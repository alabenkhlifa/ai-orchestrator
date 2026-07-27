defmodule SddOrchestrator.Devices.DeviceRegistrationTest do
  @moduledoc """
  Task 6 proof: atomic device-project registration in the device store, applying
  the shared workspace-scoped case-insensitive naming and one-project-per-repository
  rules, and treating post-loss reconnection as new history rather than restoration.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceProject
  alias SddOrchestrator.Devices.DeviceStore.Local

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    %{path: path}
  end

  defp store_path do
    Path.join(System.tmp_dir!(), "dev_reg_#{System.unique_integer([:positive])}/store.dets")
  end

  defp attrs(overrides) do
    Map.merge(
      %{
        name: "My Repo",
        repository_fingerprint: "fp-#{System.unique_integer([:positive])}",
        status: "connected"
      },
      overrides
    )
  end

  test "registers an accountless device project" do
    assert {:ok, %DeviceProject{} = project} =
             Devices.register_project(attrs(%{name: "My Repo", repository_fingerprint: "fp-1"}))

    assert project.name == "My Repo"
    assert project.storage_mode == "device"
    assert project.repository_fingerprint == "fp-1"
    assert project.status == "connected"
    assert {:ok, ^project} = Devices.get_project(project.id)
    assert project in Devices.list_projects()
  end

  test "rejects a blank or control-character name" do
    assert {:error, :invalid_name} = Devices.register_project(attrs(%{name: "   "}))
    assert {:error, :invalid_name} = Devices.register_project(attrs(%{name: "bad\aname"}))
  end

  test "requires a repository fingerprint" do
    assert {:error, :fingerprint_required} =
             Devices.register_project(attrs(%{repository_fingerprint: nil}))
  end

  test "enforces one project per repository fingerprint" do
    {:ok, first} =
      Devices.register_project(attrs(%{name: "A", repository_fingerprint: "fp-x"}))

    assert {:error, {:repository_already_linked, existing}} =
             Devices.register_project(attrs(%{name: "B", repository_fingerprint: "fp-x"}))

    assert existing.id == first.id
  end

  test "enforces case-insensitive workspace-scoped name uniqueness" do
    {:ok, _} = Devices.register_project(attrs(%{name: "Repo", repository_fingerprint: "fp-a"}))

    assert {:error, :name_taken} =
             Devices.register_project(attrs(%{name: "repo", repository_fingerprint: "fp-b"}))
  end

  test "allocates the next available suffix when the caller accepts the default" do
    {:ok, _} =
      Devices.register_project(attrs(%{name: "example", repository_fingerprint: "fp-1"}))

    {:ok, one} =
      Devices.register_project(attrs(%{name: "example", repository_fingerprint: "fp-2"}),
        allocate_suffix?: true
      )

    {:ok, two} =
      Devices.register_project(attrs(%{name: "example", repository_fingerprint: "fp-3"}),
        allocate_suffix?: true
      )

    assert one.name == "example-1"
    assert two.name == "example-2"
  end

  test "finds a project by fingerprint for reconnection and misses unknown ones" do
    {:ok, project} = Devices.register_project(attrs(%{repository_fingerprint: "fp-find"}))

    assert {:ok, found} = Devices.find_by_fingerprint("fp-find")
    assert found.id == project.id
    assert {:error, :not_found} = Devices.find_by_fingerprint("fp-missing")
  end

  test "after data loss, reconnecting a repository starts new history rather than restoring it" do
    {:ok, lost} =
      Devices.register_project(attrs(%{name: "Repo", repository_fingerprint: "fp-loss"}))

    stop_supervised!(Local)
    fresh = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(fresh)) end)
    start_supervised!({Local, path: fresh})

    assert Devices.list_projects() == []
    assert {:error, :not_found} = Devices.get_project(lost.id)

    assert {:ok, restarted} =
             Devices.register_project(attrs(%{name: "Repo", repository_fingerprint: "fp-loss"}))

    refute restarted.id == lost.id
  end
end
