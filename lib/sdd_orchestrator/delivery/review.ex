defmodule SddOrchestrator.Delivery.Review do
  @moduledoc """
  The product decision an agent may never make, made by the person who owns it.

  `ReviewHandoff` is where a proven run stops; this is where a person answers it.
  Two people may answer: the participant responsibility currently resolves to,
  and the project owner. Everyone else on the project is refused, and so is
  every agent — an agent holds no member identity at all, so it cannot reach the
  participation guard's first gate, let alone this one. The owner keeps their
  authority precisely so a departure cannot strand a feature nobody can finish.

  Responsibility is resolved now rather than read from the handoff record. The
  person who was responsible when the work finished may have left since, and the
  point of asking again is that authority follows current participation instead
  of a name frozen into history. Membership itself is revalidated first, which is
  what removes a former reviewer's authority the moment they leave.

  The board state is checked after authority, not before. Someone who may not
  decide learns only that the action is unavailable, never where the feature
  currently sits.

  An approval finishes the feature: `Ready for review` to `Done`, the one move
  that ends the lifecycle. A rejection sends it back to `In development` and
  continues the same run in the same commit as the verdict. Splitting those in
  two would leave a rejected feature stranded in `Ready for review` whenever the
  second commit never ran, and a crash would make that permanent. What the
  continuation consists of belongs to `ReviewContinuation`; this module still
  owns only the verdict.

  Whether the feedback contradicts the approved product agreement is declared by
  the reviewer, never inferred here. Feedback that changes the agreement blocks
  for specification write-back instead of quietly starting an attempt against a
  manifest the agreement no longer supports.

  A rejection must say why. Feedback is required, non-blank, and bounded, in this
  module, in the changeset, and again at the database, because a rejection nobody
  can act on wastes the whole run it sends back. An approval carries no feedback
  at all, so an accepted feature cannot hold a record that reads as a complaint.

  What the decision names is what was proved. The branch, the commit, and the
  attempt are copied from the verified completion the gate recorded rather than
  from the run, and the preview reference is whichever deployment the reviewer
  could have opened for exactly that commit. A feature with no preview decides
  normally; a preview was never part of this verdict.

  Deciding twice decides once. The reviewed attempt is the operation key, the
  append-only history is the ledger it is checked against, and the store's own
  one-verdict-per-attempt rule is the last line of defence rather than the first.
  """

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    Assignment,
    BlockingQuestion,
    DeliveryStore,
    Feature,
    ParticipantGuard,
    ReviewContinuation,
    ReviewDecision,
    ReviewHandoff,
    RunAttempt,
    RunCommand,
    RunTransitions,
    VerificationCompletion
  }

  alias SddOrchestrator.Projects.Project

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()
  @type member :: ParticipantGuard.member()

  @type subject :: %{project: Project.t(), feature: Feature.t()}

  @type result :: %{
          applied?: boolean(),
          feature: Feature.t(),
          decision: ReviewDecision.t(),
          activity: ActivityEntry.t() | nil,
          attempt: RunAttempt.t() | nil,
          command: RunCommand.t() | nil,
          question: BlockingQuestion.t() | nil
        }

  @type error ::
          :unauthorized
          | :not_in_review
          | :not_verified
          | :feedback_required
          | :feedback_too_long
          | :unknown_run
          | :no_attempt
          | ReviewContinuation.error()
          | DeliveryStore.error()

  # The one column a decision may be made from, and the one an approval reaches.
  @column "ready_for_review"
  @approved_column "done"

  @approved_activity "review_approved"
  @rejected_activity "review_rejected"

  # The authoritative feedback lives in the decision record, which is bounded at
  # 4 KB on its own. One activity payload is bounded at 4 KB in total, so the
  # history carries a bounded excerpt: without it, the longest feedback a
  # reviewer is allowed to write would be feedback the history cannot record.
  @max_excerpt_characters 400

  @spec column() :: String.t()
  def column, do: @column

  @spec approved_activity_type() :: String.t()
  def approved_activity_type, do: @approved_activity

  @spec rejected_activity_type() :: String.t()
  def rejected_activity_type, do: @rejected_activity

  @doc """
  Approves the feature and finishes it, for the acting participant.

  Only the current responsible participant or the project owner may approve, and
  only a feature that is actually in `Ready for review`. Answers
  `applied?: false` when this attempt was already decided, which is what makes a
  double-pressed button safe.
  """
  @spec approve(authority(), actor(), subject()) :: {:ok, result()} | {:error, error()}
  def approve(authority, actor, subject), do: decide(authority, actor, subject, "approved", nil)

  @doc """
  Rejects the feature with the feedback the next attempt has to act on.

  Blank, whitespace-only, and oversized feedback are refused before anything is
  written. The feature returns to `In development` and the same run continues on
  the same branch as one further attempt.

  `:contradicts_agreement?` is the reviewer's declaration that acting on this
  feedback would change the approved product agreement. It defaults to `false`,
  and when it is `true` nothing is dispatched: the run pauses on a blocking
  question so the agreement is decided and written back before any attempt runs
  against it.
  """
  @spec reject(authority(), actor(), subject(), String.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def reject(authority, actor, subject, feedback, opts \\ []),
    do: decide(authority, actor, subject, "rejected", feedback, opts)

  @doc """
  Whether this reader may decide this feature right now.

  Read through the participation guard and the same narrow authority the action
  applies, so an approve or reject control never appears for someone whose press
  would be refused. A current participant who simply may not decide is answered
  `false` rather than denied, because they are entitled to read the feature.
  """
  @spec reviewable(authority(), actor(), subject()) :: {:ok, boolean()} | {:error, :unauthorized}
  def reviewable(_authority, actor, %{project: project, feature: feature}) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :review) do
      {:ok, feature.lifecycle_column == @column and permitted?(project.id, feature, member)}
    end
  end

  @doc "The feature's most recent recorded verdict, when it has one."
  @spec decision(authority(), Ecto.UUID.t(), Feature.t()) :: ReviewDecision.t() | nil
  def decision(authority, project_id, %Feature{} = feature) do
    authority
    |> DeliveryStore.list_review_decisions(project_id, feature_id: feature.id)
    |> List.last()
  end

  @doc """
  Whether the feature's latest rejection was raised for specification write-back.

  Answered from the flag the rejection itself recorded, so a caller never has to
  re-derive it. The feature's `Blocked` status cannot answer this — a continued
  run blocks on questions of the agent's own — and comparing the open question's
  text against the verdict's feedback would tie the answer to how the question
  happens to be truncated today. One recorded fact, read by everyone who needs
  it.
  """
  @spec blocked_for_specification?(authority(), Ecto.UUID.t(), Feature.t()) :: boolean()
  def blocked_for_specification?(authority, project_id, %Feature{} = feature) do
    authority
    |> DeliveryStore.list_activity(project_id, feature.id, limit: 200)
    |> Enum.filter(&(&1.type == @rejected_activity))
    |> List.last()
    |> case do
      nil -> false
      entry -> entry.payload["blocked_for_specification"] == true
    end
  end

  defp decide(authority, actor, subject, outcome, feedback, opts \\ []) do
    %{project: project, feature: feature} = subject

    with {:ok, member} <- ParticipantGuard.authorize_action(project.id, actor, :review),
         :ok <- deciding_authority(project.id, feature, member),
         :ok <- in_review(feature),
         {:ok, text} <- feedback_for(outcome, feedback),
         {:ok, verified} <- reviewed(authority, project.id, feature) do
      apply_verdict(authority, %{
        project_id: project.id,
        feature: feature,
        member: member,
        verified: verified,
        outcome: outcome,
        feedback: text,
        key: operation_key(verified),
        opts: opts
      })
    end
  end

  # The two people who may end a review: whoever the feature's responsibility
  # currently resolves to, and the one person accountable for the project
  # whatever else changes. Membership was already revalidated by the guard, which
  # is what removes a former reviewer's authority the moment they leave.
  defp deciding_authority(project_id, feature, member) do
    if permitted?(project_id, feature, member) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp permitted?(project_id, feature, member),
    do: member.role == :owner or responsible?(project_id, feature, member)

  # A project with no owner left to fall back on has no responsible participant
  # at all, which denies rather than defaulting to whoever asked.
  defp responsible?(project_id, feature, member) do
    case Assignment.responsible(project_id, feature) do
      {:ok, responsible} -> responsible.account_id == member.account_id
      {:error, :unavailable} -> false
    end
  end

  defp in_review(%Feature{lifecycle_column: @column}), do: :ok
  defp in_review(%Feature{}), do: {:error, :not_in_review}

  defp feedback_for("approved", _feedback), do: {:ok, nil}

  defp feedback_for("rejected", feedback) when is_binary(feedback) do
    trimmed = String.trim(feedback)

    cond do
      trimmed == "" -> {:error, :feedback_required}
      byte_size(trimmed) > ReviewDecision.max_feedback_bytes() -> {:error, :feedback_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp feedback_for("rejected", _feedback), do: {:error, :feedback_required}

  # The verdict is consumed, never re-derived. A feature sitting in review with
  # no recorded verified completion behind it could not have arrived there
  # legitimately, so it is refused rather than decided about nothing.
  defp reviewed(authority, project_id, feature) do
    case handed_over(authority, project_id, feature.id) do
      {:ok, run_id} -> verified(authority, project_id, feature.id, run_id)
      :error -> {:error, :not_verified}
    end
  end

  defp handed_over(authority, project_id, feature_id) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.filter(&(&1.type == ReviewHandoff.activity_type() and is_binary(&1.run_id)))
    |> List.last()
    |> case do
      nil -> :error
      entry -> {:ok, entry.run_id}
    end
  end

  defp verified(authority, project_id, feature_id, run_id) do
    authority
    |> VerificationCompletion.verified_completion(project_id, feature_id, run_id)
    |> case do
      {:ok, entry} -> complete(entry)
      :error -> {:error, :not_verified}
    end
  end

  # A completion missing the attempt, branch, or commit it proved is not a
  # weaker verdict; it is a verdict about something nobody can identify.
  defp complete(%ActivityEntry{attempt_id: attempt_id, payload: payload} = entry)
       when is_binary(attempt_id) do
    if present?(payload["branch"]) and present?(payload["commit_sha"]) do
      {:ok, entry}
    else
      {:error, :not_verified}
    end
  end

  defp complete(%ActivityEntry{}), do: {:error, :not_verified}

  defp present?(value), do: is_binary(value) and value != ""

  defp apply_verdict(authority, verdict) do
    if RunTransitions.applied?(authority, verdict.project_id, verdict.feature.id, verdict.key) do
      already_decided(authority, verdict)
    else
      commit(authority, verdict)
    end
  end

  defp commit(authority, verdict) do
    attrs = decision_attrs(authority, verdict)

    with {:ok, continuation} <- continuation(authority, verdict) do
      authority
      |> DeliveryStore.commit(verdict.project_id, steps(verdict, attrs, continuation))
      |> case do
        {:ok, results} ->
          {:ok,
           %{
             applied?: true,
             feature: Map.get(results, :feature, verdict.feature),
             decision: results.decision,
             activity: Map.get(results, :activity),
             attempt: Map.get(results, :attempt),
             command: Map.get(results, :command),
             question: Map.get(results, :question)
           }}

        {:error, _step, reason} ->
          {:error, reason}
      end
    end
  end

  # An approval ends the lifecycle and has nothing to continue. A rejection plans
  # its continuation before anything is written, so a run that cannot be
  # continued is refused rather than leaving a verdict behind with no way back
  # into development.
  defp continuation(_authority, %{outcome: "approved"}), do: {:ok, nil}

  defp continuation(authority, verdict) do
    with {:ok, run} <- rejected_run(authority, verdict),
         {:ok, attempt} <- latest_attempt(authority, verdict, run) do
      ReviewContinuation.plan(authority, %{
        feature: verdict.feature,
        run: run,
        attempt: attempt,
        feedback: verdict.feedback,
        contradicts_agreement?: Keyword.get(verdict.opts, :contradicts_agreement?, false),
        opts: verdict.opts
      })
    end
  end

  defp rejected_run(authority, verdict) do
    case DeliveryStore.fetch_run(authority, verdict.project_id, verdict.verified.run_id) do
      {:ok, %AgentRun{} = run} -> {:ok, run}
      :error -> {:error, :unknown_run}
    end
  end

  # The run's highest-numbered attempt rather than its current one, because the
  # attempt a reviewer judged may already have ended and the continuation still
  # needs the ordering and fence it has to advance past.
  defp latest_attempt(authority, verdict, run) do
    case DeliveryStore.latest_attempt(authority, verdict.project_id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, :no_attempt}
    end
  end

  # Each record is written exactly once. A second write of any of them in one
  # commit would be offered against the version its sibling just bumped and
  # rejected as stale. The history is one entry too: the device adapter numbers
  # activity from what is already committed, so two appends in one batch would
  # claim the same sequence.
  defp steps(verdict, attrs, nil) do
    [{:decision, {:insert_review_decision, attrs}}] ++
      feature_steps(verdict) ++
      [{:activity, {:append_activity, activity_attrs(verdict, attrs, %{})}}]
  end

  defp steps(verdict, attrs, continuation) do
    [{:decision, {:insert_review_decision, attrs}}] ++
      continuation.records ++
      [{:activity, {:append_activity, activity_attrs(verdict, attrs, continuation.payload)}}] ++
      continuation.commands
  end

  # An approval is the only decision that moves the board from here. Where a
  # rejection moves the feature is part of the continuation it commits with.
  defp feature_steps(%{outcome: "approved", feature: feature}),
    do: [{:feature, {:transition_feature, feature, @approved_column, []}}]

  defp feature_steps(_verdict), do: []

  defp decision_attrs(authority, verdict) do
    verified = verdict.verified
    commit_sha = verified.payload["commit_sha"]

    %{
      project_id: verdict.project_id,
      feature_id: verdict.feature.id,
      run_id: verified.run_id,
      attempt_id: verified.attempt_id,
      decision: verdict.outcome,
      feedback: verdict.feedback,
      reviewer_account_id: verdict.member.account_id,
      branch: verified.payload["branch"],
      commit_sha: commit_sha,
      preview_deployment_id: preview_id(authority, verdict.project_id, verified, commit_sha),
      decided_at: DateTime.utc_now()
    }
  end

  # The deployment of exactly the commit under review, when one exists. An absent
  # preview is the ordinary case and must never stop a decision being recorded.
  defp preview_id(authority, project_id, verified, commit_sha) do
    authority
    |> DeliveryStore.list_preview_deployments(project_id,
      run_id: verified.run_id,
      commit_sha: commit_sha,
      current: true
    )
    |> List.last()
    |> case do
      nil -> nil
      deployment -> deployment.id
    end
  end

  # The entry names the attempt the verdict was about, not the one a rejection
  # opens. A decision belongs to the proof it judged; what the continuation did
  # next is carried in the payload beside it.
  defp activity_attrs(verdict, attrs, continuation_payload) do
    %{
      project_id: verdict.project_id,
      feature_id: verdict.feature.id,
      run_id: attrs.run_id,
      attempt_id: attrs.attempt_id,
      actor_kind: "participant",
      actor_account_id: verdict.member.account_id,
      type: activity_type(verdict.outcome),
      payload: Map.merge(payload(verdict, attrs), continuation_payload)
    }
  end

  # An account reference and what was reviewed. No display name and no address
  # reaches a stored payload, because both are resolved from current
  # participation when a screen renders rather than frozen into history.
  defp payload(verdict, attrs) do
    %{
      "operation_key" => verdict.key,
      "decision" => attrs.decision,
      "column" => column_after(attrs.decision),
      "branch" => attrs.branch,
      "commit_sha" => attrs.commit_sha,
      "reviewer_account_id" => attrs.reviewer_account_id,
      "preview_deployment_id" => attrs.preview_deployment_id,
      "feedback" => excerpt(attrs.feedback)
    }
  end

  defp excerpt(nil), do: nil
  defp excerpt(feedback), do: String.slice(feedback, 0, @max_excerpt_characters)

  defp activity_type("approved"), do: @approved_activity
  defp activity_type("rejected"), do: @rejected_activity

  defp column_after("approved"), do: @approved_column
  defp column_after("rejected"), do: ReviewContinuation.column()

  # The attempt is the unit a verdict belongs to, so a resubmitted decision finds
  # its own earlier effect instead of colliding with the store's unique binding.
  defp operation_key(%ActivityEntry{attempt_id: attempt_id}),
    do: "review-decision:" <> attempt_id

  # A decided attempt is decided whichever way it went, so nothing is planned or
  # dispatched a second time. The records a first rejection created are already
  # in the store; repeating them here would be a second continuation of a run
  # that has already moved on.
  defp already_decided(authority, verdict) do
    {:ok,
     %{
       applied?: false,
       feature: current_feature(authority, verdict),
       decision: held_decision(authority, verdict),
       activity: recorded_entry(authority, verdict),
       attempt: nil,
       command: nil,
       question: nil
     }}
  end

  defp current_feature(authority, verdict) do
    case DeliveryStore.fetch_feature(authority, verdict.project_id, verdict.feature.id) do
      {:ok, feature} -> feature
      :error -> verdict.feature
    end
  end

  defp held_decision(authority, verdict) do
    authority
    |> DeliveryStore.list_review_decisions(verdict.project_id,
      run_id: verdict.verified.run_id,
      attempt_id: verdict.verified.attempt_id
    )
    |> List.last()
  end

  defp recorded_entry(authority, verdict) do
    authority
    |> DeliveryStore.list_activity(verdict.project_id, verdict.feature.id, limit: 200)
    |> Enum.find(&(&1.payload["operation_key"] == verdict.key))
  end
end
