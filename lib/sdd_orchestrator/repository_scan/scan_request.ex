defmodule SddOrchestrator.RepositoryScan.ScanRequest do
  @moduledoc """
  One open request for a worker to scan a repository, held in memory only.

  A scan is the same shape of question as a repository-metadata read and a
  much larger one: the worker resolves a selection reference into the folder
  it is already holding and runs the bounded worker-local scanner there. The
  request is bound to the process that asked, which is what lets it be
  monitored and lets a request end exactly once however it ends.

  The request is never persisted. Losing every open request on a control-plane
  restart is correct: every caller blocked on one is on this same node and is
  lost too, so nothing survives to reply to.

  It carries an opaque selection reference and the assessment command the
  control plane issued, never a location. `RepositoryAssessmentCommand` is
  itself closed to identity, root anchor, commit, digests, and limits, so no
  filesystem path, remote URL, or file content can be put in this struct.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand

  @enforce_keys [
    :id,
    :requester,
    :device_workspace_id,
    :project_id,
    :worker_id,
    :selection_ref,
    :command,
    :expires_at
  ]
  defstruct [
    :id,
    :requester,
    :device_workspace_id,
    :project_id,
    :worker_id,
    :selection_ref,
    :command,
    :expires_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          requester: pid(),
          device_workspace_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          worker_id: Ecto.UUID.t(),
          selection_ref: String.t(),
          command: RepositoryAssessmentCommand.t(),
          expires_at: DateTime.t()
        }
end
