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
    CommandOutbox,
    DeliveryStore,
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
  # schema produced it, so a caller can retry without inspecting changesets.
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
end
