defmodule SddOrchestrator.Specifications.DeviceProjectSpecification do
  @moduledoc """
  Device-authoritative representation of the shared stable specification value.

  It mirrors the hosted observable contract without being an Ecto schema or
  creating any hosted persistence.
  """

  @enforce_keys [:id, :project_id, :title, :current_revision_id, :inserted_at, :updated_at]
  defstruct [:id, :project_id, :title, :current_revision_id, :inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          project_id: Ecto.UUID.t(),
          title: String.t(),
          current_revision_id: Ecto.UUID.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }
end
