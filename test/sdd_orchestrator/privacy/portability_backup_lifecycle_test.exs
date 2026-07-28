defmodule SddOrchestrator.Privacy.PortabilityBackupLifecycleTest do
  @moduledoc """
  Task 23 proof for encrypted rolling-backup expiry and recovery boundaries.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile, as: Profile

  defp complete_profile(configuration \\ backup_configuration()) do
    Profile.new(%{
      controller_contact: "privacy@example.com",
      processors: ["Hosting database", "Encrypted backup processor"],
      hosting_regions: ["eu-central-1"],
      transfer_safeguards: "EU processing; SCCs for support access",
      privacy_notice: "https://example.com/privacy",
      incident_path: "security@example.com",
      retention_enforcement: "30-day logs and 35-day encrypted backups",
      reviews: ["Portability privacy review 2026-07"],
      encrypted_backup_configuration: configuration,
      passwordless_delivery_provider: "Approved Mail",
      passwordless_processor_agreement: "DPA-2026-07",
      passwordless_sender_domain: "login.example.com",
      passwordless_provider_region: "eu-central-1",
      passwordless_transfer_safeguards: "EU processing; SCCs for support access",
      passwordless_retention_approval: "Attempts 24h; sessions 24h after expiry",
      passwordless_privacy_review: "Authentication privacy review 2026-07",
      passwordless_anonymisation_confirmation: "No product analytics or stable identifiers"
    })
  end

  defp backup_configuration do
    %{
      encrypted: true,
      maximum_expiry_days: 35,
      restore_scope: :approved_recovery_only,
      deletion_propagation: :required,
      processor: "Approved encrypted backup processor",
      processor_agreement: "DPA-2026-07",
      regions: ["eu-central-1"],
      transfer_safeguards: "EU processing; SCCs for support access",
      retention_enforcement: "Provider lifecycle rule deletes every copy after 35 days",
      recovery_authorization: "Documented incident recovery approval",
      privacy_review: "Encrypted backup privacy review 2026-07"
    }
  end

  test "publishes the fixed infrastructure-enforced recovery contract" do
    assert Profile.backup_lifecycle_contract() == %{
             encrypted: true,
             maximum_expiry_days: 35,
             restore_scope: :approved_recovery_only,
             deletion_propagation: :required,
             enforcement: :deployment_infrastructure,
             evidence_stage: :release
           }
  end

  test "accepts complete processor evidence at or below the 35-day ceiling" do
    assert :ok = Profile.ensure_backup_release_ready(complete_profile())

    shorter =
      backup_configuration()
      |> Map.put(:maximum_expiry_days, 14)
      |> complete_profile()

    assert :ok = Profile.ensure_backup_release_ready(shorter)
  end

  test "rejects lifecycle configuration that weakens expiry or recovery controls" do
    weakened =
      backup_configuration()
      |> Map.merge(%{
        encrypted: false,
        maximum_expiry_days: 36,
        restore_scope: :routine_restore,
        deletion_propagation: :optional
      })

    assert {:error, {:invalid_backup_configuration, invalid}} =
             weakened |> complete_profile() |> Profile.ensure_backup_release_ready()

    assert Enum.sort(invalid) ==
             Enum.sort([
               :deletion_propagation,
               :encrypted,
               :maximum_expiry_days,
               :restore_scope
             ])
  end

  test "requires processor, region, transfer, retention, authorization, and review evidence" do
    incomplete =
      backup_configuration()
      |> Map.merge(%{
        processor: "",
        processor_agreement: "",
        regions: [],
        transfer_safeguards: "",
        retention_enforcement: "",
        recovery_authorization: "",
        privacy_review: ""
      })

    assert {:error, {:invalid_backup_configuration, invalid}} =
             incomplete |> complete_profile() |> Profile.ensure_backup_release_ready()

    assert Enum.sort(invalid) ==
             Enum.sort([
               :privacy_review,
               :processor,
               :processor_agreement,
               :recovery_authorization,
               :regions,
               :retention_enforcement,
               :transfer_safeguards
             ])
  end

  test "missing deployment evidence blocks release without changing local readiness" do
    profile = Profile.new(%{})

    assert {:error, {:incomplete, missing}} = Profile.ensure_backup_release_ready(profile)
    assert :encrypted_backup_configuration in missing
    assert Profile.backup_lifecycle_contract().evidence_stage == :release
    assert Profile.backup_lifecycle_contract().enforcement == :deployment_infrastructure
  end

  test "rights propagation uses the same deletion and recovery contract" do
    contract = Profile.backup_lifecycle_contract()

    assert Profile.backup_handoff(:erasure) == %{
             action: :erasure,
             deletion_propagation: :required,
             maximum_expiry_days: 35,
             restore_scope: :approved_recovery_only
           }

    assert Map.take(Profile.backup_handoff(:access), Map.keys(contract)) ==
             Map.take(contract, [
               :deletion_propagation,
               :maximum_expiry_days,
               :restore_scope
             ])
  end
end
