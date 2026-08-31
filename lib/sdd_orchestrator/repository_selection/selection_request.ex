defmodule SddOrchestrator.RepositorySelection.SelectionRequest do
  @moduledoc """
  One open request for a worker to name a repository, held in memory only.

  A person answers a native folder panel in tens of seconds, so the request
  outlives the call that made it. It is bound to the process that asked, which
  is what lets the answer reach exactly one requester and lets a closed tab
  cancel the panel it opened.

  The request is never persisted. Losing every open request on a control-plane
  restart is the correct outcome: nothing was promised, and a person simply
  asks again.

  It carries identities, never a location. `candidates` holds portable
  repository identities the worker should compare the chosen folder against,
  each under a `ref` the requester chose. No filesystem path, remote URL, Git
  history, file name, or file content belongs in this struct, and none can be
  put in it: the struct has no field that would hold one.
  """

  @enforce_keys [
    :id,
    :requester,
    :device_workspace_id,
    :worker_id,
    :candidates,
    :generate?,
    :expires_at
  ]
  defstruct [
    :id,
    :requester,
    :device_workspace_id,
    :project_id,
    :worker_id,
    :candidates,
    :generate?,
    :expires_at
  ]

  @typedoc "One identity the worker compares the chosen folder against, under the requester's own reference."
  @type candidate :: %{ref: term(), identity: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          requester: pid(),
          device_workspace_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t() | nil,
          worker_id: String.t(),
          candidates: [candidate()],
          generate?: boolean(),
          expires_at: DateTime.t()
        }
end
