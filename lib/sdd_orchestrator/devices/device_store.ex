defmodule SddOrchestrator.Devices.DeviceStore do
  @moduledoc """
  The device-side persistence contract for accountless on-device data.

  Device-authoritative data — the device workspace and its projects — lives under
  the current operating-system boundary and never in the hosted control-plane
  database. The native macOS worker provides the production adapter
  (release-gated); `SddOrchestrator.Devices.DeviceStore.Local` backs development
  and verification.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{DeviceProject, DeviceTransaction}
  alias SddOrchestrator.Portability.{ImportAttempt, PackageProvenance}
  alias SddOrchestrator.SpecificationStore

  alias SddOrchestrator.Specifications.{
    DeviceProjectSpecification,
    DeviceSpecificationRevision
  }

  @doc "Returns the established device workspace, creating it if none exists."
  @callback establish_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, term()}

  @doc "Returns the established device workspace, or `{:error, :not_found}` after loss."
  @callback get_workspace() :: {:ok, DeviceWorkspace.t()} | {:error, :not_found}

  @doc "Atomically registers one device project under the workspace naming and uniqueness rules."
  @callback register_project(map(), keyword()) :: {:ok, DeviceProject.t()} | {:error, term()}

  @doc "Lists the device projects, ordered by display name."
  @callback list_projects() :: [DeviceProject.t()]

  @doc "Fetches one device project by id."
  @callback get_project(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}

  @doc "Corrects one device project display name without changing its stable identities."
  @callback rename_project(String.t(), String.t()) ::
              {:ok, DeviceProject.t()} | {:error, :not_found | Ecto.Changeset.t()}

  @doc """
  Deletes one device project and every device-authoritative specification,
  repository assessment, repository execution profile, repository-kit change
  plan, repository-kit installation, and pilot selection aggregate scoped to
  it.
  """
  @callback delete_project(String.t()) ::
              {:ok,
               %{
                 project_id: String.t(),
                 deleted_specifications: non_neg_integer(),
                 deleted_provenance: boolean(),
                 deleted_repository_assessments: non_neg_integer(),
                 deleted_repository_execution_profiles: non_neg_integer(),
                 deleted_repository_kit_change_plans: non_neg_integer(),
                 deleted_repository_kit_installation: boolean(),
                 deleted_pilot_selection: boolean()
               }}
              | {:error, :not_found}

  @doc "Finds a device project by its canonical repository fingerprint, for reconnection."
  @callback find_by_fingerprint(String.t()) :: {:ok, DeviceProject.t()} | {:error, :not_found}

  @doc "Marks one exact canonical repository identity connected after normal authorization."
  @callback connect_repository(String.t(), String.t(), String.t()) ::
              {:ok, DeviceProject.t()}
              | {:error, :not_found | :canonical_repository_mismatch}

  @doc """
  Atomically replaces one project's legacy repository identity after rechecking
  the other identities compared by the worker.
  """
  @callback replace_repository_identity(
              String.t(),
              String.t(),
              String.t(),
              %{optional(String.t()) => String.t()}
            ) ::
              {:ok, DeviceProject.t()}
              | {:error,
                 :not_found
                 | :identity_changed
                 | :identity_race
                 | :invalid_repository_identity
                 | {:repository_already_linked, DeviceProject.t()}}

  @doc "Atomically creates one specification and its first complete revision."
  @callback create_specification(
              String.t(),
              DeviceProjectSpecification.t(),
              DeviceSpecificationRevision.t()
            ) :: {:ok, SpecificationStore.current()} | {:error, term()}

  @doc "Atomically appends and advances one expected specification head."
  @callback append_specification_revision(
              String.t(),
              String.t(),
              String.t(),
              DeviceSpecificationRevision.t(),
              map()
            ) :: {:ok, SpecificationStore.current()} | {:error, term()}

  @doc "Returns one device-authoritative specification and its current revision."
  @callback get_current_specification(String.t(), String.t()) ::
              {:ok, SpecificationStore.current()} | {:error, :not_found}

  @doc "Counts the device-authoritative specifications for one project."
  @callback specification_count(String.t()) :: non_neg_integer()

  @doc "Returns all current device-authoritative specifications for one project."
  @callback current_specifications(String.t()) :: [SpecificationStore.current()]

  @doc "Stores one minimized repository assessment under its device project."
  @callback put_repository_assessment(String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, :not_found | :already_exists | :invalid_assessment}

  @doc """
  Atomically replaces one assessment only while its stored state matches.

  A completed value must arrive with its exact minimized proposal-envelope
  value, and both are stored together or not at all. An unsuccessful value must
  arrive with `nil`.
  """
  @callback transition_repository_assessment(
              String.t(),
              String.t(),
              String.t(),
              map(),
              map() | nil
            ) ::
              {:ok, map()}
              | {:error, :not_found | :stale | :invalid_assessment | :invalid_proposal_envelope}

  @doc "Reads one device-authoritative repository assessment value."
  @callback get_repository_assessment(String.t(), String.t()) ::
              {:ok, map()} | {:error, :not_found}

  @doc "Reads one device-authoritative proposal-envelope value."
  @callback get_repository_assessment_proposal_envelope(String.t(), String.t()) ::
              {:ok, map()} | {:error, :not_found}

  @doc "Counts one project's device-authoritative repository assessments."
  @callback repository_assessment_count(String.t()) :: non_neg_integer()

  @doc "Reads the newest device-authoritative repository assessment value."
  @callback latest_repository_assessment(String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc "Reads the newest completed device-authoritative repository assessment value."
  @callback latest_completed_repository_assessment(String.t()) ::
              {:ok, map()} | {:error, :not_found}

  @doc "Atomically appends one immutable execution profile from an exact assessment proposal."
  @callback append_repository_execution_profile(
              String.t(),
              String.t(),
              map(),
              String.t(),
              String.t()
            ) :: {:ok, map()} | {:error, atom()}

  @doc "Lists one project's immutable execution profile values in version order."
  @callback list_repository_execution_profiles(String.t()) :: [map()]

  @doc "Atomically appends one immutable device-authoritative repository-kit change plan."
  @callback append_repository_kit_change_plan(String.t(), map()) ::
              {:ok, map()} | {:error, atom()}

  @doc "Lists one project's device-authoritative repository-kit change plan values."
  @callback list_repository_kit_change_plans(String.t()) :: [map()]

  @doc "Stores one project's single current device-authoritative repository-kit installation value, replacing any prior one."
  @callback put_repository_kit_installation(String.t(), map()) ::
              {:ok, map()} | {:error, atom()}

  @doc "Reads one project's current device-authoritative repository-kit installation value."
  @callback get_repository_kit_installation(String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc "Stores one project's single current pilot selection value, replacing any prior one."
  @callback put_repository_pilot_selection(String.t(), map()) :: {:ok, map()} | {:error, atom()}

  @doc "Reads one project's current device-authoritative pilot selection value."
  @callback get_repository_pilot_selection(String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc "Stores one vault-sealed device-local import attempt."
  @callback put_import_attempt(ImportAttempt.t()) ::
              {:ok, ImportAttempt.t()} | {:error, term()}

  @doc "Fetches one vault-sealed device-local import attempt."
  @callback get_import_attempt(String.t()) ::
              {:ok, ImportAttempt.t()} | {:error, :not_found}

  @doc "Deletes one device-local import attempt and encrypted upload."
  @callback delete_import_attempt(String.t()) :: :ok

  @doc "Deletes stranded device-local import attempts at the 24-hour boundary."
  @callback prune_import_attempts(DateTime.t()) :: {:ok, non_neg_integer()}

  @doc "Fetches the minimal device-local restore provenance for one project."
  @callback get_package_provenance(String.t()) ::
              {:ok, PackageProvenance.t()} | {:error, :not_found}

  @doc "Commits the supported contributions in one worker-owned device transaction."
  @callback commit_transaction(DeviceTransaction.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Applies one all-or-nothing batch of feature-delivery writes.

  Each write carries the state version its author read. The worker re-checks
  every one against what is stored and applies the whole batch or none of it,
  which is how a device-authoritative project gets the same expected-version
  guarantee the hosted adapter gets from PostgreSQL.
  """
  @callback commit_delivery(String.t(), [
              {:put, atom(), String.t(), map(), pos_integer() | nil}
            ]) :: {:ok, map()} | {:error, :stale_state | term()}

  @doc "Reads one device-authoritative delivery record."
  @callback get_delivery(String.t(), atom(), String.t()) :: {:ok, map()} | {:error, :not_found}

  @doc "Lists one project's device-authoritative delivery records of one kind."
  @callback list_delivery(String.t(), atom()) :: [map()]
end
