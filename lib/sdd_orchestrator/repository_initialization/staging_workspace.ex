defmodule SddOrchestrator.RepositoryInitialization.StagingWorkspace do
  @moduledoc """
  The filesystem boundary one confirmed-repository build may never leave.

  Mirrors `Delivery.Worker.Workspace`'s symlink-safe, real-path containment
  pattern (specs/33), adapted from a project-scoped `ExecutionManifest`'s
  `project_id`/`run_id` segments to this pre-project flow's own
  `RepositoryInitialization.Run` id. It is a separate module, not a reuse of
  `Workspace` itself: `Workspace` is `ExecutionManifest`-typed and owned by
  specs/33, and this staging area has no separate worker-records-vs-repository
  split the way a project-scoped run workspace does — the whole directory
  under this run's own segment *is* the staged repository, since there is no
  pre-existing project repository to keep apart from worker bookkeeping.

  Containment is decided against the root's own real location, exactly as
  `Workspace` does, which lets the configured root sit behind a link while
  nothing under it may. `:workspace_escape` is the single answer a traversal
  segment, an absolute segment, and a link escape all receive — a caller that
  cannot be placed inside the root is owed a refusal, not a description of
  which attempt was detected.

  Nothing here ever stores an absolute path: every caller recomputes a run's
  staging location from the configured root and the run's own `id` whenever
  it is needed, exactly as `Workspace` never stores one either.
  """

  alias SddOrchestrator.RepositoryInitialization.Run

  @max_link_hops 8

  @type error ::
          :invalid_run
          | :workspace_escape
          | :workspace_root_unconfigured
          | :workspace_unavailable

  @doc """
  The configured staging root, resolved to its real location.

  A missing, non-binary, or relative setting is not a usable root. Guessing
  one would place a build somewhere nobody configured, so it stays an error.
  """
  @spec root() :: {:ok, String.t()} | {:error, :workspace_root_unconfigured}
  def root do
    with configured when is_binary(configured) <-
           Application.get_env(:sdd_orchestrator, :initialization_staging_root),
         :absolute <- Path.type(configured),
         {:ok, real} <- real_path(Path.expand(configured)) do
      {:ok, real}
    else
      _unconfigured -> {:error, :workspace_root_unconfigured}
    end
  end

  @doc """
  Creates and proves this run's staging directory, returning its absolute
  path.

  The path is proven contained before anything is created so a hostile
  component is never written through, and proven again afterwards so a
  component swapped during creation is still caught.
  """
  @spec prepare(Run.t()) :: {:ok, String.t()} | {:error, error()}
  def prepare(%Run{} = run) do
    with {:ok, root} <- root(),
         {:ok, staging} <- staging_path_in(root, run),
         :ok <- contained(root, staging),
         :ok <- create(staging) do
      contained_result(root, staging)
    end
  end

  def prepare(_run), do: {:error, :invalid_run}

  @doc """
  The exact directory a build must place its output in.

  This never creates anything. A caller that needs the directory to exist has
  already called `prepare/1`.
  """
  @spec staging_path(Run.t()) :: {:ok, String.t()} | {:error, error()}
  def staging_path(%Run{} = run) do
    with {:ok, root} <- root(),
         {:ok, staging} <- staging_path_in(root, run) do
      contained_result(root, staging)
    end
  end

  def staging_path(_run), do: {:error, :invalid_run}

  @doc """
  Resolves and proves containment for one path relative to this run's staging
  directory, without creating anything.

  `relative_path` is refused as `:workspace_escape` up front when it is
  blank, absolute, or carries a `..` segment — a literal traversal string is
  not something the symlink-aware containment check below can catch on its
  own (`Path.join/2` never collapses `..`, and a `..` path component is never
  itself a symlink, so `File.read_link/1` reports "not a link" and passes the
  unresolved string straight through). The joined location is then proven
  contained the same way `prepare/1` proves the staging directory itself,
  which is what catches a symlink-based escape a purely lexical check cannot.
  """
  @spec join(Run.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def join(%Run{} = run, relative_path) when is_binary(relative_path) do
    with :ok <- safe_relative_path(relative_path),
         {:ok, root} <- root(),
         {:ok, staging} <- staging_path_in(root, run) do
      contained_result(root, Path.join(staging, relative_path))
    end
  end

  def join(_run, _relative_path), do: {:error, :invalid_run}

  defp safe_relative_path(""), do: {:error, :workspace_escape}

  defp safe_relative_path(path) do
    if Path.type(path) == :relative and ".." not in Path.split(path) do
      :ok
    else
      {:error, :workspace_escape}
    end
  end

  defp contained_result(root, path) do
    with :ok <- contained(root, path), do: {:ok, path}
  end

  defp staging_path_in(root, %Run{id: id}) do
    case safe_segment(id) do
      :ok -> {:ok, Path.join(root, id)}
      {:error, _reason} = error -> error
    end
  end

  # A run id is a UUID, not the delivery worker protocol's own id grammar
  # (`WorkerProtocol.valid_id?/1`), so its safety proof is `Ecto.UUID.cast/1`
  # succeeding — a UUID string can never carry a path separator, a `..`
  # segment, or an absolute-path leader.
  defp safe_segment(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :workspace_escape}
    end
  end

  defp safe_segment(_id), do: {:error, :workspace_escape}

  defp contained(root, path) do
    with {:ok, ^path} <- real_path(path),
         true <- String.starts_with?(path, root <> "/") do
      :ok
    else
      _escape -> {:error, :workspace_escape}
    end
  end

  # The path is derived from trusted application configuration and this run's
  # own validated UUID segment, and has already been proven to resolve inside
  # the configured root, so this is not a traversal sink. Documented false
  # positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp create(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :workspace_unavailable}
    end
  end

  # Resolves a path the way the operating system will, one component at a
  # time, so a link anywhere in the chain is followed rather than assumed
  # away. A component that does not exist yet resolves to itself, which is
  # what lets a staging directory be proven before it is created. A chain
  # that keeps redirecting is refused rather than followed forever.
  defp real_path(path, hops \\ 0)

  defp real_path(_path, hops) when hops > @max_link_hops, do: :error

  defp real_path(path, hops) do
    [base | components] = Path.split(path)

    Enum.reduce_while(components, {:ok, base}, fn component, {:ok, parent} ->
      case follow(Path.join(parent, component), hops) do
        {:ok, resolved} -> {:cont, {:ok, resolved}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp follow(path, hops) do
    case File.read_link(path) do
      {:ok, target} -> real_path(Path.expand(target, Path.dirname(path)), hops + 1)
      {:error, _not_a_link} -> {:ok, path}
    end
  end
end
