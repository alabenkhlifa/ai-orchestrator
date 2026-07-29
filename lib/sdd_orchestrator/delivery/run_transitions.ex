defmodule SddOrchestrator.Delivery.RunTransitions do
  @moduledoc """
  The one place a run's state, its feature's column, its history, and its next
  worker instruction change together.

  Every state-changing delivery action goes through here, and each one commits
  exactly one authoritative transaction: the validated feature and run
  transitions, the ordered activity entry that records them, and any command
  the change produces. Nothing can leave the product in a state where the board
  says one thing, the history says another, and a worker was told a third.

  Requests carry an idempotent operation key. The append-only activity log is
  the ledger it is checked against, so a retried request, a double-clicked
  button, and a redelivered worker event all find their own earlier effect and
  return it instead of applying a second time. That check is what makes it safe
  for a caller to retry a transition it is unsure committed.

  Both storage authorities are reached through the same `DeliveryStore` step
  list, so a hosted and a device-authoritative project apply identical rules.
  """

  alias SddOrchestrator.Delivery.{AgentRun, DeliveryStore, Feature, RunAttempt}

  @type authority :: DeliveryStore.authority()

  @type request :: %{
          required(:operation_key) => String.t(),
          required(:project_id) => Ecto.UUID.t(),
          required(:feature) => Feature.t(),
          required(:activity) => map(),
          optional(:run) => AgentRun.t() | nil,
          optional(:feature_column) => String.t() | nil,
          optional(:feature_status) => String.t() | nil,
          optional(:run_state) => String.t() | nil,
          optional(:run_opts) => keyword(),
          optional(:attempt) => RunAttempt.t() | nil,
          optional(:attempt_state) => String.t() | nil,
          optional(:command) => map() | nil
        }

  @type outcome :: %{
          required(:applied?) => boolean(),
          required(:results) => map()
        }

  @type error :: :stale_state | :invalid_request | term()

  @doc """
  Applies one validated transition, its activity, and any resulting command.

  Returns `applied?: false` when the operation key shows this exact change
  already committed, which is the difference between a safe retry and a
  duplicate dispatch.
  """
  @spec apply(authority(), request()) :: {:ok, outcome()} | {:error, error()}
  def apply(authority, %{operation_key: key, project_id: project_id, feature: feature} = request)
      when is_binary(key) do
    case recorded(authority, project_id, feature.id, key) do
      {:ok, entry} -> {:ok, %{applied?: false, results: %{activity: entry}}}
      :error -> commit(authority, request)
    end
  end

  def apply(_authority, _request), do: {:error, :invalid_request}

  @doc """
  Reports whether an operation key has already been applied to one feature.

  Exposed so a caller can decide before doing expensive preparation, not only
  after.
  """
  @spec applied?(authority(), Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: boolean()
  def applied?(authority, project_id, feature_id, key),
    do: match?({:ok, _entry}, recorded(authority, project_id, feature_id, key))

  defp commit(authority, request) do
    steps = build_steps(request)

    case DeliveryStore.commit(authority, request.project_id, steps) do
      {:ok, results} -> {:ok, %{applied?: true, results: results}}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # Order matters: the feature and run move first so the activity and command
  # that describe them cannot be written against a transition that was rejected.
  defp build_steps(request) do
    []
    |> feature_step(request)
    |> run_step(request)
    |> attempt_step(request)
    |> activity_step(request)
    |> command_step(request)
    |> Enum.reverse()
  end

  defp feature_step(steps, %{feature: feature, feature_column: column} = request)
       when is_binary(column) do
    opts = status_opts(request)
    [{:feature, {:transition_feature, feature, column, opts}} | steps]
  end

  defp feature_step(steps, %{feature: feature, feature_status: status})
       when is_binary(status) do
    [{:feature, {:set_feature_status, feature, status}} | steps]
  end

  defp feature_step(steps, _request), do: steps

  defp run_step(steps, %{run: %AgentRun{} = run, run_state: state} = request)
       when is_binary(state) do
    opts = Map.get(request, :run_opts, [])
    [{:run, {:transition_run, run, state, opts}} | steps]
  end

  defp run_step(steps, _request), do: steps

  defp attempt_step(steps, %{attempt: %RunAttempt{} = attempt, attempt_state: state})
       when is_binary(state) do
    [{:attempt, {:transition_attempt, attempt, state}} | steps]
  end

  defp attempt_step(steps, _request), do: steps

  # The operation key is stamped into the activity payload, which is what makes
  # the append-only history usable as the idempotency ledger.
  defp activity_step(steps, %{activity: activity, operation_key: key}) do
    payload = activity |> Map.get(:payload, %{}) |> Map.put("operation_key", key)

    [{:activity, {:append_activity, Map.put(activity, :payload, payload)}} | steps]
  end

  defp command_step(steps, %{command: command}) when is_map(command),
    do: [{:command, {:enqueue_command, command}} | steps]

  defp command_step(steps, _request), do: steps

  defp status_opts(%{feature_status: status}) when is_binary(status), do: [status: status]
  defp status_opts(_request), do: []

  defp recorded(authority, project_id, feature_id, key) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.find(&(&1.payload["operation_key"] == key))
    |> case do
      nil -> :error
      entry -> {:ok, entry}
    end
  end
end
