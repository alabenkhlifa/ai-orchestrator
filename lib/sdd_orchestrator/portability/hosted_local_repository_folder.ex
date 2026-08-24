defmodule SddOrchestrator.Portability.HostedLocalRepositoryFolder do
  @moduledoc """
  Points the selected machine at the repository folder for a first connection.

  A machine that has never held this project cannot locate its repository. The
  restore flow avoided the question because a restored project's worker already
  knew where the repository was; a first connection has no such record, so the
  owner names the folder and the machine never searches for it.

  `select/1` opens the machine's native folder picker through the same stand-in
  seam accountless onboarding uses, confirms the chosen folder is a Git
  repository, and returns a *proof function* — a closure over the path. The path
  is therefore held in the closure's own environment and is never a field of any
  returned, rendered, or stored value. Calling the proof recomputes the portable
  identity on the device through `PortableRepositoryIdentity` and answers only
  whether it matched the identity the project already holds.

  The proof this returns is exactly the matcher
  `HostedLocalRepositoryConnection.connect/6` expects, so the connect gate runs
  its authority checks first and this module answers only the repository
  question.
  """

  alias SddOrchestrator.Devices.{PortableRepositoryIdentity, RepositoryValidation}

  @typedoc """
  Opens the machine's folder picker. `:cancelled` when the owner dismisses it,
  `:unavailable` when this machine cannot open one at all.
  """
  @type picker :: (-> {:ok, Path.t()} | :cancelled | :unavailable)

  @typedoc "Answers only whether the selected folder is the repository the project names."
  @type proof :: (String.t() -> {:ok, boolean()} | {:error, RepositoryValidation.error()})

  @type error ::
          :cancelled
          | :not_a_git_repository
          | :picker_unavailable
          | :repository_unavailable

  @doc """
  Asks the machine for a repository folder and returns a proof over it.

  A cancelled selection returns `{:error, :cancelled}` so the caller attempts no
  connection at all. A folder that is not a Git repository returns
  `{:error, :not_a_git_repository}` at selection time rather than as a generic
  connection failure, because the owner's next action is to pick a different
  folder. Nothing is stored either way.
  """
  @spec select(keyword()) :: {:ok, proof()} | {:error, error()}
  def select(opts \\ []) do
    picker = Keyword.get_lazy(opts, :picker, &default_picker/0)

    with {:ok, path} <- open(picker),
         :ok <- git_repository(path) do
      {:ok, fn repository_id -> prove(path, repository_id) end}
    end
  end

  @doc """
  Whether this machine can open a folder picker at all.

  The real native handoff belongs to the worker's own transport, which is
  release-gated; dev and test drive the same stand-in accountless onboarding
  uses.
  """
  @spec picker_available?() :: boolean()
  def picker_available?, do: Application.get_env(:sdd_orchestrator, :device_worker_stub, false)

  defp open(picker) do
    case picker.() do
      {:ok, path} when is_binary(path) -> {:ok, path}
      :cancelled -> {:error, :cancelled}
      _unavailable -> {:error, :picker_unavailable}
    end
  end

  defp git_repository(path) do
    case RepositoryValidation.root_commit_ids(path) do
      {:ok, _roots} -> :ok
      {:error, :not_a_git_repository} -> {:error, :not_a_git_repository}
      {:error, _reason} -> {:error, :repository_unavailable}
    end
  end

  # Only a verdict, or the repository's own availability, crosses back. A folder
  # that stopped being a usable repository between selection and connection is
  # reported as such; an unusable identity is never resolved as a match.
  defp prove(path, repository_id) do
    case PortableRepositoryIdentity.match(path, repository_id) do
      {:ok, matched?} ->
        {:ok, matched?}

      {:error, reason}
      when reason in [:inaccessible, :not_a_git_repository, :empty_repository] ->
        {:error, reason}

      {:error, _identity} ->
        {:ok, false}
    end
  end

  defp default_picker do
    fn ->
      if picker_available?(), do: {:ok, stub_folder()}, else: :unavailable
    end
  end

  defp stub_folder do
    Application.get_env(:sdd_orchestrator, :device_worker_stub_folder) || File.cwd!()
  end
end
