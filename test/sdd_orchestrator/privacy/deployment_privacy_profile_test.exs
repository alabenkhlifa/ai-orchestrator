defmodule SddOrchestrator.Privacy.DeploymentPrivacyProfileTest do
  @moduledoc """
  Release-gate proof (Task 10, AC-43): an incomplete deployment privacy profile
  blocks release and names the missing evidence, while a complete profile is release
  ready. The gate is a separate check, so it never blocks implementation or local
  verification.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile, as: Profile

  defmodule ProductionDelivery do
    @behaviour SddOrchestrator.HostedAccess.Delivery

    @impl true
    def deliver(_email), do: {:ok, %{}}
  end

  defp complete_attrs do
    %{
      controller_contact: "privacy@example.com",
      processors: ["Hosting DB", "Backups", "Approved Mail"],
      hosting_regions: ["eu-central-1"],
      transfer_safeguards: "SCCs",
      privacy_notice: "https://example.com/privacy",
      incident_path: "security@example.com",
      retention_enforcement: "Hourly pruner + 30d logs + 35d backups",
      reviews: ["DPIA 2026-07"],
      passwordless_delivery_provider: "Approved Mail",
      passwordless_processor_agreement: "DPA-2026-07",
      passwordless_sender_domain: "login.example.com",
      passwordless_provider_region: "eu-central-1",
      passwordless_transfer_safeguards: "EU processing; SCCs for support access",
      passwordless_retention_approval: "Attempts 24h; sessions 24h after expiry",
      passwordless_privacy_review: "Authentication privacy review 2026-07",
      passwordless_anonymisation_confirmation: "No product analytics or stable identifiers"
    }
  end

  test "an empty profile is not release ready and lists every missing field" do
    profile = Profile.new(%{})

    refute Profile.release_ready?(profile)

    assert Enum.sort(Profile.missing_requirements(profile)) ==
             Enum.sort(Profile.required_fields())

    assert {:error, {:incomplete, missing}} = Profile.ensure_release_ready(profile)
    assert :controller_contact in missing
  end

  test "a profile missing one field blocks release and names only that field" do
    profile = Profile.new(Map.delete(complete_attrs(), :incident_path))

    assert Profile.missing_requirements(profile) == [:incident_path]
    assert {:error, {:incomplete, [:incident_path]}} = Profile.ensure_release_ready(profile)
  end

  test "a complete profile is release ready" do
    profile = Profile.new(complete_attrs())

    assert Profile.release_ready?(profile)
    assert Profile.missing_requirements(profile) == []
    assert Profile.ensure_release_ready(profile) == :ok
  end

  test "records the specification log and encrypted-backup expiry ceilings" do
    assert Profile.retention_requirements() == %{
             operational_security_logs_days: 30,
             encrypted_rolling_backups_days: 35
           }
  end

  test "blank and empty-list evidence do not satisfy a requirement" do
    profile = Profile.new(%{complete_attrs() | processors: [], controller_contact: ""})

    assert :processors in Profile.missing_requirements(profile)
    assert :controller_contact in Profile.missing_requirements(profile)
  end

  test "passwordless release rejects the local or test delivery configuration" do
    profile = Profile.new(complete_attrs())

    assert {:error, {:unsafe_delivery_configuration, :local_or_test_mailer_adapter}} =
             Profile.ensure_passwordless_release_ready(profile)
  end

  test "passwordless release accepts complete evidence and a production delivery boundary" do
    profile = Profile.new(complete_attrs())

    assert :ok =
             Profile.ensure_passwordless_release_ready(profile, %{
               delivery_module: ProductionDelivery,
               mailer_adapter: nil
             })
  end
end
