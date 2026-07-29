defmodule SddOrchestrator.Delivery.Worker.Workspace do
  @moduledoc """
  The filesystem boundary one run may never leave.

  A branch name or a feature label is not isolation. Every run owns one
  directory under one configured root, and the worker refuses any path it
  cannot prove is inside that root — including a path that reads as contained
  but whose real location is somewhere else through a symbolic link. Expanding
  the string is not proof, so every component is resolved on disk both before
  and after the directory is created.

  Containment is decided against the root's own real location, which lets the
  configured root sit behind a link while nothing under it may.

  The run workspace holds the worker's own records and the repository the agent
  works in is a directory inside it. Keeping those apart is what lets the worker
  record a branch, a lock, and a stop request without writing any of it into the
  tree the agent is about to commit.

  `:invalid_manifest` means no manifest was supplied. `:workspace_escape` is the
  single answer a traversal segment, an absolute segment, and a link escape all
  receive: a caller that cannot be placed inside the root is owed a refusal, not
  a description of which attempt was detected.
  """

  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.WorkerProtocol

  @repository_directory "repository"
  @max_link_hops 8

  @type error ::
          :invalid_manifest
          | :workspace_escape
          | :workspace_root_unconfigured
          | :workspace_unavailable

  @doc """
  The configured workspace root, resolved to its real location.

  A missing, non-binary, or relative setting is not a usable root. Guessing one
  would place runs somewhere nobody configured, so it stays an error.
  """
  @spec root() :: {:ok, String.t()} | {:error, :workspace_root_unconfigured}
  def root do
    with configured when is_binary(configured) <-
           Application.get_env(:sdd_orchestrator, :worker_workspace_root),
         :absolute <- Path.type(configured),
         {:ok, real} <- real_path(Path.expand(configured)) do
      {:ok, real}
    else
      _unconfigured -> {:error, :workspace_root_unconfigured}
    end
  end

  @doc """
  Creates and proves this run's workspace, returning its absolute path.

  The path is proven contained before anything is created so the worker never
  writes through a hostile component, and proven again afterwards so a component
  swapped during creation is still caught.
  """
  @spec prepare(ExecutionManifest.t()) :: {:ok, String.t()} | {:error, error()}
  def prepare(%ExecutionManifest{} = manifest) do
    with {:ok, root} <- root(),
         {:ok, workspace} <- run_path(root, manifest),
         :ok <- contained(root, workspace),
         :ok <- create(workspace),
         :ok <- create(repository_path(workspace)) do
      confirm(root, workspace)
    end
  end

  def prepare(_manifest), do: {:error, :invalid_manifest}

  @doc """
  The exact directory an agent process must be launched in.

  This never creates anything. A caller that needs the directory to exist has
  already prepared the workspace; a caller that is only checking a working
  directory must not bring one into being by asking.
  """
  @spec working_directory(ExecutionManifest.t()) :: {:ok, String.t()} | {:error, error()}
  def working_directory(%ExecutionManifest{} = manifest) do
    with {:ok, root} <- root(),
         {:ok, workspace} <- run_path(root, manifest),
         directory = repository_path(workspace),
         :ok <- contained(root, directory) do
      {:ok, directory}
    end
  end

  def working_directory(_manifest), do: {:error, :invalid_manifest}

  @doc """
  Confirms one process working directory is exactly this run's.

  The comparison is between real locations, so an equivalent spelling of the
  same directory is accepted while a different directory that merely looks
  similar is not.
  """
  @spec ensure_working_directory(ExecutionManifest.t(), Path.t()) :: :ok | {:error, error()}
  def ensure_working_directory(manifest, directory) when is_binary(directory) do
    case working_directory(manifest) do
      {:ok, expected} -> compare(expected, directory)
      {:error, _reason} = error -> error
    end
  end

  def ensure_working_directory(_manifest, _directory), do: {:error, :workspace_escape}

  defp compare(expected, directory) do
    case real_path(Path.expand(directory)) do
      {:ok, ^expected} -> :ok
      _mismatch -> {:error, :workspace_escape}
    end
  end

  defp confirm(root, workspace) do
    with :ok <- contained(root, workspace),
         :ok <- contained(root, repository_path(workspace)) do
      {:ok, workspace}
    end
  end

  defp run_path(root, %ExecutionManifest{project_id: project_id, run_id: run_id}) do
    with :ok <- safe_segment(project_id),
         :ok <- safe_segment(run_id) do
      {:ok, Path.join([root, project_id, run_id])}
    end
  end

  # The protocol's identifier grammar is also the segment grammar: one path
  # element with no separator, no parent reference, and no root of its own.
  defp safe_segment(segment) do
    if WorkerProtocol.valid_id?(segment), do: :ok, else: {:error, :workspace_escape}
  end

  defp repository_path(workspace), do: Path.join(workspace, @repository_directory)

  defp contained(root, path) do
    with {:ok, ^path} <- real_path(path),
         true <- String.starts_with?(path, root <> "/") do
      :ok
    else
      _escape -> {:error, :workspace_escape}
    end
  end

  # The path is derived from trusted application configuration and the
  # manifest's validated identifiers, and has already been proven to resolve
  # inside the configured root, so this is not a traversal sink. Documented
  # false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp create(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :workspace_unavailable}
    end
  end

  # Resolves a path the way the operating system will, one component at a time,
  # so a link anywhere in the chain is followed rather than assumed away. A
  # component that does not exist yet resolves to itself, which is what lets a
  # workspace be proven before it is created. A chain that keeps redirecting is
  # refused rather than followed forever.
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
