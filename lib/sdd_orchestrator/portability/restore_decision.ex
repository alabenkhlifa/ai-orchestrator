defmodule SddOrchestrator.Portability.RestoreDecision do
  @moduledoc """
  Validated, non-persistent restore values after identity and destination
  conflict checks pass.

  The stable project and canonical repository identities always come from the
  package. Only `display_name` may differ, and only after an explicit valid
  replacement resolves a name-only conflict.
  """

  @enforce_keys [
    :project_id,
    :display_name,
    :repository_provider,
    :repository_id,
    :checked_boundaries
  ]
  defstruct [
    :project_id,
    :display_name,
    :repository_provider,
    :repository_id,
    :checked_boundaries
  ]

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          display_name: String.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          checked_boundaries: [SddOrchestrator.Portability.RestorePreflight.boundary()]
        }
end
