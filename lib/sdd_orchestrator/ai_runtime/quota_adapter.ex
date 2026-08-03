defmodule SddOrchestrator.AIRuntime.QuotaAdapter do
  @moduledoc """
  Provider-neutral boundary for minimized quota and token-activity facts.

  Adapter results use an exact bounded vocabulary. Missing values stay explicit
  unknowns, arbitrary provider buckets remain independent, and API-key
  connections cannot acquire ChatGPT quota or billing facts through this
  contract.
  """

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.AIRuntime.PersonalAIConnection

  @result_keys ~w(
    status provider authentication_mode source source_methods source_version retrieved_at
    buckets reset_credits token_activity unknown_fields
  )a
  @bucket_keys ~w(
    id scope model display_name primary_window secondary_window credits paid_continuation
    spend_control spend_control_reached limit_reached_reason unknown_fields
  )a
  @window_keys ~w(used_percent resets_at duration_minutes unknown_fields)a
  @credits_keys ~w(has_credits unlimited balance unknown_fields)a
  @spend_control_keys ~w(limit used remaining_percent resets_at unknown_fields)a
  @reset_credit_keys ~w(available_count unknown_fields)a
  @token_activity_keys ~w(
    lifetime_tokens peak_daily_tokens current_streak_days longest_streak_days
    longest_running_turn_seconds unknown_fields
  )a

  @statuses ~w(reported partial unknown)
  @authentication_modes ~w(chatgpt api_key)
  @scopes ~w(general model_specific provider_defined)
  @paid_continuation_states ~w(available unavailable unknown)
  @source_methods ~w(account/rateLimits/read account/usage/read)
  @limit_reached_reasons ~w(
    rate_limit_reached workspace_owner_credits_depleted
    workspace_member_credits_depleted workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )

  @max_buckets 64
  @max_unknown_fields 64
  @max_identifier_bytes 255
  @max_display_name_bytes 200
  @max_value_bytes 100
  @max_source_version_bytes 200
  @max_result_bytes 64 * 1_024
  @codex_source_version_pattern ~r/\Acodex-cli [0-9A-Za-z._+-]+\|schema:[0-9a-f]{64}\z/
  @unknown_field_pattern ~r/\A[a-z][a-z0-9_.-]*\z/

  @typedoc "Failures safe to expose outside an adapter."
  @type error ::
          :worker_unavailable
          | :timeout
          | :incompatible
          | :invalid_request
          | :invalid_response

  @type window :: %{
          used_percent: non_neg_integer(),
          resets_at: DateTime.t() | nil,
          duration_minutes: non_neg_integer() | nil,
          unknown_fields: [String.t()]
        }

  @type bucket :: %{
          id: String.t(),
          scope: String.t(),
          model: String.t() | nil,
          display_name: String.t() | nil,
          primary_window: window() | nil,
          secondary_window: window() | nil,
          credits: map() | nil,
          paid_continuation: String.t(),
          spend_control: map() | nil,
          spend_control_reached: boolean() | nil,
          limit_reached_reason: String.t() | nil,
          unknown_fields: [String.t()]
        }

  @type result :: %{
          status: String.t(),
          provider: String.t(),
          authentication_mode: String.t(),
          source: String.t(),
          source_methods: [String.t()],
          source_version: String.t(),
          retrieved_at: DateTime.t(),
          buckets: [bucket()],
          reset_credits: map() | nil,
          token_activity: map() | nil,
          unknown_fields: [String.t()]
        }

  @callback fetch(Account.t(), PersonalAIConnection.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Validates one exact quota result against the selected connection binding."
  @spec validate_result(map(), String.t(), String.t()) ::
          {:ok, result()} | {:error, :invalid_response}
  def validate_result(result, expected_provider, expected_authentication_mode)
      when is_map(result) and is_binary(expected_provider) and
             is_binary(expected_authentication_mode) do
    with {:ok, normalized} <- exact_map(result, @result_keys),
         true <- normalized.status in @statuses,
         true <- normalized.provider == expected_provider,
         true <- normalized.authentication_mode == expected_authentication_mode,
         true <- normalized.authentication_mode in @authentication_modes,
         {:ok, methods} <- validate_source_methods(normalized.source_methods),
         :ok <-
           validate_provenance(
             normalized.provider,
             normalized.source,
             methods,
             normalized.source_version
           ),
         {:ok, retrieved_at} <- normalize_datetime(normalized.retrieved_at),
         {:ok, buckets} <- validate_buckets(normalized.buckets),
         {:ok, reset_credits} <- validate_reset_credits(normalized.reset_credits),
         {:ok, token_activity} <- validate_token_activity(normalized.token_activity),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         safe = %{
           normalized
           | source_methods: methods,
             retrieved_at: retrieved_at,
             buckets: buckets,
             reset_credits: reset_credits,
             token_activity: token_activity,
             unknown_fields: unknown_fields
         },
         :ok <- validate_method_fact_binding(safe),
         :ok <- validate_authentication_boundary(safe),
         :ok <- validate_encoded_size(safe) do
      {:ok, safe}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_result(_result, _expected_provider, _expected_authentication_mode),
    do: {:error, :invalid_response}

  @doc "Validates verified compatibility provenance without accepting plan identity."
  @spec validate_provenance(String.t(), String.t(), [String.t()], String.t()) ::
          :ok | {:error, :invalid_response}
  def validate_provenance("openai_codex", "official_client", methods, source_version)
      when is_list(methods) and is_binary(source_version) do
    with true <- Enum.all?(methods, &(&1 in @source_methods)),
         true <- methods == Enum.uniq(methods),
         true <- byte_size(source_version) <= @max_source_version_bytes,
         true <- Regex.match?(@codex_source_version_pattern, source_version) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_provenance(_provider, _source, _methods, _source_version),
    do: {:error, :invalid_response}

  @doc "Validates arbitrary normalized general and model-specific buckets."
  @spec validate_buckets(term()) :: {:ok, [bucket()]} | {:error, :invalid_response}
  def validate_buckets(buckets) when is_list(buckets) and length(buckets) <= @max_buckets do
    with {:ok, buckets} <- map_ok(buckets, &validate_bucket/1),
         true <- unique_by?(buckets, &{&1.scope, &1.id}) do
      {:ok, buckets}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_buckets(_buckets), do: {:error, :invalid_response}

  @doc "Collapses arbitrary provider and transport failures to a safe vocabulary."
  @spec normalize_error(term()) :: error()
  def normalize_error(reason)
      when reason in [:worker_unavailable, :timeout, :incompatible, :invalid_request],
      do: reason

  def normalize_error(:worker_disconnected), do: :worker_unavailable
  def normalize_error(:unsupported_capability), do: :incompatible
  def normalize_error(_reason), do: :invalid_response

  @doc false
  def max_buckets, do: @max_buckets

  @doc false
  def max_source_version_bytes, do: @max_source_version_bytes

  defp validate_bucket(bucket) when is_map(bucket) do
    with {:ok, normalized} <- exact_map(bucket, @bucket_keys),
         :ok <- bounded_string(normalized.id, @max_identifier_bytes),
         true <- normalized.scope in @scopes,
         :ok <- validate_model_scope(normalized.scope, normalized.model),
         :ok <- nullable_bounded_string(normalized.display_name, @max_display_name_bytes),
         {:ok, primary_window} <- validate_window(normalized.primary_window),
         {:ok, secondary_window} <- validate_window(normalized.secondary_window),
         {:ok, credits} <- validate_credits(normalized.credits),
         true <- normalized.paid_continuation in @paid_continuation_states,
         {:ok, spend_control} <- validate_spend_control(normalized.spend_control),
         true <-
           is_nil(normalized.spend_control_reached) or
             is_boolean(normalized.spend_control_reached),
         :ok <- validate_limit_reached_reason(normalized.limit_reached_reason),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         :ok <- validate_scope_unknowns(normalized.scope, unknown_fields),
         :ok <-
           require_unknowns(unknown_fields, [
             {"display_name", normalized.display_name},
             {"primary_window", primary_window},
             {"secondary_window", secondary_window},
             {"credits", credits},
             {"paid_continuation",
              if(normalized.paid_continuation == "unknown", do: nil, else: :known)},
             {"spend_control", spend_control},
             {"spend_control_reached", normalized.spend_control_reached},
             {"limit_reached_reason", normalized.limit_reached_reason}
           ]) do
      {:ok,
       %{
         normalized
         | primary_window: primary_window,
           secondary_window: secondary_window,
           credits: credits,
           spend_control: spend_control,
           unknown_fields: unknown_fields
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_bucket(_bucket), do: {:error, :invalid_response}

  defp validate_model_scope("general", nil), do: :ok

  defp validate_model_scope("model_specific", model),
    do: bounded_string(model, @max_identifier_bytes)

  defp validate_model_scope("provider_defined", nil), do: :ok

  defp validate_model_scope(_scope, _model), do: {:error, :invalid_response}

  defp validate_window(nil), do: {:ok, nil}

  defp validate_window(window) when is_map(window) do
    with {:ok, normalized} <- exact_map(window, @window_keys),
         true <- is_integer(normalized.used_percent) and normalized.used_percent in 0..100,
         {:ok, resets_at} <- normalize_nullable_datetime(normalized.resets_at),
         :ok <- nullable_positive_integer(normalized.duration_minutes),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         :ok <-
           require_unknowns(unknown_fields, [
             {"resets_at", resets_at},
             {"duration_minutes", normalized.duration_minutes}
           ]) do
      {:ok, %{normalized | resets_at: resets_at, unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_window(_window), do: {:error, :invalid_response}

  defp validate_credits(nil), do: {:ok, nil}

  defp validate_credits(credits) when is_map(credits) do
    with {:ok, normalized} <- exact_map(credits, @credits_keys),
         true <- is_boolean(normalized.has_credits),
         true <- is_boolean(normalized.unlimited),
         :ok <- nullable_bounded_string(normalized.balance, @max_value_bytes),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         :ok <- require_unknowns(unknown_fields, [{"balance", normalized.balance}]) do
      {:ok, %{normalized | unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_credits(_credits), do: {:error, :invalid_response}

  defp validate_spend_control(nil), do: {:ok, nil}

  defp validate_spend_control(spend_control) when is_map(spend_control) do
    with {:ok, normalized} <- exact_map(spend_control, @spend_control_keys),
         :ok <- bounded_string(normalized.limit, @max_value_bytes),
         :ok <- bounded_string(normalized.used, @max_value_bytes),
         true <-
           is_integer(normalized.remaining_percent) and normalized.remaining_percent in 0..100,
         {:ok, resets_at} <- normalize_datetime(normalized.resets_at),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields) do
      {:ok, %{normalized | resets_at: resets_at, unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_spend_control(_spend_control), do: {:error, :invalid_response}

  defp validate_limit_reached_reason(nil), do: :ok

  defp validate_limit_reached_reason(reason) when reason in @limit_reached_reasons, do: :ok
  defp validate_limit_reached_reason(_reason), do: {:error, :invalid_response}

  defp validate_reset_credits(nil), do: {:ok, nil}

  defp validate_reset_credits(reset_credits) when is_map(reset_credits) do
    with {:ok, normalized} <- exact_map(reset_credits, @reset_credit_keys),
         true <- is_integer(normalized.available_count) and normalized.available_count >= 0,
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields) do
      {:ok, %{normalized | unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_reset_credits(_reset_credits), do: {:error, :invalid_response}

  defp validate_token_activity(nil), do: {:ok, nil}

  defp validate_token_activity(token_activity) when is_map(token_activity) do
    with {:ok, normalized} <- exact_map(token_activity, @token_activity_keys),
         :ok <- nullable_non_negative_integer(normalized.lifetime_tokens),
         :ok <- nullable_non_negative_integer(normalized.peak_daily_tokens),
         :ok <- nullable_non_negative_integer(normalized.current_streak_days),
         :ok <- nullable_non_negative_integer(normalized.longest_streak_days),
         :ok <- nullable_non_negative_integer(normalized.longest_running_turn_seconds),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         :ok <-
           require_unknowns(unknown_fields, [
             {"lifetime_tokens", normalized.lifetime_tokens},
             {"peak_daily_tokens", normalized.peak_daily_tokens},
             {"current_streak_days", normalized.current_streak_days},
             {"longest_streak_days", normalized.longest_streak_days},
             {"longest_running_turn_seconds", normalized.longest_running_turn_seconds}
           ]) do
      {:ok, %{normalized | unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_token_activity(_token_activity), do: {:error, :invalid_response}

  defp validate_authentication_boundary(%{
         authentication_mode: "api_key",
         status: "unknown",
         source_methods: [],
         buckets: [],
         reset_credits: nil,
         token_activity: nil,
         unknown_fields: unknown_fields
       }) do
    if "api_key_quota" in unknown_fields and "api_key_billing" in unknown_fields,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_authentication_boundary(%{authentication_mode: "chatgpt"} = result) do
    with :ok <-
           require_unknowns(result.unknown_fields, [
             {"quota_buckets", if(result.buckets == [], do: nil, else: :known)},
             {"reset_credits", result.reset_credits},
             {"token_activity", result.token_activity}
           ]) do
      cond do
        result.status == "reported" and "account/rateLimits/read" in result.source_methods -> :ok
        result.status == "partial" and result.source_methods != [] -> :ok
        result.status == "unknown" and result.source_methods == [] -> :ok
        true -> {:error, :invalid_response}
      end
    end
  end

  defp validate_authentication_boundary(_result), do: {:error, :invalid_response}

  defp validate_method_fact_binding(result) do
    has_rate_limit_facts = result.buckets != [] or not is_nil(result.reset_credits)
    has_token_activity = not is_nil(result.token_activity)

    cond do
      has_rate_limit_facts and "account/rateLimits/read" not in result.source_methods ->
        {:error, :invalid_response}

      has_token_activity and "account/usage/read" not in result.source_methods ->
        {:error, :invalid_response}

      true ->
        :ok
    end
  end

  defp validate_scope_unknowns("provider_defined", unknown_fields) do
    if "scope" in unknown_fields and "model" in unknown_fields,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_scope_unknowns(_scope, _unknown_fields), do: :ok

  defp validate_source_methods(methods)
       when is_list(methods) and length(methods) <= length(@source_methods) do
    if Enum.all?(methods, &(&1 in @source_methods)) and methods == Enum.uniq(methods),
      do: {:ok, methods},
      else: {:error, :invalid_response}
  end

  defp validate_source_methods(_methods), do: {:error, :invalid_response}

  defp validate_unknown_fields(fields)
       when is_list(fields) and length(fields) <= @max_unknown_fields do
    if Enum.all?(fields, &valid_unknown_field?/1) and fields == Enum.uniq(fields),
      do: {:ok, fields},
      else: {:error, :invalid_response}
  end

  defp validate_unknown_fields(_fields), do: {:error, :invalid_response}

  defp valid_unknown_field?(field) when is_binary(field) do
    byte_size(field) in 1..@max_identifier_bytes and
      Regex.match?(@unknown_field_pattern, field) and not forbidden_content?(field)
  end

  defp valid_unknown_field?(_field), do: false

  defp require_unknowns(unknown_fields, facts) do
    if Enum.all?(facts, fn
         {field, nil} -> field in unknown_fields
         {_field, _value} -> true
       end),
       do: :ok,
       else: {:error, :invalid_response}
  end

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

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_nullable_datetime(nil), do: {:ok, nil}
  defp normalize_nullable_datetime(value), do: normalize_datetime(value)

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_response}

  defp nullable_bounded_string(nil, _max_bytes), do: :ok
  defp nullable_bounded_string(value, max_bytes), do: bounded_string(value, max_bytes)

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_response}

  defp nullable_positive_integer(nil), do: :ok
  defp nullable_positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp nullable_positive_integer(_value), do: {:error, :invalid_response}

  defp nullable_non_negative_integer(nil), do: :ok
  defp nullable_non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp nullable_non_negative_integer(_value), do: {:error, :invalid_response}

  defp validate_encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_result_bytes -> :ok
      _other -> {:error, :invalid_response}
    end
  end

  defp unique_by?(values, fun) do
    values
    |> Enum.map(fun)
    |> then(&(length(&1) == MapSet.size(MapSet.new(&1))))
  end

  defp forbidden_content?(value) do
    Regex.match?(~r/\bBearer\s+\S+/i, value) or
      Regex.match?(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, value) or
      Regex.match?(~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, value) or
      Regex.match?(~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, value) or
      Regex.match?(
        ~r/\b(provider[-_ ]?(account|workspace)|worker[-_ ]?profile|account[-_ ]?id|workspace[-_ ]?id|profile[-_ ]?(id|ref))[-_: ]*[A-Za-z0-9]/i,
        value
      ) or
      Regex.match?(~r/\b(raw\s+)?provider\s+(error|failure|response)\b/i, value)
  end
end
