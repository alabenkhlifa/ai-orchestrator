defmodule SddOrchestrator.Delivery.AgentAdapter.Codex.Session do
  @moduledoc false

  # Owns one `codex exec` subprocess for the life of one launch: decodes its
  # `--json` output line by line into this adapter's `progress`/`failed`
  # event shape, and buffers whatever is new since the last `drain/1`.
  # Structurally identical to `ClaudeCode.Session` (same reasons: a
  # dedicated process so `observe/1` can be polled by whoever ends up owning
  # that, decoupled from whichever process called `start/1`), differing only
  # in the CLI's own invocation shape and event vocabulary.

  use GenServer

  @launch_timeout 30_000
  @sandbox_bypass "--dangerously-bypass-approvals-and-sandbox"

  defstruct port: nil,
            buffer: "",
            events: [],
            status: :running,
            ready: nil,
            awaiting: nil,
            requested_thread_ref: nil,
            thread_id: nil,
            seen_init?: false,
            turn_completed?: false

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

  # See the moduledoc for why `init/1` always returns `{:ok, state}`, even
  # for an expected failure — a non-`:normal` `{:stop, reason}` here would
  # crash the caller through the `start_link` link instead of cleanly
  # answering `{:error, reason}`.
  @impl true
  def init({executable, agent_input, environment, thread_ref}) do
    case {System.find_executable(executable), System.find_executable("sh")} do
      {nil, _sh} ->
        {:ok, %__MODULE__{ready: {:error, :agent_unavailable}}}

      {_resolved, nil} ->
        {:ok, %__MODULE__{ready: {:error, :agent_unavailable}}}

      {resolved, sh} ->
        port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            :hide,
            args: shell_args(sh, resolved, agent_input, thread_ref),
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

  def handle_call(:thread_ref, _from, state), do: {:reply, state.thread_id, state}

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
    state = %{state | status: {:exited, code}}
    state = maybe_synthesize_failure(state, code)
    {:noreply, settle(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # See `ClaudeCode.Session`'s own `terminate/2` for why this exists: closing
  # a `Port` never signals the OS process on the other end of it — confirmed
  # live — so a session stopped while still genuinely `:running` (e.g. a
  # worker cancel) is signaled directly instead of being left running after
  # the launch that owned it has been torn down. This `Port` wraps the
  # `sh -c 'exec "$0" "$@" < /dev/null'` launcher built in `shell_args/4`
  # below; `exec` replaces the shell's own process image rather than
  # forking, so the OS pid `Port.info/2` reports here is already the real
  # `codex` process — no separate child process to hunt down.
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

  # `codex exec` reads from stdin even when a prompt is given as an argument
  # ("if stdin is piped ... stdin is appended as a `<stdin>` block"), and
  # blocks waiting for it — confirmed live: a plain port with no `:in` data
  # ever sent just hangs. A bare Erlang `Port` has no way to half-close only
  # the input side of an already-open pipe, so stdin is redirected to
  # `/dev/null` the OS way, through a `sh -c` wrapper whose command string is
  # a fixed literal with no interpolated content — every dynamic value
  # (executable path, subcommand, flags, the prompt) is a separate
  # positional parameter (`"$0"`, `"$@"`), never part of the shell string
  # itself, so this carries the same "no argument can become shell syntax"
  # guarantee `Delivery.Worker.Branch.Repository.Git` already relies on.
  defp shell_args(_sh, resolved, agent_input, thread_ref) do
    ["-c", ~s(exec "$0" "$@" < /dev/null), resolved] ++ codex_args(agent_input, thread_ref)
  end

  # `codex exec resume` has no `-C`/`--cd` of its own — confirmed live, it
  # refuses the flag outright — so both a fresh launch and a resume rely on
  # the port's own `cd:` option for working-directory isolation instead.
  defp codex_args(agent_input, nil) do
    [
      "exec",
      "--json",
      "--skip-git-repo-check",
      @sandbox_bypass,
      "-C",
      to_string(agent_input["working_directory"]),
      prompt(agent_input)
    ]
  end

  defp codex_args(agent_input, thread_ref) do
    [
      "exec",
      "resume",
      thread_ref,
      "--json",
      "--skip-git-repo-check",
      @sandbox_bypass,
      prompt(agent_input)
    ]
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

  defp classify(%{"type" => "thread.started", "thread_id" => thread_id}, state)
       when is_binary(thread_id) do
    %{state | seen_init?: true, thread_id: thread_id}
  end

  defp classify(%{"type" => "turn.started"}, state), do: state

  defp classify(%{"type" => "item.completed", "item" => item}, state) when is_map(item) do
    case item_event(item) do
      nil -> state
      event -> %{state | events: [event | state.events]}
    end
  end

  defp classify(%{"type" => "turn.completed"}, state) do
    event = %{
      "type" => "progress",
      "occurred_at" => now(),
      "payload" => %{"summary" => "Turn completed."}
    }

    %{state | events: [event | state.events], turn_completed?: true}
  end

  # Neither empirically confirmed against the real CLI (see the moduledoc),
  # but handled defensively rather than left to fall through as an
  # unrecognized item and silently produce nothing on a genuine failure.
  defp classify(%{"type" => "turn.failed"} = raw, state) do
    event = failure_event(raw["error"])
    %{state | events: [event | state.events], turn_completed?: true}
  end

  defp classify(_other, state), do: state

  defp item_event(%{"type" => "agent_message", "text" => text})
       when is_binary(text) and text != "" do
    progress_event(text)
  end

  defp item_event(%{"type" => "reasoning", "text" => text}) when is_binary(text) and text != "" do
    progress_event("Reasoning: " <> text)
  end

  # Best-effort: the exact `command_execution`/`file_change` item shape was
  # not empirically confirmed (a live probe requiring the sandbox-bypass
  # flag was refused by this environment's own safety policy), so this reads
  # generously and falls through to `nil` — silently dropped, never
  # crashing — rather than assume a field name that might not exist.
  defp item_event(%{"type" => "command_execution"} = item), do: command_event(item)
  defp item_event(%{"type" => "file_change"} = item), do: file_change_event(item)
  defp item_event(%{"type" => "error"} = item), do: failure_event(item)
  defp item_event(_item), do: nil

  defp command_event(%{"command" => command}) when is_binary(command),
    do: progress_event("Ran: #{command}")

  defp command_event(%{"command" => command}) when is_list(command),
    do: progress_event("Ran: #{Enum.join(command, " ")}")

  defp command_event(_item), do: progress_event("Ran a command")

  defp file_change_event(%{"path" => path}) when is_binary(path),
    do: progress_event("Changed #{path}")

  defp file_change_event(%{"changes" => changes}) when is_list(changes),
    do: progress_event("Changed #{length(changes)} file(s)")

  defp file_change_event(_item), do: progress_event("Changed files")

  defp progress_event(summary),
    do: %{"type" => "progress", "occurred_at" => now(), "payload" => %{"summary" => summary}}

  defp failure_event(%{"message" => message}) when is_binary(message) do
    %{
      "type" => "failed",
      "occurred_at" => now(),
      "payload" => %{"reason" => "turn_failed", "summary" => message}
    }
  end

  defp failure_event(_error) do
    %{
      "type" => "failed",
      "occurred_at" => now(),
      "payload" => %{"reason" => "turn_failed", "summary" => "The agent reported an error."}
    }
  end

  # A resume that never gets as far as `thread.started` never resumed the
  # requested thread at all — confirmed live: an unresolvable resume prints
  # a plain-text error (inherited stderr, not JSON on stdout, so nothing this
  # adapter parses) and exits nonzero with no `thread.started` ever seen.
  defp settle(%{ready: nil} = state) do
    cond do
      state.seen_init? ->
        reply_ready(state, {:ok, not is_nil(state.requested_thread_ref)})

      match?({:exited, _code}, state.status) and state.requested_thread_ref ->
        reply_ready(%{state | thread_id: nil}, {:error, :thread_not_found})

      match?({:exited, _code}, state.status) ->
        reply_ready(%{state | thread_id: nil}, {:error, :agent_launch_failed})

      true ->
        state
    end
  end

  defp settle(state), do: state

  # A safety net for a session that started cleanly but then the process
  # exited nonzero without ever reporting `turn.completed` or `turn.failed`
  # — whatever the exact shape of a real mid-turn Codex failure turns out to
  # be, losing the process without any terminal signal must still surface as
  # a `failed` event rather than silently stopping.
  defp maybe_synthesize_failure(state, code)
       when code != 0 and state.seen_init? and not state.turn_completed? do
    event = %{
      "type" => "failed",
      "occurred_at" => now(),
      "payload" => %{
        "reason" => "agent_exited",
        "summary" => "The agent process exited unexpectedly."
      }
    }

    %{state | events: [event | state.events], turn_completed?: true}
  end

  defp maybe_synthesize_failure(state, _code), do: state

  defp reply_ready(state, result) do
    state = %{state | ready: result}

    case state.awaiting do
      nil -> state
      from -> GenServer.reply(from, result)
    end

    %{state | awaiting: nil}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

defmodule SddOrchestrator.Delivery.AgentAdapter.Codex do
  @moduledoc """
  The `SddOrchestrator.Delivery.AgentAdapter` implementation for the Codex
  command-line agent.

  Mirrors `SddOrchestrator.Delivery.AgentAdapter.ClaudeCode` in every way the
  shared boundary requires — same version-report contract (this adapter's
  own output-schema version, gated on a genuine, recognizable `codex`
  executable being present, never the CLI's own release number, for exactly
  the reason documented on `ClaudeCode`: two unrelated vendor version
  schemes cannot both satisfy one shared `@agent_protocol_majors` check
  unless it means this project's own contract), same environment and
  working-directory handling, same `Session`-owns-the-`Port` structure — and
  differs only where the two CLIs genuinely differ: invocation flags,
  the `--json` event vocabulary (`thread.started`/`item.completed`/
  `turn.completed` rather than `system`/`assistant`/`result`), and the
  `sh -c '... < /dev/null'` wrapper `codex exec` needs to avoid blocking on
  stdin even when a prompt is given as an argument (see `Session`'s
  moduledoc) — `claude` never needed this.

  `Application.get_env(:sdd_orchestrator, :agent_executable, "codex")`
  chooses which executable to invoke, the same key `ClaudeCode` reads:
  one worker runs exactly one configured agent type at a time, so both
  adapters sharing one key is correct, not a collision. This task also adds
  the wiring neither adapter task did: `Worker.Supervisor.init/1` now
  translates the paired `WorkerConfiguration.agent_adapter`/
  `.agent_executable` strings into that key and `Application.put_env(:sdd_orchestrator,
  :agent_adapter, ...)`, so a running worker can actually select between
  them — see `SddOrchestrator.Worker.Supervisor`.
  """

  @behaviour SddOrchestrator.Delivery.AgentAdapter

  alias SddOrchestrator.Delivery.AgentAdapter.Codex.Session

  @adapter_output_schema_version "1.0.0"
  @default_executable "codex"
  @version_pattern ~r/\Acodex-cli \d+\.\d+\.\d+\z/

  # `resolved` is the worker's own configured executable path
  # (`WorkerConfiguration.agent_executable`, set by the operator at pairing
  # time), never web or user input, and `System.cmd/3` here takes `["--version"]`
  # as a separate argument list rather than a shell string — no argument can
  # become shell syntax. Documented false positive.
  # sobelow_skip ["CI.System"]
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
