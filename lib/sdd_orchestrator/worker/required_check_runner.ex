defmodule SddOrchestrator.Worker.RequiredCheckRunner do
  @moduledoc """
  Runs one attempt's required-check contract and reports what actually happened.

  Follows the same shape `SddOrchestrator.Worker.ExecutionPreparer` and
  `SddOrchestrator.Worker.AgentObserver` already established: a plain module
  with no process of its own, composing already-proven primitives.
  `SddOrchestrator.Worker.GatewayConnection` calls this only once the agent's
  own observation loop has reported a clean exit with nothing further to
  observe and no terminal event — see its `poll_and_deliver/2`.

  Verification completion is something this worker proves, never something the
  agent asserts: every check in the manifest's own `required_checks` contract
  runs for real, in the proven working directory, and reports its own
  `evidence` event before a single trailing `verification_completed` event is
  even considered — and only when every one of them actually passed. A check
  that fails, times out, or cannot even be attempted still gets its own
  evidence event with its own real outcome, and the batch's own outcome is
  `"failed"` rather than a completion. This is the worker's own local gate on
  real check outcomes; it exists alongside, not instead of, the control
  plane's own server-side refusal path.

  Every check runs, even after an earlier one has already failed, because
  full evidence — not just the first failure — is the point of a required
  check contract.

  Each check's captured stdout+stderr is also uploaded through
  `SddOrchestrator.Delivery.Worker.ArtifactUpload`, using the same signed
  gateway credential the worker's socket already carries (see
  `GatewayConnection.check_runner_opts/1`). The project's storage authority is
  always a bare `%SddOrchestrator.Accounts.PersonalWorkspace{}` literal here —
  this worker's projects are always hosted, and `ArtifactUpload.upload/4`
  dispatches on that struct's shape alone, never a field on it, so no
  database lookup is ever needed to build one. A successful upload names its
  reference on the evidence event's payload; a failed one (transport or
  permanent) is logged and simply leaves the reference off — the check's own
  `outcome` and the batch's completion gating never depend on it.
  """

  require Logger

  alias SddOrchestrator.Accounts.PersonalWorkspace
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.Worker.ArtifactUpload
  alias SddOrchestrator.Delivery.Worker.Branch
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestrator.Worker.RunState

  # Real project checks (`mix test`, a full lint pass, ...) can legitimately
  # run for minutes; ten is a generous but bounded default. Production callers
  # never override this; tests do, via `opts[:check_timeout_ms]`, the same
  # seam `GatewayConnection` already uses for `:observe_interval`.
  @check_timeout_ms 600_000

  # A hosted project's artifact endpoint is idempotent by digest (see
  # `ArtifactUpload`'s own moduledoc), so a transient transport failure can be
  # retried without risk of storing a duplicate. Three total attempts with a
  # short fixed delay between them is enough to ride out a blip without
  # holding up the rest of the batch; production callers never override the
  # delay, tests do, via `opts[:upload_retry_delay_ms]`.
  @upload_attempts 3
  @upload_retry_delay_ms 200

  @doc """
  Runs every required check in the accepted command envelope's manifest and
  returns the events to deliver together with the batch's own terminal
  outcome.

  Resolves the manifest and proven working directory the same way
  `AgentObserver.start/2` does, reads the attempt's durable `last_sequence` as
  the starting sequence counter, and resolves the working directory's current
  commit SHA once before running any check so every evidence event and the
  trailing completion event (when every check passes) share one exact
  revision.

  A failure in any of those setup steps — an unparseable manifest, a working
  directory that cannot be proven, unreadable run state, or a repository that
  cannot resolve `HEAD` — is a runner-level failure distinct from a check's
  own outcome: it is returned unchanged so the caller can log it and leave the
  attempt untouched, exactly like `GatewayConnection.prepare_execution/3`'s
  own refusal branch (no event delivered, no lock touched, nothing forced
  into a terminal state).
  """
  @spec run(map(), String.t() | nil, keyword()) ::
          {:ok, %{events: [map()], terminal: String.t()}} | {:error, term()}
  def run(envelope, home_override \\ nil, opts \\ []) do
    with {:ok, manifest} <- ProtocolCodec.manifest(envelope),
         {:ok, directory} <- Workspace.working_directory(manifest),
         {:ok, last_sequence} <- starting_sequence(home_override),
         {:ok, commit_sha} <- Branch.repository().resolve_revision(directory, "HEAD") do
      timeout = Keyword.get(opts, :check_timeout_ms, @check_timeout_ms)

      {events, all_passed?} =
        run_checks(
          manifest.required_checks,
          envelope,
          directory,
          commit_sha,
          last_sequence,
          timeout,
          manifest.project_id,
          opts
        )

      if all_passed? do
        completion =
          completion_event(envelope, manifest, commit_sha, last_sequence + length(events) + 1)

        {:ok, %{events: events ++ [completion], terminal: "verification_completed"}}
      else
        {:ok, %{events: events, terminal: "failed"}}
      end
    end
  end

  defp starting_sequence(home_override) do
    case RunState.load(home_override) do
      {:ok, %{current: %RunState{last_sequence: last_sequence}}} -> {:ok, last_sequence}
      {:ok, %{current: nil}} -> {:error, :local_run_state_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp run_checks(
         checks,
         envelope,
         directory,
         commit_sha,
         start_sequence,
         timeout,
         project_id,
         opts
       ) do
    checks
    |> Enum.with_index(1)
    |> Enum.map_reduce(true, fn {check, index}, all_passed? ->
      sequence = start_sequence + index
      {outcome, exit_code, duration_ms, content} = execute_check(check, directory, timeout)
      artifact_ref = upload_artifact(project_id, envelope, check, content, opts)

      event =
        evidence_event(
          envelope,
          sequence,
          check,
          outcome,
          exit_code,
          duration_ms,
          commit_sha,
          content,
          artifact_ref
        )

      {event, all_passed? and outcome == "passed"}
    end)
  end

  # Uploads the same `content` binary `evidence_event/9` digests, through the
  # project's storage authority (always hosted for this worker — see the
  # moduledoc). A transient transport failure is retried a bounded number of
  # times against the exact same capture, which cannot duplicate the artifact
  # since the endpoint is idempotent by digest. Any other failure, or transport
  # failure surviving every retry, is logged and answered `nil` rather than
  # raised — an evidence event is always delivered, with or without a
  # reference.
  defp upload_artifact(project_id, envelope, check, content, opts) do
    capture = %{
      run_id: envelope["run_id"],
      fence: envelope["fence_token"],
      content: content,
      content_type: "text/plain",
      redacted: false
    }

    upload_opts = [
      base_url: Keyword.fetch!(opts, :artifact_base_url),
      token: Keyword.fetch!(opts, :artifact_token),
      req_options: Keyword.get(opts, :req_options, [])
    ]

    retry_delay = Keyword.get(opts, :upload_retry_delay_ms, @upload_retry_delay_ms)

    case upload_with_retry(project_id, capture, upload_opts, retry_delay, @upload_attempts) do
      {:ok, ref} ->
        ref

      {:error, reason} ->
        Logger.warning(
          "worker required check #{inspect(check["name"])} evidence artifact upload " <>
            "failed: #{inspect(reason)}"
        )

        nil
    end
  end

  defp upload_with_retry(project_id, capture, upload_opts, _delay, attempts_left)
       when attempts_left <= 1 do
    ArtifactUpload.upload(%PersonalWorkspace{}, project_id, capture, upload_opts)
  end

  defp upload_with_retry(project_id, capture, upload_opts, delay, attempts_left) do
    case ArtifactUpload.upload(%PersonalWorkspace{}, project_id, capture, upload_opts) do
      {:error, :transport_failed} ->
        Process.sleep(delay)
        upload_with_retry(project_id, capture, upload_opts, delay, attempts_left - 1)

      result ->
        result
    end
  end

  # Runs the check's command inside a supervised `Task` so it can be killed on
  # a timeout — `System.cmd/3` has no built-in timeout of its own, and killing
  # the task kills the port it owns, which kills the OS subprocess with it.
  defp execute_check(%{"command" => command}, directory, timeout) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> run_command(command, directory) end)

    case Task.yield(task, timeout) do
      {:ok, {:ok, output, exit_code}} ->
        {outcome_for(exit_code), exit_code, elapsed(started), output}

      {:ok, {:error, :unsupported}} ->
        {"unsupported", -1, elapsed(started), unsupported_content(command)}

      {:exit, _reason} ->
        {"unsupported", -1, elapsed(started), unsupported_content(command)}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {"failed", -1, timeout, "check timed out after #{timeout}ms"}
    end
  end

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  # `sh -c` itself absorbs a genuinely missing command into a normal nonzero
  # exit status (typically 127), so that case never reaches this `rescue` —
  # it is reserved for the pathological case where the shell interpreter
  # itself cannot even be started.
  defp run_command(command, directory) do
    {output, exit_code} =
      System.cmd("sh", ["-c", command], cd: directory, stderr_to_stdout: true)

    {:ok, output, exit_code}
  rescue
    _unavailable -> {:error, :unsupported}
  end

  defp outcome_for(0), do: "passed"
  defp outcome_for(_status), do: "failed"

  defp unsupported_content(command), do: "check could not be attempted: #{command}"

  defp evidence_event(
         envelope,
         sequence,
         check,
         outcome,
         exit_code,
         duration_ms,
         commit_sha,
         content,
         artifact_ref
       ) do
    payload =
      %{
        "kind" => "required_check",
        "name" => check["name"],
        "outcome" => outcome,
        "command" => check["command"],
        "exit_code" => exit_code,
        "duration_ms" => duration_ms,
        "commit_sha" => commit_sha,
        "digest" => ArtifactUpload.digest(content),
        "redacted" => false
      }
      |> put_artifact_ref(artifact_ref)

    %{
      "type" => "event",
      "protocol_version" => envelope["protocol_version"],
      "event_id" => WorkerProtocol.generate_id(),
      "run_id" => envelope["run_id"],
      "command_id" => envelope["command_id"],
      "attempt_number" => envelope["attempt_number"],
      "fence_token" => envelope["fence_token"],
      "sequence" => sequence,
      "event_type" => "evidence",
      "source" => "check",
      "occurred_at" => now_iso8601(),
      "payload" => payload
    }
  end

  defp put_artifact_ref(payload, nil), do: payload

  defp put_artifact_ref(payload, ref) when is_binary(ref),
    do: Map.put(payload, "artifact_ref", ref)

  defp completion_event(envelope, manifest, commit_sha, sequence) do
    %{
      "type" => "event",
      "protocol_version" => envelope["protocol_version"],
      "event_id" => WorkerProtocol.generate_id(),
      "run_id" => envelope["run_id"],
      "command_id" => envelope["command_id"],
      "attempt_number" => envelope["attempt_number"],
      "fence_token" => envelope["fence_token"],
      "sequence" => sequence,
      "event_type" => "verification_completed",
      "source" => "worker",
      "occurred_at" => now_iso8601(),
      "payload" => %{
        "branch" => manifest.target_branch,
        "revision_id" => manifest.effective_revision_id,
        "commit_sha" => commit_sha
      }
    }
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
