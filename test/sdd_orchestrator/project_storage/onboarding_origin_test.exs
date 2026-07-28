defmodule SddOrchestrator.ProjectStorage.OnboardingOriginTest do
  @moduledoc """
  Domain proof for the shared onboarding attempt's two origins and the
  identity-gated hosted-availability contract (AC-02, AC-14 foundation).

  A hosted-origin attempt (signed-in GitHub onboarding) always has hosted
  storage available. A device-origin (accountless local onboarding) attempt has
  hosted available only after a verified sign-in records the hosted prerequisite;
  device is available only through a recorded readiness receipt. Recording a
  prerequisite or a receipt only re-evaluates availability — it never selects a
  mode. Scope is enforced: a device attempt is never resolvable by another device
  and never carries a hosted owning workspace.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.ProjectStorage

  describe "hosted-origin attempt" do
    setup do
      account = AccountsFixtures.account_fixture()
      workspace = ProjectsFixtures.workspace_fixture(account)
      %{workspace: workspace, attempt: ProjectsFixtures.attempt_with_repository(workspace)}
    end

    test "hosted storage is available without any sign-in step", %{attempt: attempt} do
      assert ProjectStorage.availability(:hosted, attempt) == :available
      assert ProjectStorage.available?(:hosted, attempt)
    end

    test "carries no device workspace and keeps its hosted owning workspace", %{attempt: attempt} do
      assert attempt.origin_kind == "hosted"
      assert is_nil(attempt.device_workspace_id)
      refute is_nil(attempt.workspace_id)
    end
  end

  describe "device-origin (accountless) attempt" do
    setup do
      device = ProjectsFixtures.device_workspace_fixture()
      %{device: device, attempt: ProjectsFixtures.device_attempt_with_repository(device)}
    end

    test "owns no hosted workspace and references only the device workspace", %{
      device: device,
      attempt: attempt
    } do
      assert attempt.origin_kind == "device"
      assert attempt.device_workspace_id == device.id
      assert is_nil(attempt.workspace_id)
    end

    test "stores only the approved minimum local repository metadata", %{attempt: attempt} do
      repo = attempt.selected_repository
      assert repo["provider"] == "local"
      assert is_binary(repo["fingerprint"])
      assert is_binary(repo["name"])
      # No path, remote URL, filename, owner, or GitHub numeric id crosses over.
      assert Map.keys(repo) |> Enum.sort() == ["fingerprint", "name", "provider"]
    end

    test "hosted storage is unavailable with a sign-in prerequisite until sign-in", %{
      attempt: attempt
    } do
      assert ProjectStorage.availability(:hosted, attempt) ==
               {:unavailable, :hosted_sign_in_required}

      refute ProjectStorage.available?(:hosted, attempt)
    end

    test "device storage is unavailable until a readiness receipt is recorded", %{
      attempt: attempt
    } do
      assert ProjectStorage.availability(:device, attempt) ==
               {:unavailable, :device_setup_required}
    end

    test "a verified sign-in records the hosted prerequisite and makes hosted available without selecting it",
         %{device: device, attempt: attempt} do
      hosted_account = AccountsFixtures.account_fixture()
      hosted_workspace = ProjectsFixtures.workspace_fixture(hosted_account)

      {:ok, updated} = Projects.record_hosted_prerequisite(device, attempt.id, hosted_workspace)

      assert updated.hosted_prerequisite_workspace_id == hosted_workspace.id
      assert ProjectStorage.available?(:hosted, updated)
      # Availability only — no mode is silently selected.
      assert is_nil(updated.storage_mode)
    end
  end

  describe "scope enforcement" do
    test "a device attempt is never resolvable by another device workspace" do
      device = ProjectsFixtures.device_workspace_fixture()
      other = ProjectsFixtures.device_workspace_fixture()
      attempt = ProjectsFixtures.device_attempt_with_repository(device)

      assert Projects.get_device_onboarding_attempt(device, attempt.id).id == attempt.id
      assert is_nil(Projects.get_device_onboarding_attempt(other, attempt.id))

      assert {:error, :not_found} =
               Projects.select_storage_mode(other, attempt.id, "device")
    end

    test "a device attempt is not resolvable through the hosted workspace scope" do
      account = AccountsFixtures.account_fixture()
      hosted_workspace = ProjectsFixtures.workspace_fixture(account)
      device = ProjectsFixtures.device_workspace_fixture()
      attempt = ProjectsFixtures.device_attempt_with_repository(device)

      assert is_nil(Projects.get_onboarding_attempt(hosted_workspace, attempt.id))
    end
  end
end
