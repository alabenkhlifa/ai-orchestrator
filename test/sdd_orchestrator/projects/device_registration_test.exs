defmodule SddOrchestrator.Projects.DeviceRegistrationTest do
  @moduledoc """
  Task 4 proof for attempt-integrated on-device registration (AC-04, AC-07,
  AC-08).

  The device store owns the atomic worker transaction; registration commits the
  project, its repository connection (the canonical fingerprint), and the device
  storage mode together under the operating-system boundary and writes nothing
  device-authoritative to hosted PostgreSQL. Registration is idempotent by the
  attempt's key: a committed retry returns the same project, and a lost
  control-plane acknowledgement is reconciled without a duplicate. Creation is
  blocked without an explicit, available device mode, and a repository already
  linked is reported rather than duplicated.

  The device store is a singleton GenServer not started in test, so each test uses
  its own isolated instance on a unique path in an `async: false` case.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    {:ok, device} = Devices.establish_workspace()
    %{device: device, attempt: device_ready_attempt(device)}
  end

  describe "successful registration (AC-07)" do
    test "commits the project, its fingerprint connection, and the device mode, then consumes the attempt",
         %{device: device, attempt: attempt} do
      assert {:ok, project} = Projects.register_device_project(device, attempt)

      assert project.storage_mode == "device"
      assert project.status == "connected"
      assert project.repository_fingerprint == attempt.selected_repository["fingerprint"]
      assert project.idempotency_key == attempt.idempotency_key

      # The transient control-plane attempt is acknowledged (consumed).
      consumed = Projects.get_device_onboarding_attempt(device, attempt.id)
      refute is_nil(consumed.consumed_at)

      # Nothing device-authoritative is written to hosted PostgreSQL.
      assert Repo.aggregate(Project, :count) == 0
      assert [only] = Devices.list_projects()
      assert only.id == project.id
    end
  end

  describe "explicit, available selection required (AC-04, AC-08)" do
    test "blocks creation when no storage mode has been selected", %{device: device} do
      no_mode = ProjectsFixtures.device_attempt_with_repository(device)

      assert {:error, :storage_mode_required} = Projects.register_device_project(device, no_mode)
      assert Devices.list_projects() == []
    end

    test "blocks creation when device storage is not ready (no readiness receipt)", %{
      device: device
    } do
      {:ok, attempt} = Projects.start_device_onboarding_attempt(device)

      {:ok, _} =
        Projects.select_local_repository(
          device,
          attempt.id,
          ProjectsFixtures.local_repository_metadata()
        )

      {:ok, _} = Projects.select_storage_mode(device, attempt.id, "device")
      ready = Projects.get_device_onboarding_attempt(device, attempt.id)

      assert {:error, :storage_not_ready} = Projects.register_device_project(device, ready)
      assert Devices.list_projects() == []
    end
  end

  describe "idempotency and reconciliation" do
    test "a committed retry returns the same project without a duplicate", %{
      device: device,
      attempt: attempt
    } do
      assert {:ok, project} = Projects.register_device_project(device, attempt)

      # Retry the (now consumed) attempt: the same project resolves by its key.
      retried = Projects.get_device_onboarding_attempt(device, attempt.id)
      assert {:ok, again} = Projects.register_device_project(device, retried)

      assert again.id == project.id
      assert length(Devices.list_projects()) == 1
    end

    test "a lost control-plane acknowledgement is reconciled without a duplicate", %{
      device: device,
      attempt: attempt
    } do
      # Simulate a device commit whose acknowledgement was lost: the project is
      # committed under the attempt's key, but the attempt is not yet consumed.
      {:ok, committed} =
        Devices.register_project(%{
          name: "Reconciled",
          repository_fingerprint: attempt.selected_repository["fingerprint"],
          status: "connected",
          idempotency_key: attempt.idempotency_key
        })

      assert is_nil(Projects.get_device_onboarding_attempt(device, attempt.id).consumed_at)

      # The normal registration path reconciles: same project, attempt consumed.
      assert {:ok, reconciled} = Projects.register_device_project(device, attempt)
      assert reconciled.id == committed.id
      assert length(Devices.list_projects()) == 1
      refute is_nil(Projects.get_device_onboarding_attempt(device, attempt.id).consumed_at)
    end
  end

  describe "one project per repository" do
    test "reports a repository already linked instead of creating a second project", %{
      device: device,
      attempt: attempt
    } do
      assert {:ok, _} = Projects.register_device_project(device, attempt)

      duplicate =
        device_ready_attempt(device, %{
          fingerprint: attempt.selected_repository["fingerprint"],
          name: "Duplicate"
        })

      assert {:error, {:repository_already_linked, existing}} =
               Projects.register_device_project(device, duplicate)

      assert existing.repository_fingerprint == attempt.selected_repository["fingerprint"]
      assert length(Devices.list_projects()) == 1
    end
  end

  # A device-origin attempt ready to register: repository selected, a bound
  # readiness receipt recorded, and on-device storage explicitly chosen.
  defp device_ready_attempt(device, repository \\ nil) do
    attempt =
      case repository do
        nil -> ProjectsFixtures.device_attempt_with_repository(device)
        repo -> ProjectsFixtures.device_attempt_with_repository(device, repo)
      end

    {:ok, _} =
      Projects.record_device_receipt(device, attempt.id, ProjectsFixtures.device_receipt(attempt))

    {:ok, _} = Projects.select_storage_mode(device, attempt.id, "device")
    Projects.get_device_onboarding_attempt(device, attempt.id)
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_device_reg_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
