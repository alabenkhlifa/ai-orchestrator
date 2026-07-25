defmodule SddOrchestrator.ProjectStorage do
  @moduledoc """
  The shared project-data storage contract.

  Onboarding must let the user choose where their project work is saved before a
  project exists. Two modes are offered:

    * `:hosted` — "In my SDD Orchestrator account": stored server-side and always
      available in this slice.
    * `:device` — "On this device": available only once the local-device boundary
      has supplied a valid readiness receipt (see `DeviceStorageReceipt`). Device
      setup itself is owned by `specs/02-local-project-onboarding/`.

  This module owns the stable behaviour every storage adapter implements and the
  availability rules the storage-selection step uses. The hosted adapter's
  `prepare/3` and `abort/2` (joined into the project-registration `Ecto.Multi`)
  are implemented by the project-confirmation task; the device adapter is
  implemented by `specs/02`. Availability is evaluated here so the storage step
  does not depend on either adapter existing yet.
  """

  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.ProjectStorage.DeviceStorageReceipt

  @type mode :: :hosted | :device
  @type availability :: :available | {:unavailable, atom()}

  @modes [:hosted, :device]

  @doc """
  Availability of a storage mode for the given in-flight onboarding attempt.

  Adapters implement this to report whether their prerequisites are met. Hosted
  storage is always available; device storage requires a valid readiness receipt.
  """
  @callback availability(ProjectOnboardingAttempt.t(), keyword()) :: availability()

  @doc """
  Contributes storage initialization to the project-registration transaction.

  Hosted preparation joins the project `Ecto.Multi`; device preparation validates
  the readiness receipt and adds no server-side storage. Returns the (possibly
  extended) multi or an error that aborts registration.
  """
  @callback prepare(Ecto.Multi.t(), ProjectOnboardingAttempt.t(), keyword()) ::
              {:ok, Ecto.Multi.t()} | {:error, term()}

  @doc "Releases anything a failed `prepare/3` provisioned so retries stay clean."
  @callback abort(context :: map(), keyword()) :: :ok

  @doc "The storage modes offered, in display order."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The plain-language label for a storage mode."
  @spec label(mode()) :: String.t()
  def label(:hosted), do: "In my SDD Orchestrator account"
  def label(:device), do: "On this device"

  @doc """
  Availability of a storage mode for an onboarding attempt.

  Hosted is always available in this slice. Device is available only when the
  attempt carries a valid, unexpired readiness receipt from the local-device
  boundary.
  """
  @spec availability(mode(), ProjectOnboardingAttempt.t()) :: availability()
  def availability(:hosted, _attempt), do: :available

  def availability(:device, %ProjectOnboardingAttempt{} = attempt) do
    case DeviceStorageReceipt.from_attempt(attempt) do
      {:ok, receipt} ->
        if DeviceStorageReceipt.valid?(receipt),
          do: :available,
          else: {:unavailable, :device_setup_required}

      :error ->
        {:unavailable, :device_setup_required}
    end
  end

  @doc "Whether the given mode is currently available for the attempt."
  @spec available?(mode(), ProjectOnboardingAttempt.t()) :: boolean()
  def available?(mode, attempt), do: availability(mode, attempt) == :available

  @doc "Parses a storage-mode string into its atom, or `:error`."
  @spec parse_mode(String.t()) :: {:ok, mode()} | :error
  def parse_mode("hosted"), do: {:ok, :hosted}
  def parse_mode("device"), do: {:ok, :device}
  def parse_mode(_), do: :error
end
