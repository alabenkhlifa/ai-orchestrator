defmodule SddOrchestrator.RepositoryKitsChangePlanStoreTest do
  @moduledoc """
  Focused proof for Task 7: hosted/device storage parity for the
  repository-kit change plan, through `RepositoryKits.ChangePlanStore` and
  its `Hosted`/`Device` adapters.

  A genuine end-to-end device path through `RepositoryKits.plan_change/4` is
  not exercised here, for the exact reason
  `RepositoryKitChangePlanTest`'s own "plan_change/4 persistence boundary"
  describe block documents: `eligible_for_kit_offer?/2` requires a linked
  `Delivery.Feature`, and `Features.create/3`/`link_specification/5`
  authorize through the hosted-only `Participation` boundary a device
  project has no row in — building that path is out of this task's scope.
  Device coverage here instead exercises `ChangePlanStore.create/2` and
  `ChangePlanStore.current/3` directly — the exact calls
  `RepositoryKits.persist_plan/7` and `RepositoryKits.current_plan/3`
  delegate to — and confirms `RepositoryKits.current_plan/3` reaches the
  device adapter end-to-end once a plan already exists.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures
  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.ChangePlanStore
  alias SddOrchestrator.RepositoryKits.RepositoryKitChangePlan

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-kit-change-plan-store-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Device change plan project",
        repository_fingerprint: "device-change-plan-repository",
        status: "connected"
      })

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)

    %{
      account: account,
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: DateTime.utc_now() |> DateTime.truncate(:second),
      store_path: store_path
    }
  end

  describe "device change-plan storage parity" do
    test "create succeeds for a connected, matching device project, and current returns it",
         context do
      package = publish_package_fixture()
      attrs = plan_attrs(context.device_project, package, context.now)

      assert {:ok, plan} = ChangePlanStore.create(device_authority(context), attrs)
      assert %RepositoryKitChangePlan{} = plan
      assert plan.project_id == context.device_project.id
      assert plan.package_id == package.id
      assert plan.package_digest == package.digest

      assert {:ok, ^plan} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.device_project.id,
                 context.now
               )

      assert {:ok, ^plan} =
               RepositoryKits.current_plan(
                 device_authority(context),
                 context.device_project.id,
                 now: context.now
               )

      # No hosted row was ever written for a device-authoritative plan.
      assert Repo.aggregate(RepositoryKitChangePlan, :count) == 0
    end

    test "current returns the most recent non-expired plan", context do
      package = publish_package_fixture()

      assert {:ok, older} =
               ChangePlanStore.create(
                 device_authority(context),
                 plan_attrs(context.device_project, package, context.now)
               )

      later = DateTime.add(context.now, 1, :second)
      # `inserted_at` is a real wall-clock stamp (see `ChangePlanStore.Device`);
      # this guarantees the second plan sorts after the first.
      Process.sleep(2)

      assert {:ok, newer} =
               ChangePlanStore.create(
                 device_authority(context),
                 plan_attrs(context.device_project, package, later)
               )

      assert older.id != newer.id

      assert {:ok, current} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.device_project.id,
                 later
               )

      assert current.id == newer.id
    end

    test "an expired plan is not the current plan", context do
      package = publish_package_fixture()

      attrs =
        context.device_project
        |> plan_attrs(package, context.now)
        |> Map.put(:expires_at, DateTime.add(context.now, -1, :second))

      assert {:ok, _plan} = ChangePlanStore.create(device_authority(context), attrs)

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.device_project.id,
                 context.now
               )
    end

    test "a device plan has restart parity", context do
      package = publish_package_fixture()

      assert {:ok, plan} =
               ChangePlanStore.create(
                 device_authority(context),
                 plan_attrs(context.device_project, package, context.now)
               )

      stop_supervised!(Local)
      start_supervised!({Local, path: context.store_path})
      {:ok, workspace} = Devices.get_workspace()

      assert {:ok, restored} =
               ChangePlanStore.current(
                 {:device, workspace},
                 context.device_project.id,
                 context.now
               )

      assert restored.id == plan.id
    end
  end

  describe "cross-authority isolation" do
    test "a device authority cannot create or read a plan against a project it does not own",
         context do
      package = publish_package_fixture()
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert {:error, :unauthorized} =
               ChangePlanStore.create(
                 {:device, other_workspace},
                 plan_attrs(context.device_project, package, context.now)
               )

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 {:device, other_workspace},
                 context.device_project.id,
                 context.now
               )
    end

    test "a hosted authority cannot reach a device project's stored plan", context do
      package = publish_package_fixture()

      assert {:ok, _plan} =
               ChangePlanStore.create(
                 device_authority(context),
                 plan_attrs(context.device_project, package, context.now)
               )

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 hosted_authority(context),
                 context.device_project.id,
                 context.now
               )
    end

    test "a device authority cannot reach a hosted project's stored plan", context do
      package = publish_package_fixture()

      assert {:ok, _plan} =
               ChangePlanStore.create(
                 hosted_authority(context),
                 plan_attrs(context.hosted_project, package, context.now)
               )

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.hosted_project.id,
                 context.now
               )
    end
  end

  describe "unsupported authority" do
    test "create refuses cleanly", context do
      package = publish_package_fixture()

      assert {:error, :unsupported_authority} =
               ChangePlanStore.create(
                 {:participant, context.account.id, Ecto.UUID.generate()},
                 plan_attrs(context.hosted_project, package, context.now)
               )
    end

    test "current refuses cleanly", context do
      assert {:error, :not_found} =
               ChangePlanStore.current(:nonsense, context.hosted_project.id, context.now)
    end
  end

  describe "RepositoryKitChangePlan.to_value/1 and from_value/1" do
    test "round-trips a valid plan unchanged", context do
      package = publish_package_fixture()

      # `build/1` never stamps `inserted_at` itself (only
      # `ChangePlanStore.Device.create/2` does, right before serializing —
      # see its own moduledoc comment), so a direct `build/1` call for this
      # value-layer test supplies it explicitly.
      attrs =
        context.hosted_project
        |> plan_attrs(package, context.now)
        |> Map.put(:inserted_at, context.now)

      assert {:ok, plan} = RepositoryKitChangePlan.build(attrs)

      value = RepositoryKitChangePlan.to_value(plan)
      assert {:ok, restored} = RepositoryKitChangePlan.from_value(value)
      assert RepositoryKitChangePlan.to_value(restored) == value
    end

    test "rejects a malformed value" do
      assert {:error, :invalid_plan} = RepositoryKitChangePlan.from_value(%{"not" => "a plan"})
    end

    test "rejects a tampered value", context do
      package = publish_package_fixture()

      attrs =
        context.hosted_project
        |> plan_attrs(package, context.now)
        |> Map.put(:inserted_at, context.now)

      assert {:ok, plan} = RepositoryKitChangePlan.build(attrs)

      tampered =
        plan
        |> RepositoryKitChangePlan.to_value()
        |> Map.put("base_commit", "not-a-commit")

      assert {:error, :invalid_plan} = RepositoryKitChangePlan.from_value(tampered)
    end
  end

  describe "Devices.DeviceStore.Local delete_project/1" do
    test "reports and removes repository_kit_change_plan keys, leaving another project's untouched",
         context do
      package = publish_package_fixture()

      {:ok, other_device_project} =
        Devices.register_project(%{
          name: "Other device change plan project",
          repository_fingerprint: "device-change-plan-repository-other",
          status: "connected"
        })

      assert {:ok, kept_plan} =
               ChangePlanStore.create(
                 {:device, context.device_workspace},
                 plan_attrs(other_device_project, package, context.now)
               )

      assert {:ok, _deleted_plan} =
               ChangePlanStore.create(
                 device_authority(context),
                 plan_attrs(context.device_project, package, context.now)
               )

      assert {:ok, result} = Devices.delete_project(context.device_project.id)
      assert result.deleted_repository_kit_change_plans == 1

      assert {:ok, restored} =
               ChangePlanStore.current(
                 {:device, context.device_workspace},
                 other_device_project.id,
                 context.now
               )

      assert restored.id == kept_plan.id

      assert {:error, :not_found} =
               ChangePlanStore.current(
                 device_authority(context),
                 context.device_project.id,
                 context.now
               )
    end
  end

  ## Fixtures

  defp device_authority(context), do: {:device, context.device_workspace}
  defp hosted_authority(context), do: {:hosted, context.account.id}

  defp plan_attrs(project, package, now, overrides \\ %{}) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        project_id: project.id,
        package_id: package.id,
        package_digest: package.digest,
        profile_version: 1,
        base_commit: String.duplicate("1", 40),
        root: ".",
        repository_provider: "github",
        repository_id: "example/repo",
        target_branch: "sdd-kit/test-#{System.unique_integer([:positive])}",
        operations: [valid_operation()],
        expires_at: now |> DateTime.add(900, :second) |> DateTime.truncate(:microsecond),
        plan_type: "install"
      },
      overrides
    )
  end

  defp valid_operation do
    %{
      "path" => "NEW_FILE.md",
      "kind" => "create",
      "conflict_severity" => nil,
      "proposed_sha256" => String.duplicate("a", 64),
      "existing_sha256" => nil,
      "proposed_size" => 10,
      "proposed_executable" => false,
      "proposed_content_base64" => "IyBOZXcK",
      "reason" => "not present in the repository at the base commit"
    }
  end
end
