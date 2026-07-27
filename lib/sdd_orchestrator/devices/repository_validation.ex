defmodule SddOrchestrator.Devices.RepositoryValidation do
  @moduledoc """
  Worker-side validation of a user-selected local Git repository.

  Runs entirely under the operating-system boundary — on the native worker in
  production, and via this reference implementation for development and
  verification. It returns only approved outbound metadata: a non-reversible
  canonical fingerprint and a coarse status. Local paths, remote URLs, filenames,
  Git history, and source content never leave this boundary.

  The canonical fingerprint is an HMAC-SHA256 over the repository's sorted
  root-commit object ids keyed by a per-workspace salt. It is therefore stable
  across moved paths, clones, worktrees, and changed remotes, distinguishes
  unrelated repositories, scopes identity to one workspace, and never reveals the
  underlying commit ids.
  """

  @type ok :: %{fingerprint: String.t()}
  @type error :: :inaccessible | :not_a_git_repository | :empty_repository

  @doc """
  Validates the repository at `path` for `workspace_salt` and returns its canonical
  fingerprint. The salt scopes identity to one device workspace.
  """
  @spec validate(Path.t(), binary()) :: {:ok, ok()} | {:error, error()}
  def validate(path, workspace_salt) when is_binary(workspace_salt) do
    with :ok <- accessible?(path),
         :ok <- git_repository?(path),
         {:ok, roots} <- root_commits(path) do
      {:ok, %{fingerprint: fingerprint(roots, workspace_salt)}}
    end
  end

  defp accessible?(path) do
    if is_binary(path) and File.dir?(path), do: :ok, else: {:error, :inaccessible}
  end

  defp git_repository?(path) do
    case run(path, ["rev-parse", "--is-inside-work-tree"]) do
      {"true" <> _, 0} -> :ok
      _ -> {:error, :not_a_git_repository}
    end
  end

  defp root_commits(path) do
    case run(path, ["rev-list", "--max-parents=0", "HEAD"]) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> Enum.sort() do
          [] -> {:error, :empty_repository}
          roots -> {:ok, roots}
        end

      _ ->
        {:error, :empty_repository}
    end
  end

  defp fingerprint(roots, salt) do
    :hmac
    |> :crypto.mac(:sha256, salt, Enum.join(roots, "\n"))
    |> Base.url_encode64(padding: false)
  end

  defp run(path, args) do
    {out, code} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    {String.trim(out), code}
  rescue
    _ -> {"", 1}
  end
end
