defmodule SddOrchestrator.Delivery.DeliveryStore.Hosted do
  @moduledoc """
  The PostgreSQL adapter for feature-delivery state.

  Steps become one `Ecto.Multi`, so the database provides atomicity and the
  expected-version checks already built into each schema's changesets provide
  concurrency safety. Nothing here re-implements those rules; the adapter's job
  is to translate the shared step vocabulary into the changesets that own them.
  """
  @behaviour SddOrchestrator.Delivery.DeliveryStore

  import Ecto.Query

  alias Ecto.Multi

  alias SddOrchestrator.Delivery.{
    Activity,
    ActivityEntry,
    AgentRun,
    BlockingQuestion,
    CommandOutbox,
    DeliveryStore,
    Evidence,
    Feature,
    RunAttempt
  }

  alias SddOrchestrator.Repo

  @impl true
  def commit(_authority, _project_id, steps) do
    steps
    |> Enum.reduce(Multi.new(), &add_step(&2, &1))
    |> Repo.transaction()
    |> case do
      {:ok, results} -> {:ok, results}
      {:error, name, reason, _changes} -> {:error, name, normalize(reason)}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :commit, :stale_state}
  end

  @impl true
  def fetch_run(_authority, project_id, run_id) do
    AgentRun
    |> where([r], r.project_id == ^project_id and r.id == ^run_id)
    |> Repo.one()
    |> case do
      nil -> :error
      run -> {:ok, run}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @impl true
  def fetch_feature(_authority, project_id, feature_id) do
    Feature
    |> where([f], f.project_id == ^project_id and f.id == ^feature_id)
    |> Repo.one()
    |> case do
      nil -> :error
      feature -> {:ok, feature}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @impl true
  def list_features(_authority, project_id, opts) do
    Feature
    |> where([f], f.project_id == ^project_id)
    |> assigned_to(Keyword.get(opts, :assigned_account_id))
    |> order_by([f], asc: f.inserted_at, asc: f.id)
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @impl true
  def current_attempt(_authority, _project_id, run_id) do
    RunAttempt
    |> where([a], a.run_id == ^run_id and a.state in ^RunAttempt.current_states())
    |> Repo.one()
    |> case do
      nil -> :error
      attempt -> {:ok, attempt}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @impl true
  def latest_attempt(_authority, _project_id, run_id) do
    RunAttempt
    |> where([a], a.run_id == ^run_id)
    |> order_by([a], desc: a.attempt_number)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> :error
      attempt -> {:ok, attempt}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @impl true
  def open_question(_authority, _project_id, run_id) do
    BlockingQuestion
    |> where([q], q.run_id == ^run_id and q.state == "open")
    |> Repo.one()
    |> case do
      nil -> :error
      question -> {:ok, question}
    end
  rescue
    Ecto.Query.CastError -> :error
  end

  @impl true
  def list_evidence(_authority, project_id, opts) do
    Evidence
    |> where([e], e.project_id == ^project_id)
    |> narrow(:run_id, Keyword.get(opts, :run_id))
    |> narrow(:attempt_id, Keyword.get(opts, :attempt_id))
    |> narrow(:commit_sha, Keyword.get(opts, :commit_sha))
    |> only_current(Keyword.get(opts, :current, false))
    |> order_by([e], asc: e.recorded_at, asc: e.id)
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @impl true
  def list_activity(_authority, project_id, feature_id, opts) do
    ActivityEntry
    |> where([e], e.project_id == ^project_id and e.feature_id == ^feature_id)
    |> order_by([e], asc: e.sequence)
    |> limit(^Keyword.get(opts, :limit, Activity.max_limit()))
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @impl true
  def claim_commands(_authority, project_id, owner, opts) do
    owner
    |> CommandOutbox.claim(opts)
    |> Enum.filter(&(&1.project_id == project_id))
  end

  @impl true
  def acknowledge_command(_authority, _project_id, command_id, result),
    do: CommandOutbox.acknowledge(command_id, result)

  defp add_step(multi, {name, operation}) do
    Multi.run(multi, name, fn repo, results ->
      apply_operation(repo, operation, results)
    end)
  end

  defp apply_operation(repo, {:insert_run, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      %AgentRun{} |> AgentRun.create_changeset(resolved) |> repo.insert()
    end
  end

  defp apply_operation(repo, {:transition_run, run, to, opts}, _results),
    do: run |> AgentRun.transition_changeset(to, run.state_version, opts) |> repo.update()

  defp apply_operation(repo, {:set_effective_revision, run, id, digest}, _results) do
    run
    |> AgentRun.effective_revision_changeset(id, digest, run.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:advance_attempt_number, run, number}, _results) do
    run
    |> AgentRun.attempt_advance_changeset(number, run.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:resume_run, run, id, digest, number}, _results) do
    run
    |> AgentRun.resume_changeset(id, digest, number, run.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:insert_attempt, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      %RunAttempt{} |> RunAttempt.create_changeset(resolved) |> repo.insert()
    end
  end

  defp apply_operation(repo, {:transition_attempt, attempt, to}, _results) do
    attempt
    |> RunAttempt.transition_changeset(to, attempt.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:claim_lease, attempt, owner, expires_at}, _results) do
    attempt
    |> RunAttempt.claim_lease_changeset(owner, expires_at, attempt.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:observe_sequence, attempt, sequence}, _results) do
    attempt
    |> RunAttempt.observe_sequence_changeset(sequence, attempt.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:transition_feature, feature, to, opts}, _results) do
    feature
    |> Feature.transition_changeset(to, feature.state_version, opts)
    |> repo.update()
  end

  defp apply_operation(repo, {:set_feature_status, feature, status}, _results) do
    feature
    |> Feature.status_changeset(status, feature.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:clear_assignment, feature}, _results) do
    feature
    |> Feature.assignment_changeset(nil, feature.state_version)
    |> repo.update()
  end

  defp apply_operation(repo, {:insert_blocking_question, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      %BlockingQuestion{} |> BlockingQuestion.ask_changeset(resolved) |> repo.insert()
    end
  end

  defp apply_operation(repo, {:resolve_question, question, to, revision_id}, _results) do
    question
    |> BlockingQuestion.resolve_changeset(to, question.state_version, revision_id)
    |> repo.update()
  end

  defp apply_operation(repo, {:insert_evidence, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      %Evidence{} |> Evidence.record_changeset(resolved) |> repo.insert()
    end
  end

  defp apply_operation(repo, {:supersede_evidence, evidence, replacement}, results) do
    with {:ok, replacement_id} <- DeliveryStore.resolve(replacement, results) do
      evidence
      |> Evidence.supersede_changeset(replacement_id, evidence.state_version)
      |> repo.update()
    end
  end

  defp apply_operation(repo, {:append_activity, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      %ActivityEntry{}
      |> ActivityEntry.append_changeset(
        Map.put(resolved, :sequence, Activity.next_sequence(resolved))
      )
      |> repo.insert()
    end
  end

  defp apply_operation(repo, {:enqueue_command, attrs}, results) do
    with {:ok, resolved} <- DeliveryStore.resolve(attrs, results) do
      Multi.new()
      |> CommandOutbox.enqueue_multi(:command, resolved)
      |> repo.transaction()
      |> case do
        {:ok, %{command: command}} -> {:ok, command}
        {:error, :command, reason, _changes} -> {:error, reason}
      end
    end
  end

  defp apply_operation(_repo, _unknown, _results), do: {:error, :invalid_step}

  # A rejected expected-version check reaches the caller as one reason whatever
  # schema produced it, so a caller can retry without inspecting changesets. An
  # illegal transition is deliberately not folded in here: retrying it would
  # never help, and a caller must be able to tell the two apart.
  defp normalize(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :state_version) or
         Keyword.has_key?(changeset.errors, :last_sequence) or
         Keyword.has_key?(changeset.errors, :current_attempt_number) do
      :stale_state
    else
      changeset
    end
  end

  defp normalize(reason), do: reason

  # An absent option means every feature in the project, which is not the same
  # question as "assigned to nobody" and must not silently answer it.
  defp assigned_to(query, nil), do: query

  defp assigned_to(query, account_id),
    do: where(query, [f], f.assigned_account_id == ^account_id)

  # An absent narrowing option asks for everything in the project rather than
  # for rows whose column is null.
  defp narrow(query, _field, nil), do: query
  defp narrow(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  defp only_current(query, true), do: where(query, [e], is_nil(e.superseded_by_id))
  defp only_current(query, _all), do: query
end
