defmodule SddOrchestrator.Privacy.PortabilityRetentionTest do
  @moduledoc """
  Task 16 proof for immediate terminal cleanup and the 24-hour stranded
  encrypted-attempt ceiling across hosted and device storage.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Portability.{ImportAttempt, RestoreIntake}
  alias SddOrchestrator.Privacy.{Retention, RetentionPruner}
  alias SddOrchestrator.ProjectsFixtures

  @day 24 * 60 * 60

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    %{store_path: path}
  end

  test "prunes hosted and device attempts at the exact 24-hour boundary and is idempotent" do
    now = ~U[2026-07-28 12:00:00Z]
    workspace = hosted_workspace()
    {:ok, device_workspace} = Devices.establish_workspace()

    hosted_old = hosted_attempt(workspace)
    hosted_boundary = hosted_attempt(workspace)
    hosted_active = hosted_attempt(workspace)
    age_hosted(hosted_old, DateTime.add(now, -@day - 1, :second))
    age_hosted(hosted_boundary, DateTime.add(now, -@day, :second))
    age_hosted(hosted_active, DateTime.add(now, -@day + 1, :second))

    device_old = device_attempt(device_workspace)
    device_boundary = device_attempt(device_workspace)
    device_active = device_attempt(device_workspace)
    age_device(device_old, DateTime.add(now, -@day - 1, :second))
    age_device(device_boundary, DateTime.add(now, -@day, :second))
    age_device(device_active, DateTime.add(now, -@day + 1, :second), "validating")

    assert %{hosted_import_attempts: 2, device_import_attempts: 2} =
             Retention.prune_all(now)

    assert {:error, :not_found} = RestoreIntake.get(workspace, hosted_old.id)
    assert {:error, :not_found} = RestoreIntake.get(workspace, hosted_boundary.id)
    assert {:ok, %{status: "uploaded"}} = RestoreIntake.get(workspace, hosted_active.id)

    assert {:error, :not_found} = Devices.get_import_attempt(device_old.id)
    assert {:error, :not_found} = Devices.get_import_attempt(device_boundary.id)
    assert {:ok, %{status: "validating"}} = Devices.get_import_attempt(device_active.id)

    assert %{hosted_import_attempts: 0, device_import_attempts: 0} =
             Retention.prune_all(now)
  end

  test "reconciles a stranded device attempt after the device store returns", %{
    store_path: path
  } do
    now = ~U[2026-07-28 12:00:00Z]
    {:ok, device_workspace} = Devices.establish_workspace()
    attempt = device_attempt(device_workspace)
    age_device(attempt, DateTime.add(now, -@day - 1, :second))

    :ok = stop_supervised(Local)

    assert %{device_import_attempts: 0} = Retention.prune_all(now)

    start_supervised!({Local, path: path})
    assert {:ok, _stranded} = Devices.get_import_attempt(attempt.id)
    assert %{device_import_attempts: 1} = Retention.prune_all(now)
    assert {:error, :not_found} = Devices.get_import_attempt(attempt.id)
  end

  test "the supervisor restarts the pruner and the reconciled prune succeeds" do
    workspace = hosted_workspace()
    attempt = hosted_attempt(workspace)
    age_hosted(attempt, DateTime.add(DateTime.utc_now(), -@day - 60, :second))

    first_pid = start_supervised!({RetentionPruner, interval: :timer.hours(1)})
    Process.exit(first_pid, :kill)

    assert_eventually(fn ->
      case Process.whereis(RetentionPruner) do
        pid when is_pid(pid) -> pid != first_pid
        _not_restarted -> false
      end
    end)

    assert %{hosted_import_attempts: 1} = RetentionPruner.prune_with_lock()
    refute Repo.get(ImportAttempt, attempt.id)
  end

  test "the advisory lock prevents concurrent pruning" do
    workspace = hosted_workspace()
    attempt = hosted_attempt(workspace)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    age_hosted(attempt, DateTime.add(now, -@day - 60, :second))

    {:ok, connection} = Postgrex.start_link(postgrex_options())
    Process.unlink(connection)
    on_exit(fn -> if Process.alive?(connection), do: GenServer.stop(connection) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(
               connection,
               "SELECT pg_advisory_lock($1)",
               [RetentionPruner.advisory_lock_key()]
             )

    assert :locked = RetentionPruner.prune_with_lock(now)
    assert Repo.get(ImportAttempt, attempt.id)

    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(
               connection,
               "SELECT pg_advisory_unlock($1)",
               [RetentionPruner.advisory_lock_key()]
             )

    assert %{hosted_import_attempts: 1} = RetentionPruner.prune_with_lock(now)
    refute Repo.get(ImportAttempt, attempt.id)
  end

  test "terminal cleanup leaves no service package or secret-bearing attempt fields" do
    workspace = hosted_workspace()
    attempt = hosted_attempt(workspace)

    assert :ok = RestoreIntake.complete(workspace, attempt.id)
    refute Repo.get(ImportAttempt, attempt.id)

    fields = ImportAttempt.__schema__(:fields)

    assert fields == [
             :id,
             :device_workspace_id,
             :destination,
             :status,
             :encrypted_package,
             :expires_at,
             :workspace_id,
             :inserted_at,
             :updated_at
           ]

    refute Enum.any?(fields, fn field ->
             field
             |> Atom.to_string()
             |> String.match?(~r/passphrase|derived|decrypted|filename|path|package_hash/)
           end)
  end

  defp hosted_workspace do
    AccountsFixtures.account_fixture()
    |> ProjectsFixtures.workspace_fixture()
  end

  defp hosted_attempt(workspace) do
    {:ok, attempt} = RestoreIntake.start(workspace, "hosted", encrypted_package())
    attempt
  end

  defp device_attempt(device_workspace) do
    {:ok, attempt} = RestoreIntake.start(device_workspace, "device", encrypted_package())
    attempt
  end

  defp age_hosted(attempt, inserted_at) do
    Repo.update_all(
      from(stored in ImportAttempt, where: stored.id == ^attempt.id),
      set: [
        inserted_at: inserted_at,
        updated_at: inserted_at,
        expires_at: DateTime.add(inserted_at, @day, :second)
      ]
    )
  end

  defp age_device(attempt, inserted_at, status \\ "uploaded") do
    {:ok, stored} = Devices.get_import_attempt(attempt.id)

    {:ok, _aged} =
      Devices.put_import_attempt(%{
        stored
        | inserted_at: inserted_at,
          updated_at: inserted_at,
          expires_at: DateTime.add(inserted_at, @day, :second),
          status: status
      })
  end

  defp encrypted_package, do: :crypto.strong_rand_bytes(128)

  defp assert_eventually(check, remaining \\ 300)

  defp assert_eventually(check, remaining) when remaining > 0 do
    if check.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(check, remaining - 1)
    end
  end

  defp assert_eventually(_check, 0), do: flunk("condition did not become true")

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end

  defp store_path do
    directory =
      Path.join(
        System.tmp_dir!(),
        "sdd_portability_retention_#{System.unique_integer([:positive])}"
      )

    Path.join(directory, "store.dets")
  end
end
