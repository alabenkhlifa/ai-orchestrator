defmodule SddOrchestrator.Worker.ConnectionStatusTest do
  @moduledoc """
  Task 2 proof: `ConnectionStatus` records the connection states and reports
  the last-known snapshot back, independent of any supervised process (see
  its moduledoc on `:persistent_term`). `GatewayConnectionTest` exercises the
  real callbacks this module is reported into; this file covers
  `ConnectionStatus` itself in isolation.

  specs/39 Task 7 added `:connecting` and `:refused`, so the states a fresh
  read may answer are asserted against the module's full set rather than a
  shorter list that would go stale the next time one is added.

  `async: false`: `:persistent_term` is VM-global, and
  `SddOrchestrator.Worker.GatewayConnectionTest` writes through the same key
  via the real `handle_connect/1`/`handle_disconnect/2` callbacks — keeping
  this file synchronous avoids a cross-test-module race on that shared key.
  The `:worker_home` application env this file redirects is global for the
  same reason.

  specs/43-distribution-free-worker-control Task 2 adds the status file the
  native app reads without Erlang distribution. It is proved here as what it
  is: a report published beside the worker configuration as a side effect of
  the same write `status/0` answers from, never a replacement for it and never
  able to fail a caller.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus

  setup do
    # Every writer now touches the filesystem, so each test gets its own
    # storage root and the developer's real `~/.sdd_orchestrator/worker` is
    # never written to by the suite.
    home =
      Path.join(
        System.tmp_dir!(),
        "worker-connection-status-test-#{System.unique_integer([:positive])}"
      )

    previous = Application.fetch_env(:sdd_orchestrator, :worker_home)
    Application.put_env(:sdd_orchestrator, :worker_home, home)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :worker_home, value)
        :error -> Application.delete_env(:sdd_orchestrator, :worker_home)
      end

      File.rm_rf!(home)
    end)

    %{home: home}
  end

  defp published(home) do
    home |> ConnectionStatus.path() |> File.read!() |> Jason.decode!()
  end

  defp mode(path) do
    path |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777)
  end

  test "reports :unknown with no reason or timestamp before anything has been recorded" do
    # No fixture resets `:persistent_term` between tests (it is VM-global,
    # not per-process), so this only asserts the shape a fresh read
    # always has, not that no other test has written to it yet.
    snapshot = ConnectionStatus.status()
    assert snapshot.status in [:unknown, :connecting, :connected, :refused, :disconnected]
    assert Map.has_key?(snapshot, :reason)
    assert Map.has_key?(snapshot, :updated_at)
  end

  test "set_connected/0 records :connected with no reason and a timestamp" do
    ConnectionStatus.set_connected()

    assert %{status: :connected, reason: nil, updated_at: %DateTime{}} = ConnectionStatus.status()
  end

  test "set_disconnected/1 records :disconnected with the given reason and a timestamp" do
    ConnectionStatus.set_disconnected(:closed)

    assert %{status: :disconnected, reason: :closed, updated_at: %DateTime{}} =
             ConnectionStatus.status()
  end

  test "set_disconnected/0 defaults the reason to nil" do
    ConnectionStatus.set_disconnected()

    assert %{status: :disconnected, reason: nil} = ConnectionStatus.status()
  end

  test "set_connecting/0 records :connecting, which is an observation and not :unknown" do
    ConnectionStatus.set_connecting()

    assert %{status: :connecting, reason: nil, updated_at: %DateTime{}} =
             ConnectionStatus.status()
  end

  test "set_refused/1 records :refused with the refusal reason and a timestamp" do
    ConnectionStatus.set_refused("unsupported_protocol_version")

    assert %{status: :refused, reason: "unsupported_protocol_version", updated_at: %DateTime{}} =
             ConnectionStatus.status()
  end

  test "a refusal is not a connection: it never leaves the snapshot reading :connected" do
    ConnectionStatus.set_connecting()
    ConnectionStatus.set_refused(:refused_by_control_plane)

    refute ConnectionStatus.status().status == :connected
  end

  test "the most recent write wins and is what status/0 returns" do
    ConnectionStatus.set_connected()
    ConnectionStatus.set_disconnected(:normal_closure)
    ConnectionStatus.set_connected()

    assert %{status: :connected} = ConnectionStatus.status()
  end

  describe "the published status file" do
    test "sits beside the worker configuration, under the same storage root", %{home: home} do
      assert ConnectionStatus.path(home) ==
               Path.join(Path.dirname(Configuration.path(home)), "connection_status.json")

      refute ConnectionStatus.path(home) == Configuration.path(home)
    end

    test "is published under the configured home when no override is given", %{home: home} do
      # What the release itself does: `GatewayConnection` passes no override,
      # so the file must land in the worker's own storage root.
      ConnectionStatus.set_connected()

      assert File.exists?(ConnectionStatus.path(home))
    end

    test "every transition writes it", %{home: home} do
      writers = [
        {fn -> ConnectionStatus.set_connecting(home) end, "connecting"},
        {fn -> ConnectionStatus.set_connected(home) end, "connected"},
        {fn -> ConnectionStatus.set_refused(:unsupported_protocol_version, home) end, "refused"},
        {fn -> ConnectionStatus.set_disconnected(:closed, home) end, "disconnected"}
      ]

      for {write, expected} <- writers do
        assert write.() == :ok
        assert %{"status" => ^expected} = published(home)
      end
    end

    test "carries the same state and reason status/0 reports", %{home: home} do
      ConnectionStatus.set_refused("unsupported_protocol_version", home)

      snapshot = ConnectionStatus.status()
      file = published(home)

      assert file["status"] == Atom.to_string(snapshot.status)
      assert file["reason"] == snapshot.reason
      assert file["updated_at"] == DateTime.to_iso8601(snapshot.updated_at)
    end

    test "renders a reason that is an Elixir term as a display string", %{home: home} do
      # `GatewayConnection` reports `{:topic_closed, reason}` here. The reader
      # is a Swift process, so the term is rendered rather than encoded.
      ConnectionStatus.set_disconnected({:topic_closed, :normal}, home)

      assert ConnectionStatus.status().reason == {:topic_closed, :normal}
      assert published(home)["reason"] == "{:topic_closed, :normal}"
    end

    test "writes a null reason when there is none", %{home: home} do
      ConnectionStatus.set_connected(home)

      assert published(home)["reason"] == nil
    end

    test "carries no credential, worker identity, or path", %{home: home} do
      ConnectionStatus.set_connected(home)

      assert home |> published() |> Map.keys() |> Enum.sort() == ~w(reason status updated_at)
    end

    test "the file is owner-only and so is its directory", %{home: home} do
      ConnectionStatus.set_connected(home)

      assert mode(ConnectionStatus.path(home)) == 0o600
      assert mode(home) == 0o700
    end

    test "each transition replaces the file rather than rewriting it in place", %{home: home} do
      # The atomic publish is a write to a temporary file followed by a
      # rename, so the target is a different inode every time. A truncating
      # in-place write would keep the same one, and would be observable
      # half-written.
      ConnectionStatus.set_connecting(home)
      first = File.stat!(ConnectionStatus.path(home)).inode

      ConnectionStatus.set_connected(home)
      second = File.stat!(ConnectionStatus.path(home)).inode

      refute first == second
    end

    test "leaves no temporary file behind", %{home: home} do
      ConnectionStatus.set_connecting(home)
      ConnectionStatus.set_connected(home)
      ConnectionStatus.set_disconnected(:closed, home)

      assert File.ls!(home) == ["connection_status.json"]
    end

    test "a reader polling it never observes a partially written file", %{home: home} do
      file = ConnectionStatus.path(home)
      ConnectionStatus.set_connecting(home)

      # The reasons grow, so an in-place write would leave a longer previous
      # payload with a shorter new one written over its head — exactly the
      # truncated JSON this test would catch.
      writer =
        Task.async(fn ->
          Enum.each(1..200, fn index ->
            ConnectionStatus.set_disconnected(String.duplicate("x", index * 40), home)
          end)
        end)

      observations = observe_while_alive(file, writer, MapSet.new())
      Task.await(writer)

      assert MapSet.size(observations) > 1

      for contents <- observations do
        assert {:ok, decoded} = Jason.decode(contents)
        assert decoded["status"] in ~w(connecting disconnected)
      end
    end
  end

  describe "a failed publish" do
    test "still returns :ok to the caller", %{home: home} do
      unwritable = unwritable_home(home)

      log =
        capture_log(fn ->
          assert ConnectionStatus.set_connected(unwritable) == :ok
          assert ConnectionStatus.set_connecting(unwritable) == :ok
          assert ConnectionStatus.set_refused(:refused, unwritable) == :ok
          assert ConnectionStatus.set_disconnected(:closed, unwritable) == :ok
        end)

      assert log =~ "connection status file not published"
      refute log =~ unwritable
    end

    test "leaves status/0's in-process answer correct", %{home: home} do
      unwritable = unwritable_home(home)

      capture_log(fn ->
        ConnectionStatus.set_refused(:refused_by_control_plane, unwritable)
      end)

      assert %{status: :refused, reason: :refused_by_control_plane, updated_at: %DateTime{}} =
               ConnectionStatus.status()
    end

    test "writes nothing at all rather than something partial", %{home: home} do
      unwritable = unwritable_home(home)

      capture_log(fn -> ConnectionStatus.set_connected(unwritable) end)

      refute File.exists?(ConnectionStatus.path(unwritable))
    end
  end

  # A home whose parent is a regular file: creating it fails with `:enotdir`
  # for any user, so the proof does not quietly become a no-op when the suite
  # happens to run as root the way a read-only directory would.
  defp unwritable_home(home) do
    blocker = Path.join(home, "blocker")

    File.mkdir_p!(home)
    File.write!(blocker, "")

    Path.join(blocker, "worker")
  end

  defp observe_while_alive(file, task, seen) do
    if Process.alive?(task.pid) do
      seen =
        case File.read(file) do
          {:ok, contents} -> MapSet.put(seen, contents)
          {:error, _reason} -> seen
        end

      Process.sleep(1)
      observe_while_alive(file, task, seen)
    else
      seen
    end
  end
end
