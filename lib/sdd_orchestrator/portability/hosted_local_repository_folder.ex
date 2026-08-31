defmodule SddOrchestrator.Portability.HostedLocalRepositoryFolder do
  @moduledoc """
  Points the selected machine at the repository folder for a first connection.

  A machine that has never held this project cannot locate its repository. The
  restore flow avoided the question because a restored project's worker already
  knew where the repository was; a first connection has no such record, so the
  owner names the folder and the machine never searches for it.

  The folder is on the owner's Mac and the control plane is not, so this module
  opens nothing itself. `request/3` asks that machine's worker to open its own
  folder picker, carrying the project's portable repository identity as the only
  candidate, and returns at once with a request id. The owner answers a native
  panel in tens of seconds, so the answer arrives later in the requesting
  process's mailbox as `{:repository_selection, request_id, outcome}`. See
  `SddOrchestrator.RepositorySelection` for the outcomes.

  ## Why a verdict is still a proof

  `proof/1` builds the proof function
  `SddOrchestrator.Portability.HostedLocalRepositoryConnection.connect/6` takes,
  from the worker's answer rather than from a path. That is not a weaker check
  than the closure it replaces.

  The worker held the chosen folder, ran the Git check on it, and compared that
  real repository against the real identity this project holds. The verdict this
  closure carries is that comparison. The closure it replaces could recompute
  the identity itself only because the control plane and the repository happened
  to share one machine, which is exactly the assumption this slice removes. On a
  control plane that cannot see the folder, recomputing would be guessing; the
  proof reports what the machine that can see it found.

  The gate still runs its own authority checks first, and it still rechecks
  ownership, worker authorization, and worker availability inside the binding
  transaction. This module answers only the repository question.

  Nothing that crosses back carries a filesystem path, a remote URL, a file
  name, or a Git object. A request carries one identity, and an answer carries
  one reference.
  """

  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.SelectionResult

  # The requester's own handle for the single candidate it sends. It comes back
  # in the answer's `matches` and means "the folder is this project's
  # repository".
  @project_ref :project

  @typedoc "Answers only whether the selected folder is the repository the project names."
  @type proof :: (String.t() -> {:ok, boolean()})

  @doc """
  Asks one machine's worker for this project's repository folder.

  `scope` is `%{device_workspace_id: id, project_id: id}`, `worker_id` is the
  machine the owner chose, and `identity` is the portable repository identity
  the project already holds. No new identity is asked for: this project has one,
  and the only open question is whether the folder is it.

  Returns the request id. The outcome arrives later as a message to the calling
  process, so the caller must be the process that will render it.
  """
  @spec request(RepositorySelection.scope(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, RepositorySelection.error()}
  def request(scope, worker_id, identity) when is_binary(identity) do
    RepositorySelection.request(scope, worker_id,
      candidates: [%{ref: @project_ref, identity: identity}],
      generate: false
    )
  end

  @doc """
  Turns one worker's answer into the proof the connect gate expects.

  `requested_identity` is the identity that was sent as the single candidate.
  The worker compared the folder against that identity, so its verdict means
  nothing for any other one: a project whose identity changed while the panel
  was open is answered `{:ok, false}` rather than connected on a stale `true`.

  The proof answers `{:ok, true}` only when the worker reported that candidate
  as a match and the gate asks about that same identity. It never answers
  `{:error, _}`, because a folder the worker could not read is not reported as a
  selection at all.
  """
  @spec proof(SelectionResult.t(), String.t()) :: proof()
  def proof(%SelectionResult{matches: matches}, requested_identity)
      when is_binary(requested_identity) do
    matched? = Enum.any?(matches, &project_ref?/1)

    fn repository_id -> {:ok, matched? and repository_id == requested_identity} end
  end

  @doc "The reference this module sends its single candidate under."
  @spec project_ref() :: atom()
  def project_ref, do: @project_ref

  # A reference is stringified on the way to the worker, so a real answer names
  # it as `"project"`. An in-process transport can hand the atom straight back,
  # and both mean the same reference.
  defp project_ref?(@project_ref), do: true
  defp project_ref?(ref) when is_binary(ref), do: ref == Atom.to_string(@project_ref)
  defp project_ref?(_ref), do: false
end
