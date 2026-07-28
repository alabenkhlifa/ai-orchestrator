defmodule SddOrchestrator.Specifications.DeviceSpecificationRevision do
  @moduledoc """
  Immutable complete revision stored only under the device worker boundary.
  """

  @enforce_keys [
    :id,
    :specification_id,
    :project_id,
    :sequence,
    :requirements_document,
    :design_document,
    :tasks_document,
    :content_digest,
    :inserted_at
  ]
  defstruct [
    :id,
    :specification_id,
    :project_id,
    :sequence,
    :requirements_document,
    :design_document,
    :tasks_document,
    :content_digest,
    :actor_ref,
    :inserted_at
  ]

  @type t :: %__MODULE__{}
end
