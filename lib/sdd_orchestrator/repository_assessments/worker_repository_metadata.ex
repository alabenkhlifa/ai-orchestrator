defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryMetadata do
  @moduledoc """
  Worker-local reference implementation of repository metadata preparation.

  The absolute repository path and identity matcher exist only as worker-local
  inputs. The returned map contains no path, remote, history, content, or raw
  diagnostic and every Git operation is read-only.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparation

  @max_link_hops 8

  @type identity :: %{
          required(:repository_provider) => term(),
          required(:repository_id) => term()
        }
  @type identity_matcher :: (Path.t(), identity() -> {:ok, boolean()} | {:error, term()})

  @spec inspect(Path.t(), term(), identity(), identity_matcher()) ::
          {:ok, map()} | {:error, atom()}
  def inspect(repository_path, selected_root, expected_identity, identity_matcher)
      when is_binary(repository_path) and is_map(expected_identity) and
             is_function(identity_matcher, 2) do
    with :ok <- identity_matches(identity_matcher, repository_path, expected_identity),
         {:ok, repository_root} <- repository_root(repository_path),
         {:ok, real_repository_root} <- real_path(repository_root),
         {:ok, normalized_root} <- RepositoryBindingPreparation.normalize_root(selected_root),
         selected_path <- selected_path(real_repository_root, normalized_root),
         {:ok, real_selected_path} <- real_path(selected_path),
         :ok <- contained(real_repository_root, real_selected_path),
         true <- File.dir?(real_selected_path),
         {:ok, commit} <- current_commit(real_selected_path) do
      {:ok,
       %{
         repository_provider: to_string(expected_identity.repository_provider),
         repository_id: to_string(expected_identity.repository_id),
         root: relative_root(real_repository_root, real_selected_path),
         commit: commit
       }}
    else
      {:error, :invalid_root} -> {:error, :root_escape}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      false -> {:error, :repository_unavailable}
      _invalid -> {:error, :repository_unavailable}
    end
  rescue
    _error -> {:error, :repository_unavailable}
  catch
    _kind, _reason -> {:error, :repository_unavailable}
  end

  def inspect(_repository_path, _selected_root, _identity, _matcher),
    do: {:error, :repository_unavailable}

  defp identity_matches(matcher, repository_path, identity) do
    case matcher.(repository_path, identity) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :repository_mismatch}
      {:error, _reason} -> {:error, :repository_unavailable}
      _invalid -> {:error, :repository_unavailable}
    end
  end

  defp repository_root(repository_path) do
    case git(repository_path, ["rev-parse", "--show-toplevel"]) do
      {root, 0} when root != "" ->
        if Path.type(root) == :absolute,
          do: {:ok, Path.expand(root)},
          else: {:error, :repository_unavailable}

      _failure ->
        {:error, :repository_unavailable}
    end
  end

  defp current_commit(path) do
    case git(path, ["rev-parse", "--verify", "HEAD^{commit}"]) do
      {commit, 0} -> RepositoryBindingPreparation.full_commit(commit)
      _failure -> {:error, :repository_unavailable}
    end
  end

  defp selected_path(repository_root, "."), do: repository_root
  defp selected_path(repository_root, root), do: Path.join(repository_root, root)

  defp relative_root(repository_root, repository_root), do: "."

  defp relative_root(repository_root, selected_path),
    do: Path.relative_to(selected_path, repository_root)

  defp contained(root, root), do: :ok

  defp contained(root, path) do
    if String.starts_with?(path, root <> "/"),
      do: :ok,
      else: {:error, :root_escape}
  end

  defp real_path(path, hops \\ 0)
  defp real_path(_path, hops) when hops > @max_link_hops, do: {:error, :root_escape}

  defp real_path(path, hops) do
    [base | components] = Path.split(Path.expand(path))

    Enum.reduce_while(components, {:ok, base}, fn component, {:ok, parent} ->
      case File.read_link(Path.join(parent, component)) do
        {:ok, target} ->
          case real_path(Path.expand(target, parent), hops + 1) do
            {:ok, resolved} -> {:cont, {:ok, resolved}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _not_a_link} ->
          {:cont, {:ok, Path.join(parent, component)}}
      end
    end)
  end

  defp git(path, args) do
    {output, status} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    {String.trim(output), status}
  rescue
    _error -> {"", 1}
  end
end
