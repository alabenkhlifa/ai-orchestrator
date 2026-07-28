defmodule SddOrchestrator.Portability.DeviceRestoreContribution do
  @moduledoc false

  alias SddOrchestrator.Devices.DeviceProject
  alias SddOrchestrator.Portability.PackageProvenance

  @enforce_keys [:idempotency_key, :project, :provenance]
  defstruct [:idempotency_key, :project, :provenance, :fault]

  @type t :: %__MODULE__{
          idempotency_key: String.t(),
          project: DeviceProject.t(),
          provenance: PackageProvenance.t(),
          fault: atom() | nil
        }
end
