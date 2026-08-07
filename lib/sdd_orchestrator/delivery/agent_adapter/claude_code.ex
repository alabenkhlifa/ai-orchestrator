defmodule SddOrchestrator.Delivery.AgentAdapter.ClaudeCode.Session do
  @moduledoc false

  # Owns one `claude` subprocess for the life of one launch: decodes its
  # `stream-json` output line by line into this adapter's `progress`/`failed`
  # event shape, and buffers whatever is new since the last `drain/1`. A
  # dedicated process (rather than the caller's own) is what lets `start/1`
  # return quickly while `observe/1` is polled later, possibly by a different
  # process entirely — the boundary documents no constraint that the same
  # process must do both.

  use GenServer

  @launch_timeout 30_000
  @permission_mode "bypassPermissions"

  defstruct port: nil,
            buffer: "",
            events: [],
            status: :running,
            ready: nil,
            awaiting: nil,
            requested_thread_ref: nil,
            session_id: nil,
            seen_init?: false,
            seen_result?: false,
            result_is_error?: false

  @spec start(String.t(), map(), [{String.t(), String.t() | nil}], String.t() | nil) ::
          {:ok, pid(), boolean()} | {:error, atom()}
  def start(executable, agent_input, environment, thread_ref) do
    case GenServer.start_link(__MODULE__, {executable, agent_input, environment, thread_ref}) do
      {:ok, pid} ->
        case GenServer.call(pid, :await_ready, @launch_timeout) do
          {:ok, resumed?} -> {:ok, pid, resumed?}
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} ->
        {:error, :agent_launch_failed}
    end
  catch
    :exit, _reason -> {:error, :agent_launch_failed}
  end

  @spec thread_ref(pid()) :: String.t() | nil
  def thread_ref(pid), do: GenServer.call(pid, :thread_ref)

  @spec drain(pid()) :: {:ok, [map()]} | {:error, atom()}
  def drain(pid) do
    if Process.alive?(pid) do
      GenServer.call(pid, :drain)
    else
      {:error, :agent_exited}
    end
  end

  # Always returns `{:ok, state}`, never `{:stop, reason}` for an expected
  # failure: a non-`:normal` stop from `init/1` propagates to the caller as a
  # raw link-exit signal (crashing it if it isn't trapping exits) rather than
  # cleanly as `{:error, reason}` from `start_link` — an unavailable
  # executable is recorded in `:ready` instead and reported the same way
  # `settle/1` reports any other launch failure, then the process stops
  # itself with reason `:normal` right after replying (see `handle_call/3`).
  @impl true
  def init({executable, agent_input, environment, thread_ref}) do
    case System.find_executable(executable) do
      nil ->
        {:ok, %__MODULE__{ready: {:error, :agent_unavailable}}}

      resolved ->
        port =
          Port.open({:spawn_executable, resolved}, [
            :binary,
            :exit_status,
            :hide,
            args: build_args(agent_input, thread_ref),
            cd: to_charlist(Map.fetch!(agent_input, "working_directory")),
            env: port_env(environment)
          ])

        {:ok, %__MODULE__{port: port, requested_thread_ref: thread_ref}}
    end
  rescue
    _unavailable -> {:ok, %__MODULE__{ready: {:error, :agent_unavailable}}}
  end

  @impl true
  def handle_call(:await_ready, from, %{ready: nil} = state),
    do: {:noreply, %{state | awaiting: from}}

  def handle_call(:await_ready, _from, %{ready: {:error, _reason} = ready} = state),
    do: {:stop, :normal, ready, state}

  def handle_call(:await_ready, _from, %{ready: ready} = state), do: {:reply, ready, state}

  def handle_call(:thread_ref, _from, state), do: {:reply, state.session_id, state}

  def handle_call(:drain, _from, state) do
    events = Enum.reverse(state.events)

    reply =
      case {events, state.status} do
        {[], {:exited, _code}} -> {:error, :agent_exited}
        _has_events_or_running -> {:ok, events}
      end

    {:reply, reply, %{state | events: []}}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {lines, remainder} = split_lines(state.buffer <> chunk)
    state = %{state | buffer: remainder}
    state = Enum.reduce(lines, state, &handle_line/2)
    {:noreply, settle(state)}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    {:noreply, settle(%{state | status: {:exited, code}})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Closing this process's own `Port` — whether from a normal GenServer stop
  # or a crash — never signals the OS process on the other end of it:
  # confirmed live, closing a `Port` opened via `:spawn_executable` leaves
  # the wrapped `claude` subprocess running. A session already reporting
  # `{:exited, _}` needs nothing here, its subprocess is already gone; one
  # still `:running` when stopped (e.g. a worker cancel) is signaled
  # directly, so it cannot keep running — possibly still writing to the
  # workspace — after the launch that owned it has been torn down.
  @impl true
  def terminate(_reason, %{port: port, status: :running}) when is_port(port) do
    kill_os_process(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # `Port.info/2` on an already-closed port returns `nil` rather than raising
  # or returning a stale pid — confirmed live — so the `nil` clause below is
  # a genuine liveness check, not a defense against a hypothetical. `SIGKILL`
  # rather than `SIGTERM`: this only runs for an explicit cancellation, not a
  # graceful shutdown request, matching `RequiredCheckRunner`'s own
  # `Task.shutdown(task, :brutal_kill)` convention for the same situation.
  defp kill_os_process(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # `--print` runs one headless turn against the already-isolated working
  # directory (set via `cd:`, so no `--add-dir` is needed) and never opens an
  # interactive prompt; `bypassPermissions` is what makes that possible with
  # no human present to answer one. Safety here comes from the isolation this
  # worker already proved before launch (workspace, branch, environment
  # allowlist), not from a per-call approval this headless context cannot
  # offer anyway.
  defp build_args(agent_input, thread_ref) do
    base = [
      "--print",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      @permission_mode
    ]

    with_resume = if thread_ref, do: base ++ ["--resume", thread_ref], else: base
    with_resume ++ [prompt(agent_input)]
  end

  defp prompt(agent_input) do
    """
    You are continuing approved automated development for project #{agent_input["project_id"]}, \
    feature #{agent_input["feature_id"]}, run #{agent_input["run_id"]}, attempt #{agent_input["attempt_number"]}.

    Approved slice: #{agent_input["approved_slice"]}
    Target branch (already checked out in this directory): #{agent_input["target_branch"]}
    Continuation: #{inspect(agent_input["continuation"])}

    Required checks that must pass before this work is considered complete:
    #{format_checks(agent_input["required_checks"])}

    Implement the approved slice fully and make focused commits on the current branch.
    """
  end

  defp format_checks(checks) when is_list(checks) and checks != [] do
    Enum.map_join(checks, "\n", fn check -> "- #{check["name"]}: #{check["command"]}" end)
  end

  defp format_checks(_checks), do: "- (none recorded)"

  # `nil` means "clear this variable" in `AgentAdapter.environment/0`'s own
  # shape; Erlang's port `:env` option uses `false` for exactly that, so this
  # is a direct translation, not a reinterpretation.
  defp port_env(environment) do
    Enum.map(environment, fn
      {name, nil} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) -> classify(decoded, state)
      _unparseable -> state
    end
  end

  defp classify(%{"type" => "system", "subtype" => "init", "session_id" => session_id}, state) do
    %{state | seen_init?: true, session_id: session_id}
  end

  defp classify(%{"type" => "system"}, state), do: state

  defp classify(%{"type" => "assistant", "message" => message} = raw, state) do
    case assistant_event(message, raw) do
      nil -> state
      event -> %{state | events: [event | state.events]}
    end
  end

  # A tool-result echo fed back into the conversation, not new agent-authored
  # narration — surfacing it would duplicate what the matching `assistant`
  # tool_use event already reported.
  defp classify(%{"type" => "user"}, state), do: state

  defp classify(%{"type" => "result"} = result, state) do
    event = result_event(result)
    is_error? = result["is_error"] == true
    %{state | events: [event | state.events], seen_result?: true, result_is_error?: is_error?}
  end

  defp classify(_other, state), do: state

  defp assistant_event(%{"content" => content}, raw) when is_list(content) do
    summary = content |> Enum.map(&describe_block/1) |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if summary == "" do
      nil
    else
      %{
        "type" => "progress",
        "occurred_at" => timestamp(raw),
        "payload" => %{"summary" => summary}
      }
    end
  end

  defp assistant_event(_message, _raw), do: nil

  defp describe_block(%{"type" => "text", "text" => text}) when is_binary(text) and text != "",
    do: text

  defp describe_block(%{"type" => "tool_use", "name" => name} = block) when is_binary(name),
    do: "Used #{name}#{tool_detail(block)}"

  defp describe_block(_block), do: nil

  defp tool_detail(%{"input" => %{"file_path" => path}}) when is_binary(path), do: " on #{path}"

  defp tool_detail(%{"input" => %{"command" => command}}) when is_binary(command),
    do: ": #{command}"

  defp tool_detail(_block), do: ""

  defp result_event(%{"is_error" => true} = result) do
    %{
      "type" => "failed",
      "occurred_at" => now(),
      "payload" => %{
        "reason" => result["subtype"] || "agent_error",
        "summary" => result_summary(result)
      }
    }
  end

  defp result_event(result) do
    %{
      "type" => "progress",
      "occurred_at" => now(),
      "payload" => %{"summary" => result["result"] || "Turn completed."}
    }
  end

  defp result_summary(%{"errors" => [first | _rest]}) when is_binary(first), do: first
  defp result_summary(%{"result" => result}) when is_binary(result), do: result
  defp result_summary(_result), do: "The agent reported an error."

  defp timestamp(%{"timestamp" => value}) when is_binary(value), do: value
  defp timestamp(_raw), do: now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # A resume that never gets as far as a `system`/`init` message never
  # started the requested session at all — the provider thread this worker
  # asked for is gone, not merely a mid-run failure, so the boundary's own
  # new-thread fallback is the right answer rather than failing the attempt.
  defp settle(%{ready: nil} = state) do
    cond do
      state.seen_init? ->
        reply_ready(state, {:ok, not is_nil(state.requested_thread_ref)})

      state.seen_result? and state.result_is_error? and state.requested_thread_ref ->
        reply_ready(%{state | session_id: nil}, {:error, :thread_not_found})

      state.seen_result? and state.result_is_error? ->
        reply_ready(%{state | session_id: nil}, {:error, :agent_launch_failed})

      match?({:exited, _code}, state.status) ->
        reply_ready(%{state | session_id: nil}, {:error, :agent_launch_failed})

      true ->
        state
    end
  end

  defp settle(state), do: state

  defp reply_ready(state, result) do
    state = %{state | ready: result}

    case state.awaiting do
      nil -> state
      from -> GenServer.reply(from, result)
    end

    %{state | awaiting: nil}
  end
end

defmodule SddOrchestrator.Delivery.AgentAdapter.ClaudeCode do
  @moduledoc """
  The `SddOrchestrator.Delivery.AgentAdapter` implementation for the Claude
  Code command-line agent.

  `installed_version/0` reports this adapter's own output-schema version
  (`"1.0.0"`, the value `AgentAdapter.confirm_version/1` checks against the
  shared `@agent_protocol_majors [1]`) — never the CLI product's own release
  number. The two are unrelated: Claude Code and Codex each carry their own
  independent version scheme, so the only "protocol version" that can mean
  the same thing across both adapters is this project's own contract for the
  `agent_event` shape `AgentAdapter.observe/2` normalizes. That value is
  reported only once a genuine, recognizable `claude` executable answers
  `--version`; anything else collapses to `:agent_unavailable`, exactly as
  `AgentAdapter.version/1` already treats every non-`{:ok, _}` result.

  Launch and streaming decode live in `Session`, a dedicated `GenServer` that
  owns the subprocess `Port` for the run's whole life, so `observe/1` can be
  polled by whatever process ends up owning that later without the two
  needing to be the same process that called `start/1`.

  `Application.get_env(:sdd_orchestrator, :agent_executable, "claude")`
  chooses which executable to invoke, resolved by name via `PATH` like
  `Delivery.Worker.Branch.Repository.Git`'s own `"git"`. Wiring a worker's
  configured executable path into that key, and selecting this module by
  configuration in the first place, is `specs/33-local-worker-run-execution`
  Task 7's own declared surface, not this one's — this module is fully
  provable today by an explicit `Application.put_env/3` or an
  `AgentAdapter.launch/3` `:adapter` override, the same seam the existing
  test double already uses.
  """

  @behaviour SddOrchestrator.Delivery.AgentAdapter

  alias SddOrchestrator.Delivery.AgentAdapter.ClaudeCode.Session

  @adapter_output_schema_version "1.0.0"
  @default_executable "claude"
  @version_pattern ~r/\A(\d+\.\d+\.\d+)\s*\(Claude Code\)\z/

  @impl true
  def installed_version do
    case System.find_executable(executable()) do
      nil ->
        {:error, :agent_unavailable}

      resolved ->
        case System.cmd(resolved, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> confirm_installed(String.trim(output))
          {_output, _status} -> {:error, :agent_unavailable}
        end
    end
  rescue
    _unavailable -> {:error, :agent_unavailable}
  end

  @impl true
  def start(%{agent_input: agent_input, environment: environment, thread_ref: thread_ref})
      when is_map(agent_input) and is_list(environment) do
    case Session.start(executable(), agent_input, environment, thread_ref) do
      {:ok, session, resumed?} ->
        {:ok, %{reference: session, thread_ref: Session.thread_ref(session), resumed?: resumed?}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def start(_input), do: {:error, :invalid_agent_input}

  @impl true
  def observe(%{reference: session}) when is_pid(session), do: Session.drain(session)
  def observe(_handle), do: {:error, :agent_exited}

  defp executable,
    do: Application.get_env(:sdd_orchestrator, :agent_executable, @default_executable)

  defp confirm_installed(reported) do
    if Regex.match?(@version_pattern, reported) do
      {:ok, @adapter_output_schema_version}
    else
      {:error, :agent_unavailable}
    end
  end
end
