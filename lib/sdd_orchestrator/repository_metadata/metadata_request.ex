defmodule SddOrchestrator.RepositoryMetadata.MetadataRequest do
  @moduledoc """
  One open request for a worker to read a repository's identity, root, and commit, held in memory only.

  Reading a repository takes a worker real time: it resolves opaque worker and
  selection references into the actual folder on the Mac before it can
  answer. The request is bound to the process that asked, which is what lets
  it be monitored and lets a request end exactly once however it ends,
  whether the asking process is the one that called
  `RepositoryMetadata.inspect/2` directly or a supervised task doing so on a
  LiveView's behalf.

  The request is never persisted. Losing every open request on a
  control-plane restart is correct: every caller blocked on one is on this
  same node and is lost too, so nothing survives to reply to.

  It carries opaque worker and selection references and two opaque digests,
  never a location. No filesystem path, remote URL, Git history, file name, or
  file content belongs in this struct, and none can be put in it: the struct
  has no field that would hold one.
  """

  @enforce_keys [
    :id,
    :requester,
    :device_workspace_id,
    :worker_id,
    :repository_provider,
    :repository_id,
    :selection_ref,
    :selected_root,
    :scanner_contract_digest,
    :disclosure_digest,
    :expires_at
  ]
  defstruct [
    :id,
    :requester,
    :device_workspace_id,
    :project_id,
    :worker_id,
    :repository_provider,
    :repository_id,
    :selection_ref,
    :selected_root,
    :scanner_contract_digest,
    :disclosure_digest,
    :expires_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          requester: pid(),
          device_workspace_id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t() | nil,
          worker_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          selection_ref: String.t(),
          selected_root: String.t(),
          scanner_contract_digest: String.t(),
          disclosure_digest: String.t(),
          expires_at: DateTime.t()
        }
end
