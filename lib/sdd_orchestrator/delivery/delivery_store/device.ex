defmodule SddOrchestrator.Delivery.DeliveryStore.Device do
  @moduledoc """
  The worker-owned adapter for a device-authoritative project.

  Nothing this adapter writes reaches the hosted database. Records are the same
  plain value shapes the schemas expose through `to_value/1`, and the worker
  process is the serialization boundary that makes a batch atomic — the device
  equivalent of the hosted transaction, without a distributed one.

  Concurrency safety is the same rule stated differently. The hosted adapter
  gets it from an optimistic lock in the changeset; here each write carries the
  state version its author read, and the worker re-checks every one against
  what is stored before applying any of them.
  """
  @behaviour SddOrchestrator.Delivery.DeliveryStore

  alias SddOrchestrator.Delivery.{
    Activity,
    ActivityEntry,
    AgentRun,
    BlockingQuestion,
    DeliveryStore,
    Evidence,
    Feature,
    PreviewDeployment,
    ReviewDecision,
    RunAttempt,
    RunCommand
  }

  alias SddOrchestrator.Devices

  @impl true
  def commit(_authority, project_id, steps) do
    case build(project_id, steps, %{}, []) do
      {:ok, results, writes} -> apply_writes(project_id, writes, results)
      {:error, name, reason} -> {:error, name, reason}
    end
  end

  @impl true
  def fetch_run(_authority, project_id, run_id) do
    with {:ok, value} <- Devices.get_delivery(project_id, :run, run_id),
         {:ok, run} <- AgentRun.from_value(value) do
      {:ok, run}
    else
      _missing -> :error
    end
  end

  @impl true
  def fetch_feature(_authority, project_id, feature_id) do
    with {:ok, value} <- Devices.get_delivery(project_id, :feature, feature_id),
         {:ok, feature} <- Feature.from_value(value) do
      {:ok, feature}
    else
      _missing -> :error
    end
  end

  @impl true
  def list_features(_authority, project_id, opts) do
    project_id
    |> Devices.list_delivery(:feature)
    |> Enum.flat_map(fn value ->
      case Feature.from_value(value) do
        {:ok, feature} -> [feature]
        {:error, _reason} -> []
      end
    end)
    |> assigned_to(Keyword.get(opts, :assigned_account_id))
    |> Enum.sort_by(& &1.id)
  end

  @impl true
  def current_attempt(_authority, project_id, run_id) do
    project_id
    |> attempts(run_id)
    |> Enum.find(&RunAttempt.current?/1)
    |> case do
      nil -> :error
      attempt -> {:ok, attempt}
    end
  end

  @impl true
  def latest_attempt(_authority, project_id, run_id) do
    project_id
    |> attempts(run_id)
    |> Enum.max_by(& &1.attempt_number, fn -> nil end)
    |> case do
      nil -> :error
      attempt -> {:ok, attempt}
    end
  end

  @impl true
  def open_question(_authority, project_id, run_id) do
    project_id
    |> Devices.list_delivery(:question)
    |> Enum.flat_map(fn value ->
      case BlockingQuestion.from_value(value) do
        {:ok, question} -> [question]
        {:error, _reason} -> []
      end
    end)
    |> Enum.find(&(&1.run_id == run_id and BlockingQuestion.open?(&1)))
    |> case do
      nil -> :error
      question -> {:ok, question}
    end
  end

  @impl true
  def list_evidence(_authority, project_id, opts) do
    project_id
    |> Devices.list_delivery(:evidence)
    |> Enum.flat_map(fn value ->
      case Evidence.from_value(value) do
        {:ok, evidence} -> [evidence]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&matches_evidence_filters?(&1, opts))
    # Ordered by the recorded instant as a number rather than as a struct,
    # because Erlang term order over a `DateTime` is not chronological.
    |> Enum.sort_by(&{DateTime.to_unix(&1.recorded_at, :microsecond), &1.id})
  end

  @impl true
  def list_preview_deployments(_authority, project_id, opts) do
    project_id
    |> Devices.list_delivery(:preview)
    |> Enum.flat_map(fn value ->
      case PreviewDeployment.from_value(value) do
        {:ok, deployment} -> [deployment]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&matches_preview_filters?(&1, opts))
    # Ordered by the requested instant as a number rather than as a struct,
    # because Erlang term order over a `DateTime` is not chronological.
    |> Enum.sort_by(&{DateTime.to_unix(&1.requested_at, :microsecond), &1.id})
  end

  @impl true
  def list_review_decisions(_authority, project_id, opts) do
    project_id
    |> Devices.list_delivery(:review_decision)
    |> Enum.flat_map(fn value ->
      case ReviewDecision.from_value(value) do
        {:ok, decision} -> [decision]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&matches_decision_filters?(&1, opts))
    # Ordered by the decided instant as a number rather than as a struct,
    # because Erlang term order over a `DateTime` is not chronological.
    |> Enum.sort_by(&{DateTime.to_unix(&1.decided_at, :microsecond), &1.id})
  end

  @impl true
  def list_activity(_authority, project_id, feature_id, opts) do
    project_id
    |> Devices.list_delivery(:activity)
    |> Enum.flat_map(fn value ->
      case ActivityEntry.from_value(value) do
        {:ok, entry} -> [entry]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&(&1.feature_id == feature_id))
    |> Enum.sort_by(& &1.sequence)
    |> Enum.take(Keyword.get(opts, :limit, Activity.max_limit()))
  end

  @impl true
  def claim_commands(_authority, project_id, owner, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = Keyword.get(opts, :limit, 20)
    lease_seconds = Keyword.get(opts, :lease_seconds, 60)

    project_id
    |> due_commands(now)
    |> Enum.take(limit)
    |> Enum.map(&claim_one(project_id, &1, owner, DateTime.add(now, lease_seconds, :second)))
    |> Enum.flat_map(fn
      {:ok, command} -> [command]
      {:error, _reason} -> []
    end)
  end

  @impl true
  def acknowledge_command(_authority, project_id, command_id, result) do
    with {:ok, value} <- Devices.get_delivery(project_id, :command, command_id),
         {:ok, command} <- RunCommand.from_value(value) do
      acknowledge_recorded(project_id, command, result)
    else
      _missing -> {:error, :not_found}
    end
  end

  # The command's recorded result is the authoritative answer once it exists, so
  # a reconnecting worker acknowledging twice does not overwrite the first.
  defp acknowledge_recorded(_project_id, %RunCommand{state: "acknowledged"} = command, _result),
    do: {:ok, command}

  defp acknowledge_recorded(project_id, command, result) do
    acknowledged = %{command | state: "acknowledged", result: result}

    project_id
    |> Devices.commit_delivery([
      write(:command, acknowledged.id, RunCommand.to_value(acknowledged), nil)
    ])
    |> case do
      {:ok, _applied} -> {:ok, acknowledged}
      {:error, reason} -> {:error, reason}
    end
  end

  # Steps are folded in order so a later one can reference an earlier result,
  # exactly as the hosted `Ecto.Multi` does. Validation runs here, before any
  # write reaches the worker, so a rejected batch leaves nothing behind.
  defp build(_project_id, [], results, writes), do: {:ok, results, Enum.reverse(writes)}

  # Inserting an attempt is the one operation whose legality depends on what the
  # rest of this batch is doing, so it is the one operation that gets to see the
  # pending writes. Every continuation ends the current attempt and creates its
  # successor in a single commit; judging that against committed state alone
  # would reject the very pattern the hosted adapter allows.
  defp build(project_id, [{name, {:insert_attempt, attrs}} | rest], results, writes) do
    case insert_attempt(project_id, attrs, results, writes) do
      {:ok, record, write} ->
        build(project_id, rest, Map.put(results, name, record), [write | writes])

      {:error, reason} ->
        {:error, name, reason}
    end
  end

  defp build(project_id, [{name, operation} | rest], results, writes) do
    case apply_operation(project_id, operation, results) do
      {:ok, record, write} ->
        build(project_id, rest, Map.put(results, name, record), [write | writes])

      {:error, reason} ->
        {:error, name, reason}
    end
  end

  defp insert_attempt(project_id, attrs, results, writes) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <- RunAttempt.create_changeset(%RunAttempt{}, resolved),
         attempt = changeset |> Ecto.Changeset.apply_changes() |> put_id(),
         :ok <- ensure_one_current_attempt(project_id, attempt, writes) do
      {:ok, attempt, write(:attempt, attempt.id, RunAttempt.to_value(attempt), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, {:insert_run, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <- AgentRun.create_changeset(%AgentRun{}, resolved) do
      run = Ecto.Changeset.apply_changes(changeset) |> put_id()
      {:ok, run, write(:run, run.id, AgentRun.to_value(run), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, {:transition_run, run, to, opts}, _results),
    do: run_write(run, AgentRun.transition_changeset(run, to, run.state_version, opts))

  defp apply_operation(_project_id, {:set_effective_revision, run, id, digest}, _results),
    do:
      run_write(
        run,
        AgentRun.effective_revision_changeset(run, id, digest, run.state_version)
      )

  defp apply_operation(_project_id, {:advance_attempt_number, run, number}, _results),
    do: run_write(run, AgentRun.attempt_advance_changeset(run, number, run.state_version))

  defp apply_operation(_project_id, {:resume_run, run, id, digest, number}, _results),
    do: run_write(run, AgentRun.resume_changeset(run, id, digest, number, run.state_version))

  defp apply_operation(_project_id, {:transition_attempt, attempt, to}, _results),
    do:
      attempt_write(
        attempt,
        RunAttempt.transition_changeset(attempt, to, attempt.state_version)
      )

  defp apply_operation(_project_id, {:claim_lease, attempt, owner, expires_at}, _results),
    do:
      attempt_write(
        attempt,
        RunAttempt.claim_lease_changeset(attempt, owner, expires_at, attempt.state_version)
      )

  defp apply_operation(_project_id, {:observe_sequence, attempt, sequence}, _results),
    do:
      attempt_write(
        attempt,
        RunAttempt.observe_sequence_changeset(attempt, sequence, attempt.state_version)
      )

  defp apply_operation(_project_id, {:transition_feature, feature, to, opts}, _results),
    do:
      feature_write(
        feature,
        Feature.transition_changeset(feature, to, feature.state_version, opts)
      )

  defp apply_operation(_project_id, {:set_feature_status, feature, status}, _results),
    do: feature_write(feature, Feature.status_changeset(feature, status, feature.state_version))

  defp apply_operation(_project_id, {:clear_assignment, feature}, _results),
    do: feature_write(feature, Feature.assignment_changeset(feature, nil, feature.state_version))

  # The device store has no partial unique index, so the invariant the hosted
  # one gets from the database is checked here before any write is applied.
  defp apply_operation(project_id, {:insert_blocking_question, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <-
           BlockingQuestion.ask_changeset(%BlockingQuestion{}, resolved),
         question = changeset |> Ecto.Changeset.apply_changes() |> put_id(),
         :ok <- ensure_one_open_question(project_id, question) do
      {:ok, question, write(:question, question.id, BlockingQuestion.to_value(question), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, {:resolve_question, question, to, revision_id}, _results),
    do:
      question_write(
        question,
        BlockingQuestion.resolve_changeset(question, to, question.state_version, revision_id)
      )

  defp apply_operation(_project_id, {:insert_evidence, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <- Evidence.record_changeset(%Evidence{}, resolved) do
      evidence = changeset |> Ecto.Changeset.apply_changes() |> put_id()
      {:ok, evidence, write(:evidence, evidence.id, Evidence.to_value(evidence), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, {:supersede_evidence, evidence, replacement}, results) do
    with {:ok, replacement_id} <- DeliveryStore.resolve(replacement, results) do
      evidence_write(
        evidence,
        Evidence.supersede_changeset(evidence, replacement_id, evidence.state_version)
      )
    end
  end

  # The device store has no unique index, so the binding uniqueness the hosted
  # adapter gets from the database is checked here before any write is applied.
  # One run, attempt, and commit have one deployment in either authority.
  defp apply_operation(project_id, {:insert_preview_deployment, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <-
           PreviewDeployment.request_changeset(%PreviewDeployment{}, resolved),
         deployment = changeset |> Ecto.Changeset.apply_changes() |> put_id(),
         :ok <- ensure_one_deployment_per_binding(project_id, deployment) do
      {:ok, deployment,
       write(:preview, deployment.id, PreviewDeployment.to_value(deployment), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, {:observe_preview_deployment, deployment, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      preview_write(
        deployment,
        PreviewDeployment.observe_changeset(deployment, resolved, deployment.state_version)
      )
    end
  end

  defp apply_operation(
         _project_id,
         {:supersede_preview_deployment, deployment, replacement},
         results
       ) do
    with {:ok, replacement_id} <- DeliveryStore.resolve(replacement, results) do
      preview_write(
        deployment,
        PreviewDeployment.supersede_changeset(
          deployment,
          replacement_id,
          deployment.state_version
        )
      )
    end
  end

  defp apply_operation(_project_id, {:record_preview_cleanup, deployment, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      preview_write(
        deployment,
        PreviewDeployment.cleanup_changeset(deployment, resolved, deployment.state_version)
      )
    end
  end

  # The device store has no unique index, so the one-verdict-per-attempt rule the
  # hosted adapter gets from the database is checked here before any write is
  # applied. A double-submitted approval is refused in either authority.
  defp apply_operation(project_id, {:insert_review_decision, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <-
           ReviewDecision.record_changeset(%ReviewDecision{}, resolved),
         decision = changeset |> Ecto.Changeset.apply_changes() |> put_id(),
         :ok <- ensure_one_decision_per_attempt(project_id, decision) do
      {:ok, decision,
       write(:review_decision, decision.id, ReviewDecision.to_value(decision), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(project_id, {:append_activity, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         sequence = next_sequence(project_id, resolved),
         %{valid?: true} = changeset <-
           ActivityEntry.append_changeset(
             %ActivityEntry{},
             Map.put(resolved, :sequence, sequence)
           ) do
      entry = changeset |> Ecto.Changeset.apply_changes() |> put_id()
      {:ok, entry, write(:activity, entry.id, ActivityEntry.to_value(entry), nil)}
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(project_id, {:enqueue_command, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results),
         %{valid?: true} = changeset <- RunCommand.enqueue_changeset(%RunCommand{}, resolved) do
      command = Ecto.Changeset.apply_changes(changeset)
      recorded_or_new(project_id, command)
    else
      %Ecto.Changeset{} = invalid -> {:error, invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_operation(_project_id, _unknown, _results), do: {:error, :invalid_step}

  # An instruction already recorded under this ID replays its stored result
  # instead of producing a second command, matching the hosted outbox.
  defp recorded_or_new(project_id, command) do
    case Devices.get_delivery(project_id, :command, command.id) do
      {:ok, value} ->
        replay(value, command)

      {:error, :not_found} ->
        {:ok, command, write(:command, command.id, RunCommand.to_value(command), nil)}
    end
  end

  defp replay(value, command) do
    case RunCommand.from_value(value) do
      {:ok, %RunCommand{operation: operation} = recorded} when operation == command.operation ->
        {:ok, recorded, write(:command, recorded.id, value, nil)}

      {:ok, _different} ->
        {:error, :command_id_reused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_write(run, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()
    {:ok, updated, write(:run, updated.id, AgentRun.to_value(updated), run.state_version)}
  end

  defp run_write(_run, changeset), do: {:error, changeset}

  defp attempt_write(attempt, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()

    {:ok, updated,
     write(:attempt, updated.id, RunAttempt.to_value(updated), attempt.state_version)}
  end

  defp attempt_write(_attempt, changeset), do: {:error, changeset}

  defp feature_write(feature, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()

    {:ok, updated, write(:feature, updated.id, Feature.to_value(updated), feature.state_version)}
  end

  defp feature_write(_feature, changeset), do: {:error, changeset}

  defp question_write(question, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()

    {:ok, updated,
     write(:question, updated.id, BlockingQuestion.to_value(updated), question.state_version)}
  end

  defp question_write(_question, changeset), do: {:error, changeset}

  defp evidence_write(evidence, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()

    {:ok, updated,
     write(:evidence, updated.id, Evidence.to_value(updated), evidence.state_version)}
  end

  defp evidence_write(_evidence, changeset), do: {:error, changeset}

  defp preview_write(deployment, %{valid?: true} = changeset) do
    updated = changeset |> Ecto.Changeset.apply_changes() |> bump_version()

    {:ok, updated,
     write(:preview, updated.id, PreviewDeployment.to_value(updated), deployment.state_version)}
  end

  defp preview_write(_deployment, changeset), do: {:error, changeset}

  # `optimistic_lock/2` only takes effect inside `Repo.update`, which this
  # adapter never calls, so the increment is applied here. Without it the stored
  # version would never move and a superseded write would look current.
  defp bump_version(%{state_version: version} = record),
    do: %{record | state_version: version + 1}

  # The version the worker compares against is the one the caller read, so a
  # write built from a superseded record is rejected before anything is applied.
  defp write(kind, id, value, expected_version),
    do: {:put, kind, id, value, expected_version}

  defp apply_writes(project_id, writes, results) do
    case Devices.commit_delivery(project_id, writes) do
      {:ok, _applied} -> {:ok, results}
      {:error, reason} -> {:error, :commit, reason}
    end
  end

  defp attempts(project_id, run_id) do
    project_id
    |> Devices.list_delivery(:attempt)
    |> Enum.flat_map(fn value ->
      case RunAttempt.from_value(value) do
        {:ok, attempt} -> [attempt]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&(&1.run_id == run_id))
  end

  defp ensure_one_current_attempt(project_id, attempt, writes) do
    case current_attempt(nil, project_id, attempt.run_id) do
      {:ok, existing} ->
        if ended_in_batch?(existing, writes), do: :ok, else: {:error, :one_current_attempt}

      :error ->
        :ok
    end
  end

  # The committed store still shows the outgoing attempt as current, because
  # this batch has not been applied yet. An earlier step in the same batch that
  # moves it to a terminal state is what makes room for its successor.
  defp ended_in_batch?(%RunAttempt{id: id}, writes) do
    Enum.any?(writes, fn
      {:put, :attempt, ^id, value, _expected} ->
        value["state"] not in RunAttempt.current_states()

      _other ->
        false
    end)
  end

  defp ensure_one_deployment_per_binding(project_id, deployment) do
    nil
    |> list_preview_deployments(project_id,
      run_id: deployment.run_id,
      attempt_id: deployment.attempt_id,
      commit_sha: deployment.commit_sha
    )
    |> case do
      [] -> :ok
      _held -> {:error, :one_preview_per_binding}
    end
  end

  defp ensure_one_decision_per_attempt(project_id, decision) do
    nil
    |> list_review_decisions(project_id,
      run_id: decision.run_id,
      attempt_id: decision.attempt_id
    )
    |> case do
      [] -> :ok
      _held -> {:error, :one_decision_per_attempt}
    end
  end

  defp ensure_one_open_question(project_id, question) do
    case open_question(nil, project_id, question.run_id) do
      {:ok, _existing} -> {:error, :one_open_question}
      :error -> :ok
    end
  end

  defp next_sequence(project_id, attrs) do
    feature_id = Map.get(attrs, :feature_id) || Map.get(attrs, "feature_id")

    nil
    |> list_activity(project_id, feature_id, limit: Activity.max_limit())
    |> Enum.map(& &1.sequence)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp due_commands(project_id, now) do
    project_id
    |> Devices.list_delivery(:command)
    |> Enum.flat_map(fn value ->
      case RunCommand.from_value(value) do
        {:ok, command} -> [command]
        {:error, _reason} -> []
      end
    end)
    |> Enum.filter(&(&1.state == "pending" and DateTime.compare(&1.due_at, now) != :gt))
    |> Enum.sort_by(& &1.due_at, DateTime)
  end

  defp claim_one(project_id, command, owner, expires_at) do
    claimed = %{command | state: "claimed", claimed_by: owner, claim_expires_at: expires_at}

    project_id
    |> Devices.commit_delivery([write(:command, claimed.id, RunCommand.to_value(claimed), nil)])
    |> case do
      {:ok, _applied} -> {:ok, claimed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_id(%{id: nil} = record), do: %{record | id: Ecto.UUID.generate()}
  defp put_id(record), do: record

  # An absent option means every feature in the project, which is not the same
  # question as "assigned to nobody" and must not silently answer it.
  defp assigned_to(features, nil), do: features

  defp assigned_to(features, account_id),
    do: Enum.filter(features, &(&1.assigned_account_id == account_id))

  # An absent narrowing option asks for everything in the project rather than
  # for records whose field is nil, matching the hosted query.
  defp matches_evidence_filters?(evidence, opts) do
    Enum.all?(
      [
        {:run_id, evidence.run_id},
        {:attempt_id, evidence.attempt_id},
        {:commit_sha, evidence.commit_sha}
      ],
      fn {option, held} ->
        case Keyword.get(opts, option) do
          nil -> true
          wanted -> held == wanted
        end
      end
    ) and current_enough?(evidence, Keyword.get(opts, :current, false))
  end

  defp current_enough?(evidence, true), do: Evidence.current?(evidence)
  defp current_enough?(_evidence, _all), do: true

  # The same narrowing the hosted query applies to preview deployments: an
  # absent option asks for everything, never for records whose field is nil.
  defp matches_preview_filters?(deployment, opts) do
    Enum.all?(
      [
        {:run_id, deployment.run_id},
        {:attempt_id, deployment.attempt_id},
        {:commit_sha, deployment.commit_sha}
      ],
      fn {option, held} ->
        case Keyword.get(opts, option) do
          nil -> true
          wanted -> held == wanted
        end
      end
    ) and current_preview_enough?(deployment, Keyword.get(opts, :current, false))
  end

  defp current_preview_enough?(deployment, true), do: PreviewDeployment.current?(deployment)
  defp current_preview_enough?(_deployment, _all), do: true

  # The same narrowing the hosted query applies to review decisions: an absent
  # option asks for everything, never for records whose field is nil.
  defp matches_decision_filters?(decision, opts) do
    Enum.all?(
      [
        {:run_id, decision.run_id},
        {:attempt_id, decision.attempt_id},
        {:feature_id, decision.feature_id}
      ],
      fn {option, held} ->
        case Keyword.get(opts, option) do
          nil -> true
          wanted -> held == wanted
        end
      end
    )
  end
end
