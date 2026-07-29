defmodule SddOrchestrator.Delivery.EvidenceIngestion do
  @moduledoc """
  Turning one worker command result into durable typed proof.

  Only a command result becomes evidence. The event's own `source` decides that
  before anything else is looked up: an `agent`-sourced event is refused
  outright, because an agent describing its own success is narrative and
  narrative can never satisfy a required check. Everything else a worker says
  still has to pass the shared proof `EventIngestion` applies to every event —
  the protocol schema, the current fence, and the attempt's sequence — so a
  superseded worker can keep reporting green checks and record none.

  A rerun never rewrites what it disagrees with. When a check of the same kind
  and name already has a current result for the same commit, one transaction
  records the new item, links the old one to it, and appends the history entry.
  Each record is written once in that commit, and the earlier result stays
  visible as the thing that was superseded rather than disappearing.
  """

  alias SddOrchestrator.Delivery.{DeliveryStore, EventIngestion, Evidence}

  @type authority :: DeliveryStore.authority()

  @type error ::
          EventIngestion.error()
          | :agent_evidence_refused
          | :invalid_evidence

  # The event type this task owns. `EventIngestion` refuses it, which is what
  # keeps one owner per transition.
  @event_type "evidence"

  # The protocol's third source. It is deliberately not a value this module or
  # the `evidence` table will accept.
  @agent_source "agent"

  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @doc """
  Applies one validated `evidence` worker event to the run it names.

  Agent-sourced events are refused before the run is even resolved, so the
  refusal cannot be mistaken for a transient ordering problem a retry might fix.
  """
  @spec ingest(authority(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, error()}
  def ingest(authority, project_id, envelope) do
    with :ok <- worker_derived?(envelope),
         {:ok, %{run: run, attempt: attempt}} <-
           EventIngestion.accept(authority, project_id, envelope, [@event_type]),
         {:ok, attrs} <- evidence_attrs(run, attempt, envelope) do
      commit(authority, project_id, run, attrs, envelope, attempt)
    end
  end

  @doc "Everything one run has proved, superseded items included."
  @spec for_run(authority(), Ecto.UUID.t(), Ecto.UUID.t()) :: [Evidence.t()]
  def for_run(authority, project_id, run_id),
    do: DeliveryStore.list_evidence(authority, project_id, run_id: run_id)

  @doc "Everything one attempt produced, superseded items included."
  @spec for_attempt(authority(), Ecto.UUID.t(), Ecto.UUID.t()) :: [Evidence.t()]
  def for_attempt(authority, project_id, attempt_id),
    do: DeliveryStore.list_evidence(authority, project_id, attempt_id: attempt_id)

  @doc """
  The proof that still counts for one exact commit.

  Superseded items are excluded here and nowhere else: they remain readable
  through the run and attempt views, because a reader deciding whether to trust
  a completion claim needs to see that an earlier result was replaced.
  """
  @spec current_for_commit(authority(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          [Evidence.t()]
  def current_for_commit(authority, project_id, run_id, commit_sha) do
    DeliveryStore.list_evidence(authority, project_id,
      run_id: run_id,
      commit_sha: commit_sha,
      current: true
    )
  end

  defp worker_derived?(%{"source" => @agent_source}), do: {:error, :agent_evidence_refused}
  defp worker_derived?(_envelope), do: :ok

  defp commit(authority, project_id, run, attrs, envelope, attempt) do
    superseded = superseded_by_this(authority, project_id, attrs)

    authority
    |> DeliveryStore.commit(project_id, steps(run, attempt, attrs, superseded, envelope))
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # Each record is written exactly once. The new item, the superseded item, the
  # attempt's sequence, and the history entry are four different records, so a
  # step cannot be offered against a version a sibling step just bumped.
  defp steps(run, attempt, attrs, superseded, envelope) do
    [
      {:attempt, {:observe_sequence, attempt, envelope["sequence"]}},
      {:evidence, {:insert_evidence, attrs}}
    ] ++
      supersede_step(superseded) ++
      [activity_step(run, attempt, attrs, superseded, envelope)]
  end

  defp supersede_step(nil), do: []

  defp supersede_step(superseded),
    do: [{:superseded, {:supersede_evidence, superseded, {:ref, :evidence, :id}}}]

  # A minimized projection of the approved fields, never the command's output.
  # What the check printed belongs in the private artifact the digest addresses.
  defp activity_step(run, attempt, attrs, superseded, envelope) do
    {:activity,
     {:append_activity,
      %{
        project_id: run.project_id,
        feature_id: run.feature_id,
        run_id: run.id,
        attempt_id: attempt.id,
        actor_kind: "agent",
        type: "evidence_recorded",
        payload:
          %{
            "operation_key" => envelope["event_id"],
            "evidence_id" => {:ref, :evidence, :id},
            "kind" => attrs.kind,
            "name" => attrs.name,
            "outcome" => attrs.outcome,
            "source" => attrs.source,
            "exit_code" => attrs.exit_code,
            "branch" => attrs.branch,
            "commit_sha" => attrs.commit_sha,
            "redacted" => attrs.redacted
          }
          |> put_superseded(superseded)
      }}}
  end

  defp put_superseded(payload, nil), do: payload

  defp put_superseded(payload, superseded),
    do: Map.put(payload, "supersedes_evidence_id", superseded.id)

  # The branch comes from the run rather than from the event: a run owns one
  # branch for its whole lifetime, so evidence cannot claim work happened
  # somewhere the run does not own. The recorded instant is the control plane's,
  # because a worker clock must not decide the order of the record.
  defp evidence_attrs(run, attempt, envelope) do
    payload = Map.get(envelope, "payload", %{})

    attrs = %{
      project_id: run.project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: attempt.id,
      command_id: envelope["command_id"],
      kind: payload["kind"],
      name: payload["name"],
      outcome: payload["outcome"],
      command: payload["command"],
      exit_code: payload["exit_code"],
      duration_ms: payload["duration_ms"],
      branch: run.branch,
      commit_sha: payload["commit_sha"],
      source: envelope["source"],
      recorded_at: DateTime.utc_now(),
      digest: payload["digest"],
      redacted: payload["redacted"] || false,
      artifact_ref: payload["artifact_ref"]
    }

    case Evidence.record_changeset(%Evidence{}, attrs) do
      %{valid?: true} -> {:ok, attrs}
      %{valid?: false} -> {:error, :invalid_evidence}
    end
  end

  defp superseded_by_this(authority, project_id, attrs) do
    authority
    |> current_for_commit(project_id, attrs.run_id, attrs.commit_sha)
    |> Enum.find(&(&1.kind == attrs.kind and &1.name == attrs.name))
  end
end
