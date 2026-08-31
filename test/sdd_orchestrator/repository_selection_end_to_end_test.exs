defmodule SddOrchestrator.RepositorySelectionEndToEndTest do
  @moduledoc """
  specs/40-worker-repository-selection Task 9 proof: one folder selection
  travels the whole way, and the review AC-08 asks for is written as
  assertions.

  This file is the slice's closing evidence. It stands behind two acceptance
  criteria:

    * [AC-08] a completed selection carries the repository identity and the
      folder name only. No path, remote URL, Git history, file name, or content
      reaches the transported payload, the request the control plane holds, the
      result the requester is given, or a log line on either side.
    * [AC-11] the answer the Mac app wrote is deleted the moment the release
      reads it, and the pending file goes with the request, so nothing on disk
      names the chosen folder once the selection ends.

  Every other task proved one half. This one makes the halves meet. A real
  worker release dials a real control plane over a real socket (a dedicated
  `Bandit` listener bound to `SddOrchestratorWeb.Endpoint`, exactly as
  `SddOrchestrator.Worker.MacScopedConnectionEndToEndTest` does), a real
  request is pushed to it, a real Git repository on this machine is chosen, and
  the answer comes back through the real codec into the real request table.

  The Mac app is the one stand-in, because there is no Swift in a `mix test`.
  Its whole part in the exchange is a single file, so the scenario writes that
  file the way `SelectionAnswerWriter.swift` writes it: the same two keys, the
  same owner-only mode, and the same create-then-rename, which matters because
  the release deletes the answer as soon as it reads it and a half-written one
  would be a lost answer rather than a retried one.

  ## Why the leak review is assertions

  AC-08 reads as an inspection: look at the payloads and at the logs, and find
  only identities and a folder name. A person doing that proves the one run
  they looked at, and proves nothing about the next change to the codec, the
  channel, or the worker. So the review runs here instead, and it runs on a
  fixture built to be conspicuous: a marked parent directory, a marked file
  name inside the repository, and a marked remote. The scenario asserts that
  none of those strings, and no commit id from the repository's history,
  appears in the diagnostics either side emitted or in the frames that actually
  crossed the channel, captured by tracing the attachment's own channel
  process.

  An absence proof is worth only what it looked at, so the review first proves
  it is looking at something: the worker's own lines, the control plane's
  socket, channel, and inbound-frame lines, and its database traffic. Without
  that, a silent logger or a capture that never opened would make every
  `refute` below pass while asserting nothing.

  `async: false`: the request table is one named process for the whole node,
  the worker release's request holder is another, and this file selects the
  real transport and the worker storage root in application environment.
  """

  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias Phoenix.Socket.Message
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Portability.HostedLocalRepositoryFolder
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.AttachmentCodec
  alias SddOrchestrator.RepositorySelection.SelectionRequest
  alias SddOrchestrator.RepositorySelection.SelectionResult
  alias SddOrchestrator.RepositorySelection.Server
  alias SddOrchestrator.RepositorySelection.Transport.Attachment
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.ConnectionStatus
  alias SddOrchestrator.Worker.GatewayConnection
  alias SddOrchestrator.Worker.RepositorySelection, as: WorkerSelection

  @transport_key :repository_selection_transport

  # Shorter than the release's own half-second so a scenario does not wait on a
  # production timer. It is the same `:poll_interval` seam Task 3's tests use.
  @poll_interval 25

  # Long enough that a person would still be looking at the panel, short enough
  # that a scenario which never gets answered fails on its own assertion rather
  # than on the suite's timeout.
  @request_timeout_ms 30_000
  @answer_timeout_ms 5_000

  # The marks the leak review looks for. They are put where a careless
  # implementation would pick them up: on the remote, on a file inside the
  # working tree, and on the directory holding the repository.
  @remote_url "https://example.invalid/leak-marker.git"
  @remote_marker "leak-marker"
  @secret_file "secret-file-name-marker.txt"
  @parent_marker "sdd_selection_parent_marker"

  # The width of the slice a commit-id review looks for, so a truncated or
  # abbreviated object id trips it too.
  @fragment_length 12

  setup do
    worker_home =
      Path.join(System.tmp_dir!(), "sdd_selection_home_#{System.unique_integer([:positive])}")

    File.mkdir_p!(worker_home)
    put_env(:worker_home, worker_home)
    on_exit(fn -> File.rm_rf!(worker_home) end)

    # `config/test.exs` selects the stand-in adapter, and this file proves the
    # real attachment transport, so the choice is made here rather than assumed.
    put_env(@transport_key, Attachment)

    bandit =
      start_supervised!(
        {Bandit, plug: SddOrchestratorWeb.Endpoint, scheme: :http, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    # `ConnectionStatus` is `:persistent_term`-backed and therefore VM-global,
    # so each test starts from "nothing observed yet" and leaves nothing behind.
    reset_connection_status()
    on_exit(&reset_connection_status/0)

    # The request holder the worker release runs, started the way
    # `SddOrchestrator.Worker.Supervisor` starts it: no home override, so it
    # reads the storage root above through `Configuration.home/1`.
    start_supervised!({WorkerSelection, poll_interval: @poll_interval}, restart: :temporary)

    %{control_plane_address: "http://127.0.0.1:#{port}", worker_home: worker_home}
  end

  describe "AC-08: an accountless selection, end to end" do
    test "the chosen folder comes back as a name, the candidate it matched, and a fresh identity",
         context do
      attached = attach_worker(context)
      repository = marked_repository_fixture()
      unrelated = marked_repository_fixture()

      {:ok, request_id} =
        RepositorySelection.request(
          %{device_workspace_id: attached.device_workspace_id},
          attached.worker_id,
          candidates: [
            %{ref: "this-repository", identity: portable_identity!(repository)},
            %{ref: "another-repository", identity: portable_identity!(unrelated)}
          ],
          generate: true,
          timeout_ms: @request_timeout_ms
        )

      # The release published the request for the app, holding the id and the
      # expiry and nothing else. The candidates stayed in its memory.
      pending = await_pending!(request_id)
      assert Enum.sort(Map.keys(pending)) == ["expires_at", "request_id"]

      answer_as_the_app!(request_id, repository)

      assert_receive {:repository_selection, ^request_id,
                      {:selected, %SelectionResult{} = result}},
                     @answer_timeout_ms

      assert result.request_id == request_id
      assert result.folder_name == Path.basename(repository)
      assert result.matches == ["this-repository"]
      assert {:ok, true} = PortableRepositoryIdentity.match(repository, result.identity)
      assert {:ok, false} = PortableRepositoryIdentity.match(unrelated, result.identity)

      # [AC-11] The release deletes the answer before it computes anything from
      # it, so by the time a result exists the file is already gone. The
      # pending file is removed inside the same callback, and a `pending/0` call
      # can only be served after that callback returns, so both are decided
      # rather than waited on.
      refute File.exists?(WorkerSelection.answer_path())
      assert WorkerSelection.pending() == nil
      refute File.exists?(WorkerSelection.pending_path())
    end
  end

  describe "AC-08: a hosted-shaped selection" do
    test "the project's identity comes back as the single match, with no new identity generated",
         context do
      attached = attach_worker(context)
      repository = marked_repository_fixture()
      identity = portable_identity!(repository)

      # The exact call `Portability.HostedLocalRepositoryFolder` makes for a
      # first connection: one candidate, the project's own identity, and no
      # generation, because the project already has one. The connect gate that
      # consumes the proof is Task 6's proof, not this one; what is proved here
      # is that the selection half answers the shape that gate is given.
      scope = %{
        device_workspace_id: attached.device_workspace_id,
        project_id: Ecto.UUID.generate()
      }

      {:ok, request_id} =
        HostedLocalRepositoryFolder.request(scope, attached.worker_id, identity)

      await_pending!(request_id)
      answer_as_the_app!(request_id, repository)

      assert_receive {:repository_selection, ^request_id,
                      {:selected, %SelectionResult{} = result}},
                     @answer_timeout_ms

      assert result.folder_name == Path.basename(repository)
      assert result.matches == ["project"]
      assert is_nil(result.identity)

      # The verdict the gate is handed, built from that answer.
      assert HostedLocalRepositoryFolder.proof(result, identity).(identity) == {:ok, true}

      refute File.exists?(WorkerSelection.answer_path())
      assert WorkerSelection.pending() == nil
    end
  end

  describe "AC-08: the review, as assertions" do
    test "a completed round trip leaves no location in the diagnostics or in the frames",
         context do
      repository = marked_repository_fixture()
      markers = leak_markers(repository)

      # The whole scenario runs inside the capture, attachment included, so the
      # review covers the exchange that set the round trip up and not only what
      # happened once it was already running.
      {reviewed, log} = with_debug_log(fn -> drive_reviewed_round_trip(context, repository) end)

      transcript = transcript(reviewed.traffic)
      request_payload = transported_request!(reviewed.traffic)
      result_payload = transported_result!(reviewed.traffic)

      assert_review_covers_both_sides(log, reviewed.device_workspace_id)
      assert_review_covers_the_frames(transcript, reviewed.result)

      refute_leak(log, markers, "the captured diagnostics")
      refute_leak(transcript, markers, "the frames that crossed the channel")

      # The wire vocabulary, closed on both sides. A key added to either payload
      # is a widening of what may leave a Mac, so it fails here first.
      assert Enum.sort(Map.keys(request_payload)) == [
               "candidates",
               "expires_at",
               "generate",
               "request_id"
             ]

      assert Enum.sort(Map.keys(result_payload)) == [
               "folder_name",
               "identity",
               "matches",
               "outcome",
               "request_id"
             ]

      assert Enum.sort(Map.keys(result_payload)) -- AttachmentCodec.result_keys() == []

      # A location spells itself with a separator. A folder name is one segment
      # and may not carry one at all, an identity and an expiry never do, and a
      # candidate cannot hide one inside a nested value.
      for value <- strings(request_payload) ++ strings(result_payload) do
        refute String.contains?(value, ["/", "\\"]),
               "a transported value carried a path separator"
      end

      # The request the control plane held open while the panel was up, and the
      # result the requester was given. Neither has a field a location could sit
      # in, which is asserted as the field list itself so that adding one is
      # caught here rather than reviewed by eye later.
      assert struct_fields(reviewed.held) == [
               :candidates,
               :device_workspace_id,
               :expires_at,
               :generate?,
               :id,
               :project_id,
               :requester,
               :worker_id
             ]

      assert struct_fields(reviewed.result) == [
               :folder_name,
               :identity,
               :matches,
               :outcome,
               :request_id
             ]

      refute_leak(readable(reviewed.held), markers, "the request the control plane held")
      refute_leak(readable(reviewed.result), markers, "the result the requester received")

      # And the round trip really did complete, so the review above is a review
      # of a selection rather than of a request that went nowhere.
      assert reviewed.result.outcome == :selected
      assert reviewed.result.folder_name == Path.basename(repository)
      assert reviewed.result.matches == ["this-repository"]
    end
  end

  # --- the reviewed scenario ----------------------------------------------

  defp drive_reviewed_round_trip(context, repository) do
    attached = attach_worker(context)

    # What crossed the channel is read from the channel process itself: the
    # payload it was handed to push, the frame the worker sent back, and the
    # serialized bytes in between. Nothing here reconstructs a payload from the
    # codec, because the point is what actually travelled.
    assert :erlang.trace(attached.channel, true, [:send, :receive]) == 1

    {:ok, request_id} =
      RepositorySelection.request(
        %{device_workspace_id: attached.device_workspace_id},
        attached.worker_id,
        candidates: [%{ref: "this-repository", identity: portable_identity!(repository)}],
        generate: true,
        timeout_ms: @request_timeout_ms
      )

    await_pending!(request_id)

    # Read while the panel is notionally open, which is the only moment the
    # request table holds anything at all.
    held = held_request(request_id)

    answer_as_the_app!(request_id, repository)

    assert_receive {:repository_selection, ^request_id, {:selected, %SelectionResult{} = result}},
                   @answer_timeout_ms

    # The requester is told from inside the channel's own `handle_in`, so the
    # answer arrives here before that callback has returned and before the
    # control plane has logged the frame it handled. A synchronous call to the
    # channel queues behind that callback, which is what makes the review of its
    # diagnostics a review of this round trip rather than a race with it.
    :sys.get_state(attached.channel)

    :erlang.trace(attached.channel, false, [:send, :receive])

    Map.merge(attached, %{result: result, held: held, traffic: drain_trace()})
  end

  # --- the review ---------------------------------------------------------

  # The capture is only worth what it contains, so it is proved to hold both
  # sides of the exchange before anything is refuted against it.
  defp assert_review_covers_both_sides(log, device_workspace_id) do
    assert log =~ "worker gateway transport connected for device workspace #{device_workspace_id}"
    assert log =~ "worker gateway joined worker_workspace:#{device_workspace_id}"

    assert log =~ "CONNECTED TO SddOrchestratorWeb.WorkerSocket"
    assert log =~ "JOINED worker_workspace:#{device_workspace_id}"
    assert log =~ "HANDLED repository_selection_result"
    assert log =~ "QUERY OK"
  end

  # The same guard for the frame scan: it is proved to hold both directions of
  # real traffic, by the two values that are genuinely allowed to travel, before
  # any absence is claimed of it.
  defp assert_review_covers_the_frames(transcript, result) do
    assert String.contains?(transcript, result.request_id)
    assert String.contains?(transcript, result.folder_name)
    assert String.contains?(transcript, result.identity)
  end

  # `config/test.exs` runs the logger at `:warning`, and `capture_log`'s handler
  # sits below the primary level filter, so nearly everything a healthy round
  # trip emits would never reach the capture at all and the review would assert
  # almost nothing. The level is lifted for the reviewed scenario only.
  defp with_debug_log(fun) do
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log(fun)
    after
      Logger.configure(level: previous_level)
    end
  end

  # Everything about the repository that must stay on the Mac. The folder name
  # is deliberately not among them: it is the one thing the worker is allowed
  # to report, and the fixture keeps it distinct from every mark below.
  defp leak_markers(repository) do
    fixed = [
      {"the repository's absolute path", repository},
      {"the repository's parent directory", Path.dirname(repository)},
      {"the parent directory's own name", @parent_marker},
      {"a file name inside the repository", @secret_file},
      {"the repository's remote URL", @remote_url},
      {"the remote's distinctive name", @remote_marker}
    ]

    fixed ++ Enum.flat_map(commit_ids(repository), &commit_markers/1)
  end

  # The whole object id, and a leading slice of it, so an abbreviated or
  # truncated disclosure is caught as well as a complete one.
  defp commit_markers(commit_id) do
    [
      {"a commit id from the repository's history", commit_id},
      {"the leading #{@fragment_length} characters of a commit id",
       String.slice(commit_id, 0, @fragment_length)}
    ]
  end

  # The failure message names which mark was found and where, never the value:
  # a review that printed the location to explain itself would be the leak.
  defp refute_leak(text, markers, where) do
    for {label, value} <- markers do
      refute String.contains?(text, value), "#{label} appeared in #{where}"
    end
  end

  defp transported_request!(traffic) do
    found =
      Enum.find_value(traffic, fn
        {:in, {:repository_selection, payload}} -> payload
        _other -> nil
      end)

    found || flunk("no repository_selection push crossed the channel")
  end

  defp transported_result!(traffic) do
    found =
      Enum.find_value(traffic, fn
        {:in, %Message{event: "repository_selection_result", payload: payload}} -> payload
        _other -> nil
      end)

    found || flunk("no repository_selection_result frame crossed the channel")
  end

  # Every traced message rendered whole, including the serialized frames, which
  # are iodata rather than a term the review could walk.
  defp transcript(traffic) do
    Enum.map_join(traffic, "\n", fn {direction, message} ->
      "#{direction} #{readable(message)}"
    end)
  end

  defp readable(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp struct_fields(struct), do: struct |> Map.from_struct() |> Map.keys() |> Enum.sort()

  # Every string anywhere in a payload, so a location cannot hide inside a
  # nested candidate or a key.
  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)

  defp strings(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.flat_map(fn {key, nested} -> strings(key) ++ strings(nested) end)
  end

  defp strings(_value), do: []

  defp drain_trace(collected \\ []) do
    receive do
      {:trace, _pid, :send, message, _to} -> drain_trace([{:out, message} | collected])
      {:trace, _pid, :receive, message} -> drain_trace([{:in, message} | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  # --- the two halves -----------------------------------------------------

  # A worker paired from the menu bar and attached over the Mac-scoped topic,
  # driven through the real gateway client against the real socket. The stored
  # configuration is what `MacPairingRetention` writes on the Swift side; the
  # release reads its own device workspace back out of it when it compares a
  # legacy candidate.
  defp attach_worker(context) do
    device_workspace_id = Ecto.UUID.generate()
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    config = %Configuration{
      control_plane_address: context.control_plane_address,
      device_workspace_id: device_workspace_id,
      worker_credential: credential,
      agent_adapter: "claude_code",
      agent_executable: "/usr/local/bin/claude",
      worker_id: worker.id
    }

    :ok = Configuration.store(config)

    {:ok, gateway} = GatewayConnection.start_link(config)
    on_exit(fn -> stop_gateway(gateway) end)

    wait_until(fn -> WorkerAttachment.attached(device_workspace_id) != [] end)

    assert [{channel, contract}] = WorkerAttachment.attached(device_workspace_id)
    assert contract.worker_id == worker.id
    assert Attachment.capability() in contract.capabilities
    wait_until(fn -> ConnectionStatus.status().status == :connected end)

    %{device_workspace_id: device_workspace_id, worker_id: worker.id, channel: channel}
  end

  defp await_pending!(request_id) do
    wait_until(fn -> File.exists?(WorkerSelection.pending_path()) end)

    pending = WorkerSelection.pending_path() |> File.read!() |> Jason.decode!()

    assert pending["request_id"] == request_id

    pending
  end

  # The Mac app's own answer, written the way `SelectionAnswerWriter.swift`
  # writes it: the request id and the chosen path, owner-only, created under a
  # unique name and renamed over the target. The rename is not decoration. The
  # release deletes the answer as soon as it reads it, so an answer it caught
  # half-written would be an answer nobody ever gets.
  defp answer_as_the_app!(request_id, path) do
    file = WorkerSelection.answer_path()
    temporary = "#{file}.app.#{System.unique_integer([:positive])}.tmp"

    File.write!(temporary, Jason.encode!(%{"request_id" => request_id, "path" => path}))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, file)
  end

  defp held_request(request_id) do
    %{^request_id => entry} = :sys.get_state(Server).requests

    %SelectionRequest{} = entry.request
  end

  # --- fixtures -----------------------------------------------------------

  # A real repository whose surroundings are all marked: the directory holding
  # it, a file inside it, and its remote. Its own folder name carries none of
  # those marks, because the folder name is the one value that is allowed to
  # travel and the review must not confuse the two.
  defp marked_repository_fixture do
    label = System.unique_integer([:positive])
    parent = Path.join(System.tmp_dir!(), "#{@parent_marker}_#{label}")
    repository = Path.join(parent, "orchestrator-#{label}")

    File.mkdir_p!(repository)
    on_exit(fn -> File.rm_rf!(parent) end)

    git!(repository, ["init", "-q"])
    git!(repository, ["config", "user.email", "t@example.test"])
    git!(repository, ["config", "user.name", "Tester"])
    git!(repository, ["remote", "add", "origin", @remote_url])

    # A distinct first blob gives this fixture a root commit unrelated to any
    # other one's, so a match reported below is a real comparison.
    File.write!(Path.join(repository, @secret_file), "seed-#{label}")
    git!(repository, ["add", @secret_file])
    git!(repository, ["commit", "-q", "-m", "root"])

    repository
  end

  defp commit_ids(repository) do
    {ids, 0} =
      System.cmd("git", ["-C", repository, "rev-list", "--all"], stderr_to_stdout: true)

    String.split(ids, "\n", trim: true)
  end

  defp git!(directory, args) do
    {_output, 0} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)

    :ok
  end

  defp portable_identity!(repository) do
    {:ok, identity} = PortableRepositoryIdentity.generate(repository)

    identity
  end

  # --- helpers ------------------------------------------------------------

  defp put_env(key, value) do
    previous = Application.fetch_env(:sdd_orchestrator, key)
    Application.put_env(:sdd_orchestrator, key, value)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(:sdd_orchestrator, key, original)
        :error -> Application.delete_env(:sdd_orchestrator, key)
      end
    end)
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

  defp wait_until(fun, timeout \\ 5_000, interval \\ 20) do
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
