defmodule SddOrchestrator.AIRuntime.QuotaPolicyAdapter do
  @moduledoc """
  Provider-neutral boundary for deterministic quota and paid-use decisions.

  The owner-scoped policy context supplies one already selected connection,
  model, and effort. Adapters may only decide whether that exact selection can
  proceed, must first enter the API-key cost-reservation boundary, or must
  pause. They cannot select a fallback or change the cost boundary.
  """

  @decision_keys ~w(
    decision reason connection_id model effort quota_snapshot_id
    applicable_bucket_ids choice_ids paid_continuation
  )a

  @decisions ~w(proceed proceed_to_cost_reservation pause)a
  @pause_reasons ~w(
    scarcity_unknown scarce_model_opt_in_required quota_unknown quota_stale
    quota_capacity_unknown model_specific_quota_opt_in_required
    provider_defined_quota_applicability_unknown quota_exhausted
    paid_continuation_unknown paid_continuation_unavailable
    paid_continuation_approval_required
  )a

  @typedoc "A validated request and its current owner-scoped runtime facts."
  @type context :: %{
          account_id: Ecto.UUID.t(),
          authentication_mode: String.t(),
          selection: map(),
          choices: [map()],
          quota: map() | nil,
          quota_error: atom() | nil,
          now: DateTime.t()
        }

  @typedoc "Safe failures exposed by a policy adapter."
  @type error :: :invalid_request | :invalid_response

  @callback evaluate(context(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Validates an adapter decision against the immutable selected boundary."
  @spec validate_result(map(), context()) :: {:ok, map()} | {:error, :invalid_response}
  def validate_result(result, context) when is_map(result) and is_map(context) do
    with {:ok, result} <- exact_map(result, @decision_keys),
         {:ok, decision} <- normalize_member(result.decision, @decisions),
         {:ok, reason} <- normalize_reason(result.reason),
         true <- result.connection_id == context.selection.connection_id,
         true <- result.model == context.selection.model,
         true <- result.effort == context.selection.effort,
         :ok <- validate_decision_reason(decision, reason, context.authentication_mode),
         :ok <- validate_snapshot(result.quota_snapshot_id, context),
         {:ok, bucket_ids} <-
           validate_ids(result.applicable_bucket_ids, allowed_bucket_ids(context)),
         {:ok, choice_ids} <- validate_ids(result.choice_ids, allowed_choice_ids(context)),
         true <- is_boolean(result.paid_continuation),
         true <- decision != :proceed_to_cost_reservation or result.paid_continuation == false,
         normalized = %{
           decision: decision,
           reason: reason,
           connection_id: result.connection_id,
           model: result.model,
           effort: result.effort,
           quota_snapshot_id: result.quota_snapshot_id,
           applicable_bucket_ids: bucket_ids,
           choice_ids: choice_ids,
           paid_continuation: result.paid_continuation
         },
         :ok <- validate_authoritative_decision(normalized, context) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_result(_result, _context), do: {:error, :invalid_response}

  @doc "Collapses adapter failures to the policy boundary's safe vocabulary."
  @spec normalize_error(term()) :: error()
  def normalize_error(:invalid_request), do: :invalid_request
  def normalize_error(_reason), do: :invalid_response

  defp normalize_reason(nil), do: {:ok, nil}

  defp normalize_reason(reason),
    do: normalize_member(reason, @pause_reasons ++ [:cost_reservation_required])

  defp validate_decision_reason(:proceed, nil, _authentication_mode), do: :ok

  defp validate_decision_reason(
         :proceed_to_cost_reservation,
         :cost_reservation_required,
         "api_key"
       ),
       do: :ok

  defp validate_decision_reason(:pause, reason, _authentication_mode)
       when reason in @pause_reasons,
       do: :ok

  defp validate_decision_reason(_decision, _reason, _authentication_mode),
    do: {:error, :invalid_response}

  defp validate_snapshot(nil, %{authentication_mode: "api_key"}), do: :ok

  defp validate_snapshot(snapshot_id, %{quota: %{snapshot_id: snapshot_id}})
       when is_binary(snapshot_id),
       do: :ok

  defp validate_snapshot(nil, %{quota: nil}), do: :ok
  defp validate_snapshot(_snapshot_id, _context), do: {:error, :invalid_response}

  defp allowed_bucket_ids(%{quota: %{buckets: buckets}}) when is_list(buckets),
    do: MapSet.new(Enum.map(buckets, & &1.id))

  defp allowed_bucket_ids(_context), do: MapSet.new()

  defp allowed_choice_ids(%{choices: choices}) when is_list(choices),
    do: MapSet.new(Enum.map(choices, & &1.id))

  defp allowed_choice_ids(_context), do: MapSet.new()

  defp validate_ids(ids, allowed) when is_list(ids) and length(ids) <= 64 do
    with true <- ids == Enum.uniq(ids),
         true <- Enum.all?(ids, &(is_binary(&1) and MapSet.member?(allowed, &1))) do
      {:ok, ids}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_ids(_ids, _allowed), do: {:error, :invalid_response}

  defp validate_authoritative_decision(result, context) do
    case SddOrchestrator.AIRuntime.QuotaPolicyAdapter.Default.evaluate(context, []) do
      {:ok, expected} when result == expected -> :ok
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_member(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_response}
  end

  defp normalize_member(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_response}
      member -> {:ok, member}
    end
  end

  defp normalize_member(_value, _allowed), do: {:error, :invalid_response}

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :invalid_response}
    end
  end
end
