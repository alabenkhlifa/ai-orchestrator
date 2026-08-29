defmodule SddOrchestrator.Worker.MacScopedConnectionEndToEndTest do
  @moduledoc """
  specs/39-mac-scoped-worker-connection Task 8 proof: the whole Mac-scoped
  round trip, end to end, and the diagnostic review that AC-10 demands of it.

  One scenario drives redemption, retention, setup, exchange, attachment, and
  reachability in that order against the real control plane — a dedicated
  `Bandit` listener bound to the already-running `SddOrchestratorWeb.Endpoint`
  on an OS-assigned port, exactly as
  `SddOrchestrator.Worker.GatewayConnectionTest` does, never
  `Phoenix.ChannelTest`'s in-process fake transport. `GatewayConnection` is a
  wire-level Slipstream client with no fake-transport mode, so anything short
  of a real socket would prove a different thing than the capability claims.

  What the scenario establishes, in one pass and with no project anywhere:

    * [AC-01/AC-02] a menu-bar redemption keeps both halves of the pairing
      result and produces a stored configuration with neither `project_id` nor
      `workspace_root`;
    * [AC-04/AC-05] that configuration exchanges its pairing credential for a
      workspace-scoped gateway credential without naming a project, and joins
      the Mac-scoped topic;
    * [AC-07] the control plane records the attachment, and only then does
      `ConnectionStatus` read `:connected`;
    * [AC-06] one `WorkerLivenessRefresher` pass makes the device workspace
      read `:detected` with no project ever created and no `Pairing.mark_seen/1`
      call anywhere in this file — the reachability comes from the control
      plane's own record of the attachment, not from a worker self-report;
    * [AC-10] neither the pairing credential nor the gateway credential, nor
      any fragment of either, appears in the diagnostics either side emitted
      while all of that happened. A refusal is reviewed the same way, because
      AC-10 names one explicitly.

  The Swift half of retention is not restated here. `MacPairingRetention`
  writes exactly these six fields through `bin/worker rpc` and is proved by
  `swift test` under `native/worker-app/MenuBarApp`; building the
  `%Configuration{}` directly is this suite's stand-in for that write, and it
  is the only stand-in in the scenario.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Delivery.CommandTransport.Channel, as: Transport
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.WorkerLivenessRefresher
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus
  alias SddOrchestrator.Worker.GatewayConnection

  # The width of the slice a fragment review looks for. Long enough that a
  # collision with unrelated log text is not a real possibility, short enough
  # that a truncated or partially-redacted secret still trips it.
  @fragment_length 12

  setup do
    # [specs/43 Task 2] `ConnectionStatus` now publishes every transition to a
    # file under `Configuration.home/1`. These tests drive the real callbacks,
    # so without redirecting the home they would write into the developer's own
    # `~/.sdd_orchestrator/worker` and could disturb a worker actually running
    # on this machine.
    worker_home =
      Path.join(System.tmp_dir!(), "sdd_worker_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worker_home)
    previous_home = Application.get_env(:sdd_orchestrator, :worker_home)
    Application.put_env(:sdd_orchestrator, :worker_home, worker_home)

    on_exit(fn ->
      if previous_home do
        Application.put_env(:sdd_orchestrator, :worker_home, previous_home)
      else
        Application.delete_env(:sdd_orchestrator, :worker_home)
      end

      File.rm_rf!(worker_home)
    end)

    # Started via `start_supervised!/1` so ExUnit's own per-test supervisor
    # owns shutdown ordering — see `GatewayConnectionTest`'s matching note.
    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    # `ConnectionStatus` is `:persistent_term`-backed and therefore VM-global,
    # so each test starts from the genuine "nothing observed yet" reading and
    # leaves nothing behind for another module to read.
    reset_connection_status()
    on_exit(&reset_connection_status/0)

    # This is what makes the leak review meaningful rather than vacuous.
    # `config/test.exs` runs the logger at `:warning`, and `capture_log`'s
    # handler sits below the primary level filter, so every `Logger.info` and
    # `Logger.debug` event — which is nearly everything either side emits on a
    # healthy round trip, including Phoenix's own request, socket, and channel
    # lines and Ecto's query log — would never reach the capture at all. A
    # review that only ever saw warnings would assert almost nothing. The level
    # is lifted for these tests only and restored afterwards.
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    %{control_plane_address: "http://127.0.0.1:#{port}"}
  end

  describe "AC-10: the Mac-scoped round trip, and the diagnostics it leaves behind" do
    test "a menu-bar redemption reaches a worker reported reachable with no project, leaking neither credential",
         %{control_plane_address: base} do
      # The whole scenario runs inside the capture, so the review covers the
      # redemption and the exchange themselves — not just what happened after
      # the secrets already existed.
      {%{
         device_workspace_id: device_workspace_id,
         worker: worker,
         credential: credential,
         gateway_credential: gateway_credential
       }, log} = with_log(fn -> drive_round_trip(base) end)

      assert_review_covers_both_sides(log, device_workspace_id)
      refute_credential_anywhere(log, credential, gateway_credential)

      # The attachment and the reading outlive the capture: nothing above
      # depended on the log being open.
      assert [{_channel_pid, contract}] = WorkerAttachment.attached(device_workspace_id)
      assert contract.worker_id == worker.id
      assert ConnectionStatus.status().status == :connected
    end

    test "a refused attachment leaks neither credential either",
         %{control_plane_address: base} do
      # AC-10 names a refusal explicitly, so it gets its own review. The
      # refusal is driven through `start_link/2`'s `:protocol_version` seam,
      # the same way `GatewayConnectionTest`'s AC-05 tests drive it: the
      # credential exchange still succeeds and a real socket still opens, so
      # both secrets genuinely exist and genuinely crossed the wire.
      {%{
         device_workspace_id: device_workspace_id,
         credential: credential,
         gateway_credential: gateway_credential
       }, log} = with_log(fn -> drive_refusal(base) end)

      assert log =~ "JOIN REFUSED"
      assert WorkerAttachment.attached(device_workspace_id) == []
      assert ConnectionStatus.status().status == :refused

      refute_credential_anywhere(log, credential, gateway_credential)
    end
  end

  # --- the scenario -------------------------------------------------------

  defp drive_round_trip(control_plane_address) do
    device_workspace_id = Ecto.UUID.generate()

    # 1. Redemption, the menu-bar path's own first step. Both halves of the
    #    result are kept: the credential is what the app stores, and the worker
    #    identity is what names the configuration. Keeping both is exactly what
    #    specs/38 discarded and Task 2 retains.
    {worker, credential} = redeem_pairing(device_workspace_id)

    assert worker.device_workspace_id == device_workspace_id
    assert worker.state == "active"
    assert is_nil(worker.last_seen_at)

    # 2. Retention and setup, as `MacPairingRetention` performs them: the six
    #    fields Task 1 left required, and neither `project_id` nor
    #    `workspace_root`, because this pairing was never told about a project.
    #    Building the struct here is the Elixir-side stand-in for the app's
    #    `bin/worker rpc` write; the Swift side is proved by its own suite.
    config = mac_configuration(control_plane_address, worker, credential)

    assert is_nil(config.project_id)
    assert is_nil(config.workspace_root)

    # 3. The exchange and the join. Nothing observed yet, and nothing may claim
    #    otherwise until the control plane answers.
    assert ConnectionStatus.status().status == :unknown

    {:ok, pid} = GatewayConnection.start_link(config)
    on_exit(fn -> stop_gateway(pid) end)

    # 4. The control plane recorded the attachment, for this Mac and this
    #    worker, on the full negotiated contract.
    wait_until(fn -> WorkerAttachment.attached(device_workspace_id) != [] end)

    assert [{_channel_pid, contract}] = WorkerAttachment.attached(device_workspace_id)
    assert contract.worker_id == worker.id
    assert contract.protocol_version == WorkerProtocol.version()
    assert contract.capabilities == WorkerProtocol.capabilities()

    # 5. Only now would the app say "Connected".
    wait_until(fn -> ConnectionStatus.status().status == :connected end)

    # 6. Reachability, from the control plane's own record. `Pairing.mark_seen/1`
    #    is called nowhere in this file, and no project exists to have opened, so
    #    a `:detected` reading can have come from nothing but the refresher pass
    #    over the Mac-keyed attachment registry.
    assert is_nil(reloaded_last_seen(worker))
    assert Devices.worker_status(device_workspace_id) == :unavailable

    assert WorkerLivenessRefresher.refresh() == 1

    refute is_nil(reloaded_last_seen(worker))
    assert Devices.worker_status(device_workspace_id) == :detected

    assert_no_project_anywhere()

    %{
      device_workspace_id: device_workspace_id,
      worker: worker,
      credential: credential,
      gateway_credential: gateway_credential(pid)
    }
  end

  defp drive_refusal(control_plane_address) do
    device_workspace_id = Ecto.UUID.generate()
    {worker, credential} = redeem_pairing(device_workspace_id)
    config = mac_configuration(control_plane_address, worker, credential)

    {:ok, pid} = GatewayConnection.start_link(config, protocol_version: 999)
    on_exit(fn -> stop_gateway(pid) end)

    wait_until(fn -> ConnectionStatus.status().status == :refused end)

    assert_no_project_anywhere()

    %{
      device_workspace_id: device_workspace_id,
      credential: credential,
      gateway_credential: gateway_credential(pid)
    }
  end

  # --- the review ---------------------------------------------------------

  # An absence proof is only worth what the capture actually contains, so the
  # review first proves it is looking at something: the worker runtime's own
  # lines, the control plane's HTTP exchange, its socket connection, its channel
  # join, and its database traffic. Without this a silent logger, a wrong level,
  # or a capture that never opened would make every `refute` below pass while
  # asserting nothing at all.
  defp assert_review_covers_both_sides(log, device_workspace_id) do
    # The worker runtime's side.
    assert log =~ "worker gateway transport connected for device workspace #{device_workspace_id}"
    assert log =~ "worker gateway joined worker_workspace:#{device_workspace_id}"

    # The control plane's side: the credential exchange, the socket the issued
    # credential opened, and the Mac-scoped join it was accepted for.
    #
    # The socket line matters most to the review below. The gateway credential
    # travels as a `token` query parameter, and Phoenix logs a socket's connect
    # parameters at `:info` — production's own level. It stays out of the log
    # only because `filter_parameters` redacts it, and this project sets no
    # `config :phoenix, :filter_parameters` of its own, so what redacts it is
    # Phoenix's shipped default (`["password", "token"]`). Asserting the line is
    # present is what turns the refusal below into a real check of that
    # redaction rather than a check that the line was never emitted.
    assert log =~ "POST /worker/gateway_credentials"
    assert log =~ "CONNECTED TO SddOrchestratorWeb.WorkerSocket"
    assert log =~ "JOINED worker_workspace:#{device_workspace_id}"

    # And its database traffic, which is where a credential carried as a query
    # parameter would surface.
    assert log =~ "QUERY OK"
  end

  # Both secrets, whole and in fragment, against the diagnostics both sides
  # emitted while the scenario ran. The worker runtime and the control plane
  # share one VM here, so one capture is genuinely both sides' log.
  defp refute_credential_anywhere(log, credential, gateway_credential) do
    refute String.contains?(log, credential),
           "the pairing credential appeared in the captured diagnostics"

    refute String.contains?(log, gateway_credential),
           "the gateway credential appeared in the captured diagnostics"

    # A whole-value check alone would pass a truncated or partially-redacted
    # leak, which is still a leak, so every window of the secret is looked for
    # and not only its leading slice.
    #
    # A pairing credential is transported as `"<worker id>.<secret>"`. The id
    # half is a public identifier the control plane stores, returns, and logs
    # by design — Ecto's own query parameters carry it at `:debug` — so
    # scanning it would test the identifier rather than the secret, and would
    # fail on entirely correct behavior. The window scan therefore runs over
    # the secret half, which is the half whose disclosure is the leak.
    refute_fragments(log, pairing_secret(credential), "the pairing credential's secret")

    # The gateway credential carries no such public half: it is one opaque
    # signed string, so every window of it is scanned.
    refute_fragments(log, gateway_credential, "the gateway credential")
  end

  defp refute_fragments(log, secret, label) do
    offset =
      secret
      |> fragment_windows()
      |> Enum.find_index(&String.contains?(log, &1))

    # The message names where the leaked slice sits, never what it says: a
    # failure that printed the secret to explain itself would be the leak.
    refute offset,
           "#{label} appeared in the captured diagnostics: " <>
             "a #{@fragment_length}-character slice at offset #{offset}"
  end

  defp fragment_windows(secret) do
    last_offset = String.length(secret) - @fragment_length

    if last_offset < 0 do
      [secret]
    else
      Enum.map(0..last_offset, &String.slice(secret, &1, @fragment_length))
    end
  end

  defp pairing_secret(credential) do
    [_worker_id, secret] = String.split(credential, ".", parts: 2)
    secret
  end

  # --- helpers ------------------------------------------------------------

  defp redeem_pairing(device_workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {worker, credential}
  end

  # Exactly the six fields `MacPairingRetention` writes, and nothing else: no
  # `project_id:` and no `workspace_root:` key at all, so both take the struct's
  # own `nil` default rather than being set to `nil` by a caller that was never
  # told about a project.
  defp mac_configuration(control_plane_address, worker, credential) do
    %Configuration{
      control_plane_address: control_plane_address,
      device_workspace_id: worker.device_workspace_id,
      worker_credential: credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      worker_id: worker.id
    }
  end

  # The gateway credential the exchange actually answered with, read from the
  # connection's own assign rather than re-signed here, so the review looks for
  # the exact string that crossed the wire.
  defp gateway_credential(pid), do: :sys.get_state(pid).assigns.gateway_credential

  defp reloaded_last_seen(worker), do: Repo.get!(LocalWorker, worker.id).last_seen_at

  # AC-06's premise, asserted rather than implied: no project was created, and
  # the project-keyed transport registry — the one a project-scoped attachment
  # would land in — stayed empty for the whole run.
  defp assert_no_project_anywhere do
    assert Repo.aggregate(Project, :count) == 0
    assert Registry.count(Transport.registry()) == 0
  end

  defp reset_connection_status do
    :persistent_term.erase({ConnectionStatus, :status})
    :ok
  end

  defp stop_gateway(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end
  end

  defp wait_until(fun, timeout \\ 3_000, interval \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(interval)
        do_wait_until(fun, deadline, interval)
    end
  end
end
