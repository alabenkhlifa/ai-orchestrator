defmodule SddOrchestrator.Delivery.Blocking do
  @moduledoc """
  Pausing one run on one focused product question.

  A blocked run is a run that reached a decision it must not make alone. Making
  that durable is the whole point: the run pauses, the feature shows a visible
  `Blocked` status, the question and everything a later attempt resumes from are
  stored, and the history records it — all in one authoritative transaction, in
  either storage authority. A rejection anywhere leaves none of it.

  The feature never moves. `Blocked` is a status, so a paused feature keeps its
  place in `In development`; a separate blocked column would tell a reader the
  work went backwards when it did not.

  A worker earns none of this by asserting it. The event proves the protocol
  schema, the current fence, and its sequence through `EventIngestion` before
  anything here runs, so a superseded worker holding the old fence can keep
  asking questions and pause nothing.
  """

  import Ecto.Query

  alias SddOrchestrator.Delivery.{
    AgentRun,
    BlockingQuestion,
    DeliveryStore,
    EventIngestion,
    ParticipantGuard,
    QuestionRouting
  }

  alias SddOrchestrator.Repo

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()

  @type error ::
          EventIngestion.error()
          | :question_already_open
          | :run_not_running
          | :unknown_feature
          | :invalid_question

  # The event type this task owns. `EventIngestion` refuses it, which is what
  # keeps one owner per transition.
  @event_type "blocked"

  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @doc """
  Applies one validated `blocked` worker event to the run it names.

  A run that already has an open question is refused rather than given a second
  one: the agent is paused, so a further question is a redelivery or a
  misbehaving worker, never a new decision to make.
  """
  @spec ingest(authority(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, error()}
  def ingest(authority, project_id, envelope) do
    with {:ok, %{run: run, attempt: attempt}} <-
           EventIngestion.accept(authority, project_id, envelope, [@event_type]),
         :ok <- no_open_question(authority, project_id, run),
         :ok <- blockable?(run),
         {:ok, feature} <- fetch_feature(authority, project_id, run),
         {:ok, attrs} <- question_attrs(run, attempt, envelope) do
      commit(authority, project_id, run, attempt, %{feature: feature, question: attrs}, envelope)
    end
  end

  @doc "The run's one open question, when it has one."
  @spec open_question(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, BlockingQuestion.t()} | :error
  def open_question(authority, project_id, run_id),
    do: DeliveryStore.open_question(authority, project_id, run_id)

  @doc """
  The open question a feature is waiting on, for an authorized member.

  Read through the participation guard rather than a storage authority, because
  this is the screen's read and the feature detail resolves its project the same
  way its activity and comments do.
  """
  @spec for_feature(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, BlockingQuestion.t() | nil} | {:error, :unauthorized}
  def for_feature(project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      {:ok, open_for_feature(project_id, feature_id)}
    end
  end

  defp open_for_feature(project_id, feature_id) do
    BlockingQuestion
    |> where([q], q.project_id == ^project_id and q.feature_id == ^feature_id)
    |> where([q], q.state == "open")
    |> order_by([q], desc: q.asked_at)
    |> limit(1)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  defp commit(authority, project_id, run, attempt, %{feature: feature, question: attrs}, envelope) do
    authority
    |> DeliveryStore.commit(project_id, steps(run, attempt, feature, attrs, envelope))
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # Each record is written exactly once. A second write to the same record in
  # one commit would be offered against the version its sibling step just
  # bumped and would be rejected as stale, so the attempt's sequence, the run's
  # state, and the feature's status each move in a single step.
  defp steps(run, attempt, feature, attrs, envelope) do
    [
      {:attempt, {:observe_sequence, attempt, envelope["sequence"]}},
      {:run, {:transition_run, run, "blocked", []}},
      {:feature, {:set_feature_status, feature, "blocked"}},
      {:question, {:insert_blocking_question, attrs}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: attempt.id,
          actor_kind: "agent",
          type: "question_asked",
          payload:
            Map.merge(
              %{
                "operation_key" => envelope["event_id"],
                "question_id" => {:ref, :question, :id},
                "branch" => run.branch,
                "attempt_number" => envelope["attempt_number"],
                "summary" => String.slice(attrs.question, 0, 200)
              },
              QuestionRouting.tag(run.project_id, feature)
            )
        }}}
    ]
  end

  # The branch comes from the run rather than from the event: a run owns one
  # branch for its whole lifetime, so a worker cannot name a different one.
  # Credential-shaped content was already refused by the protocol codec, so the
  # checkpoint reaching here carries none.
  defp question_attrs(run, attempt, envelope) do
    payload = Map.get(envelope, "payload", %{})

    attrs = %{
      project_id: run.project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: attempt.id,
      question: payload["question"],
      context: payload["context"],
      checkpoint: payload["checkpoint"] || %{},
      branch: run.branch,
      workspace_path: payload["workspace_path"],
      asked_at: DateTime.utc_now()
    }

    case BlockingQuestion.ask_changeset(%BlockingQuestion{}, attrs) do
      %{valid?: true} -> {:ok, attrs}
      %{valid?: false} -> {:error, :invalid_question}
    end
  end

  defp no_open_question(authority, project_id, run) do
    case open_question(authority, project_id, run.id) do
      {:ok, _open} -> {:error, :question_already_open}
      :error -> :ok
    end
  end

  # A run has to have reported that it is running before it can report that it
  # is stuck. The transition table already says so; refusing here says it in a
  # way a caller can act on, and keeps the run to one write per commit.
  defp blockable?(%AgentRun{state: state} = run) do
    if AgentRun.legal_transition?(state, "blocked") do
      :ok
    else
      {:error, run_refusal(run)}
    end
  end

  defp run_refusal(%AgentRun{state: "blocked"}), do: :question_already_open
  defp run_refusal(_run), do: :run_not_running

  defp fetch_feature(authority, project_id, run) do
    case DeliveryStore.fetch_feature(authority, project_id, run.feature_id) do
      {:ok, feature} -> {:ok, feature}
      :error -> {:error, :unknown_feature}
    end
  end
end
