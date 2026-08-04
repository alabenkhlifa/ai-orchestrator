defmodule SddOrchestrator.AIRuntime.QuotaPolicyAdapter.Default do
  @moduledoc """
  Deterministic provider-neutral quota applicability and consent evaluator.

  General buckets apply to every model. Model-specific buckets apply only to
  their exact model. Provider-defined scope is deliberately not guessed.
  """

  @behaviour SddOrchestrator.AIRuntime.QuotaPolicyAdapter

  @impl true
  def evaluate(context, _opts) do
    case scarcity_choice(context) do
      {:ok, scarcity_choice_ids} ->
        evaluate_quota(context, scarcity_choice_ids)

      {:pause, reason, buckets, choice_ids} ->
        pause_decision(context, reason, buckets, choice_ids)
    end
  end

  defp evaluate_quota(context, scarcity_choice_ids) do
    case quota_boundary(context) do
      :api_key ->
        {:ok,
         decision(
           context,
           :proceed_to_cost_reservation,
           :cost_reservation_required,
           [],
           scarcity_choice_ids,
           false
         )}

      {:continue, quota} ->
        evaluate_applicable_quota(context, quota, scarcity_choice_ids)

      {:pause, reason, buckets, choice_ids} ->
        pause_decision(context, reason, buckets, scarcity_choice_ids ++ choice_ids)

      {:error, :invalid_request} = error ->
        error
    end
  end

  defp evaluate_applicable_quota(context, quota, scarcity_choice_ids) do
    case applicable_buckets(quota.buckets, context.selection.model) do
      {:ok, applicable} ->
        evaluate_applicable_choices(context, applicable, scarcity_choice_ids)

      {:pause, reason, buckets, choice_ids} ->
        pause_decision(context, reason, buckets, scarcity_choice_ids ++ choice_ids)
    end
  end

  defp evaluate_applicable_choices(context, applicable, scarcity_choice_ids) do
    case model_specific_choices(context, applicable) do
      {:ok, model_choice_ids} ->
        case capacity_choice(context, applicable) do
          {:ok, paid_choice_ids, paid_continuation} ->
            {:ok,
             decision(
               context,
               :proceed,
               nil,
               applicable,
               scarcity_choice_ids ++ model_choice_ids ++ paid_choice_ids,
               paid_continuation
             )}

          {:pause, reason, buckets, choice_ids} ->
            pause_decision(
              context,
              reason,
              buckets,
              scarcity_choice_ids ++ model_choice_ids ++ choice_ids
            )
        end

      {:pause, reason, buckets, choice_ids} ->
        pause_decision(context, reason, buckets, scarcity_choice_ids ++ choice_ids)
    end
  end

  defp pause_decision(context, reason, buckets, choice_ids),
    do: {:ok, decision(context, :pause, reason, buckets, choice_ids, false)}

  defp scarcity_choice(%{selection: %{scarcity: :unknown}} = context) do
    pause(context, :scarcity_unknown)
  end

  defp scarcity_choice(%{selection: %{scarcity: :standard}}), do: {:ok, []}

  defp scarcity_choice(%{selection: %{scarcity: :scarce}} = context) do
    case choice(context, :scarce_model, nil, :scarce_model) do
      nil -> pause(context, :scarce_model_opt_in_required)
      choice -> {:ok, [choice.id]}
    end
  end

  defp quota_boundary(%{authentication_mode: "api_key", choices: choices}) do
    paid_choices = Enum.filter(choices, &(&1.kind == :provider_paid_continuation))

    if paid_choices == [] do
      :api_key
    else
      {:error, :invalid_request}
    end
  end

  defp quota_boundary(%{quota_error: :stale} = context), do: pause(context, :quota_stale)

  defp quota_boundary(%{quota_error: reason} = context) when not is_nil(reason),
    do: pause(context, :quota_unknown)

  defp quota_boundary(%{quota: nil} = context), do: pause(context, :quota_unknown)

  defp quota_boundary(%{quota: %{status: "unknown"}} = context),
    do: pause(context, :quota_unknown)

  defp quota_boundary(%{quota: %{buckets: []}} = context), do: pause(context, :quota_unknown)
  defp quota_boundary(%{quota: quota}), do: {:continue, quota}

  defp applicable_buckets(buckets, model) do
    if Enum.any?(buckets, &(&1.scope == "provider_defined")) do
      {:pause, :provider_defined_quota_applicability_unknown, [], []}
    else
      applicable =
        Enum.filter(buckets, fn bucket ->
          bucket.scope == "general" or
            (bucket.scope == "model_specific" and bucket.model == model)
        end)

      if applicable == [] do
        {:pause, :quota_unknown, [], []}
      else
        {:ok, applicable}
      end
    end
  end

  defp model_specific_choices(context, buckets) do
    buckets
    |> Enum.filter(&(&1.scope == "model_specific"))
    |> Enum.reduce_while({:ok, []}, fn bucket, {:ok, choice_ids} ->
      case choice(context, :model_specific_quota, bucket.id, :quota) do
        nil ->
          {:halt, {:pause, :model_specific_quota_opt_in_required, buckets, choice_ids}}

        choice ->
          {:cont, {:ok, choice_ids ++ [choice.id]}}
      end
    end)
  end

  defp capacity_choice(context, buckets) do
    buckets
    |> Enum.reduce_while({:ok, [], false}, fn bucket, {:ok, choice_ids, paid?} ->
      case capacity(bucket) do
        :available ->
          {:cont, {:ok, choice_ids, paid?}}

        :unknown ->
          {:halt, {:pause, :quota_capacity_unknown, buckets, choice_ids}}

        :exhausted ->
          paid_capacity(context, bucket, buckets, choice_ids)
      end
    end)
  end

  defp paid_capacity(_context, %{paid_continuation: "unknown"}, buckets, choice_ids),
    do: {:halt, {:pause, :paid_continuation_unknown, buckets, choice_ids}}

  defp paid_capacity(_context, %{paid_continuation: "unavailable"}, buckets, choice_ids),
    do: {:halt, {:pause, :paid_continuation_unavailable, buckets, choice_ids}}

  defp paid_capacity(context, %{paid_continuation: "available"} = bucket, buckets, choice_ids) do
    case choice(context, :provider_paid_continuation, bucket.id, :provider_paid_continuation) do
      nil ->
        {:halt, {:pause, :paid_continuation_approval_required, buckets, choice_ids}}

      choice ->
        {:cont, {:ok, choice_ids ++ [choice.id], true}}
    end
  end

  defp capacity(bucket) do
    windows = Enum.reject([bucket.primary_window, bucket.secondary_window], &is_nil/1)

    cond do
      bucket.spend_control_reached == true ->
        :exhausted

      not is_nil(bucket.spend_control) and bucket.spend_control.remaining_percent == 0 ->
        :exhausted

      not is_nil(bucket.limit_reached_reason) ->
        :exhausted

      Enum.any?(windows, &(&1.used_percent >= 100)) ->
        :exhausted

      is_nil(bucket.primary_window) ->
        :unknown

      true ->
        :available
    end
  end

  defp choice(context, kind, bucket_id, cost_boundary) do
    Enum.find(context.choices, fn choice ->
      choice.kind == kind and choice.bucket_id == bucket_id and
        choice.cost_boundary == cost_boundary
    end)
  end

  defp pause(_context, reason), do: {:pause, reason, [], []}

  defp decision(context, decision, reason, buckets, choice_ids, paid_continuation) do
    %{
      decision: decision,
      reason: reason,
      connection_id: context.selection.connection_id,
      model: context.selection.model,
      effort: context.selection.effort,
      quota_snapshot_id: quota_snapshot_id(context),
      applicable_bucket_ids: Enum.map(buckets, & &1.id),
      choice_ids: Enum.uniq(choice_ids),
      paid_continuation: paid_continuation
    }
  end

  defp quota_snapshot_id(%{quota: %{snapshot_id: snapshot_id}}), do: snapshot_id
  defp quota_snapshot_id(_context), do: nil
end
