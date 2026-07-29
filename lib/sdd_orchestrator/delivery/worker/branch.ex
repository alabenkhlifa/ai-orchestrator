defmodule SddOrchestrator.Delivery.Worker.Branch do
  @moduledoc """
  The isolated branch one run owns for its whole life.

  A run writes only to the branch its manifest names, and that name is recorded
  in the run's own workspace the first time it resolves. A later command naming
  a different branch for the same run is refused rather than reconciled: two
  branch names for one run means one of them carries work the product never
  approved.

  The default branch is refused outright. A run able to reach `main` would make
  human review optional, which is the one outcome this workflow exists to
  prevent.

  The base revision is never assumed. The repository must resolve the exact
  revision the manifest bound the attempt to before any branch exists, so a
  workspace sitting on unrelated history fails before an agent starts rather
  than after it produces a diff nobody can place.

  Git sits behind `Branch.Repository` so those guarantees stay provable without
  a repository, and so the worker's Git surface remains four named operations
  rather than an open command line.
  """

  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.Worker.Branch.Repository
  alias SddOrchestrator.Delivery.Worker.Workspace

  @branch_record "branch"
  @default_branches ~w(head main master)

  @enforce_keys [:name, :run_id, :base_revision, :working_directory, :reused?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          run_id: String.t(),
          base_revision: String.t(),
          working_directory: String.t(),
          reused?: boolean()
        }

  @type error ::
          :base_revision_mismatch
          | :branch_conflict
          | :default_branch_forbidden
          | :invalid_manifest
          | :repository_unavailable
          | Workspace.error()

  @doc "The configured repository boundary, defaulting to the installed `git`."
  @spec repository() :: module()
  def repository do
    Application.get_env(:sdd_orchestrator, :worker_repository, Repository.Git)
  end

  @doc """
  Creates or reuses this run's isolated branch inside its own workspace.

  Every gate runs before the repository is touched, so a refused run leaves no
  branch, no checkout, and no partially prepared workspace behind.
  """
  @spec prepare(ExecutionManifest.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def prepare(manifest, opts \\ [])

  def prepare(%ExecutionManifest{} = manifest, opts) do
    with {:ok, valid} <- revalidate(manifest),
         :ok <- refuse_default_branch(valid.target_branch),
         {:ok, workspace} <- Workspace.prepare(valid),
         {:ok, directory} <- Workspace.working_directory(valid),
         {:ok, name} <- stable_branch(workspace, valid.target_branch) do
      resolve(Keyword.get_lazy(opts, :repository, &repository/0), directory, valid, name)
    end
  end

  def prepare(_manifest, _opts), do: {:error, :invalid_manifest}

  defp resolve(repository, directory, manifest, name) do
    with {:ok, base} <-
           resolved_base(repository, directory, manifest.repository_base_revision),
         {:ok, reused?} <- create_or_reuse(repository, directory, name, base) do
      {:ok,
       %__MODULE__{
         name: name,
         run_id: manifest.run_id,
         base_revision: base,
         working_directory: directory,
         reused?: reused?
       }}
    end
  end

  # The worker re-derives the manifest's own rules instead of restating them, so
  # a hand-built or altered manifest cannot widen the branch grammar the control
  # plane already enforced.
  defp revalidate(manifest) do
    case manifest |> ExecutionManifest.to_map() |> ExecutionManifest.new() do
      {:ok, valid} -> {:ok, valid}
      {:error, _reason} -> {:error, :invalid_manifest}
    end
  end

  # Case and a `refs/heads/` prefix are stripped first so the refusal cannot be
  # spelled around. A branch merely named after the default one is refused too,
  # which costs a rename and buys certainty.
  defp refuse_default_branch(branch) do
    normalized = branch |> String.replace_prefix("refs/heads/", "") |> String.downcase()

    if normalized in @default_branches, do: {:error, :default_branch_forbidden}, else: :ok
  end

  # The record is the run's answer to "which branch is mine", and it is written
  # once. An unreadable record is not treated as agreement.
  # sobelow_skip ["Traversal.FileModule"]
  defp stable_branch(workspace, target) do
    path = Path.join(workspace, @branch_record)

    case File.read(path) do
      {:ok, recorded} -> confirm_recorded(String.trim(recorded), target)
      {:error, :enoent} -> record(path, target)
      {:error, _unreadable} -> {:error, :workspace_unavailable}
    end
  end

  defp confirm_recorded(target, target), do: {:ok, target}
  defp confirm_recorded(_recorded, _target), do: {:error, :branch_conflict}

  # sobelow_skip ["Traversal.FileModule"]
  defp record(path, target) do
    case File.write(path, target) do
      :ok -> {:ok, target}
      {:error, _reason} -> {:error, :workspace_unavailable}
    end
  end

  defp resolved_base(repository, directory, base_revision) do
    case repository.resolve_revision(directory, base_revision) do
      {:ok, resolved} -> match_base(resolved, base_revision)
      {:error, :unknown_revision} -> {:error, :base_revision_mismatch}
      {:error, _reason} -> {:error, :repository_unavailable}
    end
  end

  # An abbreviated manifest revision counts only when it actually prefixes the
  # revision this repository resolved, so a workspace on another history is
  # refused rather than silently accepted as close enough.
  defp match_base(resolved, base_revision) do
    resolved = String.downcase(resolved)

    if String.starts_with?(resolved, String.downcase(base_revision)),
      do: {:ok, resolved},
      else: {:error, :base_revision_mismatch}
  end

  defp create_or_reuse(repository, directory, name, base) do
    case repository.branch_exists?(directory, name) do
      {:ok, true} -> reuse(repository, directory, name)
      {:ok, false} -> create(repository, directory, name, base)
      {:error, _reason} -> {:error, :repository_unavailable}
    end
  end

  defp reuse(repository, directory, name) do
    case repository.checkout(directory, name) do
      :ok -> {:ok, true}
      {:error, _reason} -> {:error, :repository_unavailable}
    end
  end

  defp create(repository, directory, name, base) do
    with :ok <- repository.create_branch(directory, name, base),
         :ok <- repository.checkout(directory, name) do
      {:ok, false}
    else
      {:error, _reason} -> {:error, :repository_unavailable}
    end
  end
end

defmodule SddOrchestrator.Delivery.Worker.Branch.Repository do
  @moduledoc """
  The four repository operations one run's branch isolation needs.

  Nothing here reads, resolves, or forwards a credential. The boundary exists so
  branch ownership, reuse, and base-revision validation can be proven against a
  deterministic double, and so the only Git a worker can perform is the Git this
  contract names.
  """

  @doc "Resolves one revision to the exact commit this repository holds."
  @callback resolve_revision(Path.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}

  @callback branch_exists?(Path.t(), String.t()) :: {:ok, boolean()} | {:error, atom()}

  @callback create_branch(Path.t(), String.t(), String.t()) :: :ok | {:error, atom()}

  @callback checkout(Path.t(), String.t()) :: :ok | {:error, atom()}
end

defmodule SddOrchestrator.Delivery.Worker.Branch.Repository.Git do
  @moduledoc """
  The installed `git` executable, invoked with an argument list and no shell.

  Every value taken from a manifest is checked to be a value and never an
  option, so a branch name or revision can never become a flag on the command
  line. The subprocess is told not to prompt for credentials: this boundary
  resolves no secret and must not be able to acquire one by asking.
  """

  @behaviour SddOrchestrator.Delivery.Worker.Branch.Repository

  @executable "git"
  @environment [{"GIT_TERMINAL_PROMPT", "0"}]

  @impl true
  def resolve_revision(directory, revision) when is_binary(revision) do
    if option?(revision) do
      {:error, :invalid_argument}
    else
      case run(directory, ["rev-parse", "--verify", "--quiet", revision <> "^{commit}"]) do
        {:ok, output} -> {:ok, String.trim(output)}
        {:error, {_status, _output}} -> {:error, :unknown_revision}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def branch_exists?(directory, name) when is_binary(name) do
    if option?(name) do
      {:error, :invalid_argument}
    else
      case run(directory, ["show-ref", "--verify", "--quiet", "refs/heads/" <> name]) do
        {:ok, _output} -> {:ok, true}
        {:error, {1, _output}} -> {:ok, false}
        {:error, _reason} -> {:error, :repository_unavailable}
      end
    end
  end

  @impl true
  def create_branch(directory, name, revision) when is_binary(name) and is_binary(revision) do
    if option?(name) or option?(revision) do
      {:error, :invalid_argument}
    else
      completed(run(directory, ["branch", name, revision]))
    end
  end

  @impl true
  def checkout(directory, name) when is_binary(name) do
    if option?(name) do
      {:error, :invalid_argument}
    else
      completed(run(directory, ["checkout", "--quiet", name]))
    end
  end

  defp completed({:ok, _output}), do: :ok
  defp completed({:error, _reason}), do: {:error, :repository_unavailable}

  defp option?(value), do: value == "" or String.starts_with?(value, "-")

  # The command is a literal and its arguments are passed as a list, so no shell
  # parses them and no manifest value can become a second command. Documented
  # false positive.
  # sobelow_skip ["CI.System"]
  defp run(directory, args) do
    case System.cmd(@executable, args,
           cd: directory,
           env: @environment,
           stderr_to_stdout: true
         ) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {status, output}}
    end
  rescue
    _unavailable -> {:error, :repository_unavailable}
  end
end
