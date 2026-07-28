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
  alias SddOrchestrator.ProjectStorage.StorageMode

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

  @doc """
  The approved, source-neutral heading for the storage-selection step. Identical
  for every repository source so the shared surface never leaks GitHub- or
  local-specific wording.
  """
  @spec question() :: String.t()
  def question, do: "Where should your project work be saved?"

  @doc """
  The approved explanation of what the storage choice covers. Source-neutral: it
  never names GitHub or a local path, so it reads correctly for both onboarding
  sources.
  """
  @spec work_explanation() :: String.t()
  def work_explanation do
    "Your project work includes specifications, tasks, agent runs, and generated files. " <>
      "Your linked repository stays where it is."
  end

  @doc "The plain-language label for a storage mode."
  @spec label(mode()) :: String.t()
  def label(:hosted), do: "In my SDD Orchestrator account"
  def label(:device), do: "On this device"

  @doc """
  The approved, first-release access-consequence description for a storage mode.

  The hosted copy states cross-device account access without stating or implying
  that collaboration is available (AC-16). The device copy states the on-device
  boundary and that moving or exporting is required to reach another device.
  """
  @spec description(mode()) :: String.t()
  def description(:hosted),
    do: "Your project work is saved to your account so you can access it from other devices."

  def description(:device) do
    "Your project work stays on this device. It will not be available on another device " <>
      "or to collaborators unless you move or export it later."
  end

  @doc """
  Availability of a storage mode for an onboarding attempt.

  Hosted requires an authorized identity: a hosted-origin attempt (the user is
  already signed in) always has one, while a device-origin (accountless) attempt
  has one only after a verified hosted sign-in records the hosted prerequisite —
  until then hosted stays visible but unavailable with a sign-in action. Device is
  available only when the attempt carries a valid, unexpired readiness receipt
  from the local-device boundary.
  """
  @spec availability(mode(), ProjectOnboardingAttempt.t()) :: availability()
  def availability(:hosted, %ProjectOnboardingAttempt{origin_kind: "hosted"}), do: :available

  def availability(:hosted, %ProjectOnboardingAttempt{
        hosted_prerequisite_workspace_id: workspace_id
      })
      when not is_nil(workspace_id),
      do: :available

  def availability(:hosted, %ProjectOnboardingAttempt{}),
    do: {:unavailable, :hosted_sign_in_required}

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
  @spec parse_mode(String.t() | mode()) :: {:ok, mode()} | :error
  def parse_mode(mode), do: StorageMode.to_atom(mode)
end
