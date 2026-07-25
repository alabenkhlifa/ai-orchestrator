defmodule SddOrchestrator.Privacy.DeploymentPrivacyProfileTest do
  @moduledoc """
  Release-gate proof (Task 10, AC-43): an incomplete deployment privacy profile
  blocks release and names the missing evidence, while a complete profile is release
  ready. The gate is a separate check, so it never blocks implementation or local
  verification.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile, as: Profile

  defp complete_attrs do
    %{
      controller_contact: "privacy@example.com",
      processors: ["Hosting DB", "Backups"],
      hosting_regions: ["eu-central-1"],
      transfer_safeguards: "SCCs",
      privacy_notice: "https://example.com/privacy",
      incident_path: "security@example.com",
      retention_enforcement: "Hourly pruner + 30d logs + 35d backups",
      reviews: ["DPIA 2026-07"]
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

  test "blank and empty-list evidence do not satisfy a requirement" do
    profile = Profile.new(%{complete_attrs() | processors: [], controller_contact: ""})

    assert :processors in Profile.missing_requirements(profile)
    assert :controller_contact in Profile.missing_requirements(profile)
  end
end
