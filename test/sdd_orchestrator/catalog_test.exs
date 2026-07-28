defmodule SddOrchestrator.CatalogTest do
  @moduledoc """
  Task 5 proof for the signed-in combined catalog composition (AC-10, AC-11).

  Composition shows each authorized destination record once with its storage mode
  and current availability, keeps records that share a stable project id separate
  and flagged as an identity conflict, and is strictly non-mutating: it changes no
  ownership, storage mode, or identity, creates no records, and persists no
  cross-boundary link.

  The device store is a singleton GenServer not started in test, so this case
  starts its own isolated instance on a unique path in an `async: false` case.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Catalog
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    account = AccountsFixtures.account_fixture()
    %{account: account, workspace: ProjectsFixtures.workspace_fixture(account)}
  end

  describe "combined/3 (AC-10)" do
    test "shows on-device and hosted projects each once with their mode and availability", %{
      account: account,
      workspace: workspace
    } do
      hosted = ProjectsFixtures.registered_project(workspace, name: "Hosted App")

      {:ok, device} =
        Devices.register_project(%{
          name: "Local App",
          repository_fingerprint: "fp-catalog-1",
          status: "connected"
        })

      entries = Catalog.combined(account, workspace, revalidate: false)

      assert length(entries) == 2

      hosted_entry = Enum.find(entries, &(&1.storage_mode == "hosted"))
      device_entry = Enum.find(entries, &(&1.storage_mode == "device"))

      assert hosted_entry.id == hosted.id
      assert hosted_entry.name == "Hosted App"
      assert hosted_entry.availability in [:connected, :disconnected, :temporarily_unavailable]
      assert hosted_entry.route == "/projects/#{hosted.id}"

      assert device_entry.id == device.id
      assert device_entry.name == "Local App"
      assert device_entry.availability in [:available, :unavailable]
      assert device_entry.route == "/local/projects/#{device.id}"
      # A device repository exposes no shareable label (only its fingerprint).
      assert is_nil(device_entry.repository_label)

      refute hosted_entry.identity_conflict?
      refute device_entry.identity_conflict?
    end
  end

  describe "non-mutating composition (AC-11)" do
    test "changes no ownership, storage mode, or identity and creates no records", %{
      account: account,
      workspace: workspace
    } do
      hosted = ProjectsFixtures.registered_project(workspace, name: "Keep")

      {:ok, device} =
        Devices.register_project(%{
          name: "Keep Local",
          repository_fingerprint: "fp-catalog-2",
          status: "connected"
        })

      _ = Catalog.combined(account, workspace, revalidate: false)

      # The hosted project is unchanged and still hosted-owned.
      reloaded = Repo.get!(Project, hosted.id)
      assert reloaded.storage_mode == "hosted"
      assert reloaded.workspace_id == workspace.id

      # The device project stays device-owned; the personal workspace never
      # acquired or changed it.
      {:ok, device_reloaded} = Devices.get_project(device.id)
      assert device_reloaded.storage_mode == "device"
      assert device_reloaded.id == device.id

      # No records were created or duplicated by composition.
      assert Repo.aggregate(Project, :count) == 1
      assert length(Devices.list_projects()) == 1
    end
  end

  describe "mark_identity_conflicts/1 (AC-10, AC-11)" do
    test "flags records sharing a stable id and keeps each separate" do
      id = Ecto.UUID.generate()

      entries =
        Catalog.mark_identity_conflicts([
          entry(id, "hosted", "/projects/#{id}"),
          entry(id, "device", "/local/projects/#{id}")
        ])

      # Both remain present, separate, and flagged — neither is merged or chosen.
      assert length(entries) == 2
      assert Enum.all?(entries, & &1.identity_conflict?)
      assert entries |> Enum.map(& &1.storage_mode) |> Enum.sort() == ["device", "hosted"]
    end

    test "does not flag records with distinct ids" do
      entries =
        Catalog.mark_identity_conflicts([
          entry(Ecto.UUID.generate(), "hosted", "/projects/a"),
          entry(Ecto.UUID.generate(), "device", "/local/projects/b")
        ])

      refute Enum.any?(entries, & &1.identity_conflict?)
    end
  end

  defp entry(id, mode, route) do
    %{
      id: id,
      name: "Shared Project",
      storage_mode: mode,
      availability: if(mode == "hosted", do: :connected, else: :available),
      repository_label: nil,
      route: route,
      identity_conflict?: false
    }
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_catalog_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
