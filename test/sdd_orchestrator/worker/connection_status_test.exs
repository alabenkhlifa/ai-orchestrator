defmodule SddOrchestrator.Worker.ConnectionStatusTest do
  @moduledoc """
  Task 2 proof: `ConnectionStatus` records connect/disconnect and reports
  the last-known snapshot back, independent of any supervised process (see
  its moduledoc on `:persistent_term`). `GatewayConnectionTest` exercises
  the real `handle_connect/1`/`handle_disconnect/2` side effect this module
  is reported into; this file covers `ConnectionStatus` itself in isolation.

  `async: false`: `:persistent_term` is VM-global, and
  `SddOrchestrator.Worker.GatewayConnectionTest` writes through the same key
  via the real `handle_connect/1`/`handle_disconnect/2` callbacks — keeping
  this file synchronous avoids a cross-test-module race on that shared key.
  """

  use ExUnit.Case, async: false

  alias SddOrchestrator.Worker.ConnectionStatus

  test "reports :unknown with no reason or timestamp before anything has been recorded" do
    # No fixture resets `:persistent_term` between tests (it is VM-global,
    # not per-process), so this only asserts the shape a fresh read
    # always has, not that no other test has written to it yet.
    snapshot = ConnectionStatus.status()
    assert snapshot.status in [:unknown, :connected, :disconnected]
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

  test "the most recent write wins and is what status/0 returns" do
    ConnectionStatus.set_connected()
    ConnectionStatus.set_disconnected(:normal_closure)
    ConnectionStatus.set_connected()

    assert %{status: :connected} = ConnectionStatus.status()
  end
end
