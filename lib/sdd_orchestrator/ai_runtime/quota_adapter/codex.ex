defmodule SddOrchestrator.AIRuntime.QuotaAdapter.Codex do
  @moduledoc """
  Worker-local Codex quota adapter over documented App Server account methods.

  ChatGPT quota uses exact `account/rateLimits/read` and `account/usage/read`
  responses with `nil` parameters. API-key quota and billing remain unknown.
  Sparse rate-limit notifications are validated only as refetch signals; this
  adapter never merges them into a complete snapshot or treats omitted values
  as cleared.
  """

  @behaviour SddOrchestrator.AIRuntime.QuotaAdapter

  alias SddOrchestrator.AIRuntime.{CodexAppServer, QuotaAdapter}

  @rate_limit_response_keys ~w(rateLimits rateLimitsByLimitId rateLimitResetCredits)
  @rate_limit_snapshot_keys ~w(
    credits individualLimit limitId limitName planType primary rateLimitReachedType secondary
    spendControlReached
  )
  @window_keys ~w(usedPercent resetsAt windowDurationMins)
  @credits_keys ~w(hasCredits unlimited balance)
  @spend_control_keys ~w(limit remainingPercent resetsAt used)
  @reset_summary_keys ~w(availableCount credits)
  @reset_credit_keys ~w(description expiresAt grantedAt id resetType status title)
  @usage_response_keys ~w(summary dailyUsageBuckets)
  @usage_summary_keys ~w(
    currentStreakDays lifetimeTokens longestRunningTurnSec longestStreakDays peakDailyTokens
  )
  @daily_usage_keys ~w(startDate tokens)

  @plan_types ~w(
    free go plus pro prolite team self_serve_business_usage_based business ent26
    enterprise_cbp_usage_based enterprise edu unknown
  )
  @limit_reached_types ~w(
    rate_limit_reached workspace_owner_credits_depleted
    workspace_member_credits_depleted workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )
  @reset_types ~w(codexRateLimits unknown)
  @reset_statuses ~w(available redeeming redeemed unknown)

  @max_provider_buckets 63
  @max_reset_credit_details 100
  @max_daily_usage_buckets 400
  @max_identifier_bytes 255
  @max_text_bytes 1_000
  @max_value_bytes 100

  @impl true
  def fetch(_account, %{provider: "openai_codex", authentication_mode: "api_key"}, opts) do
    with {:ok, server} <- server(opts),
         {:ok, source_version} <- source_version(server, opts),
         {:ok, retrieved_at} <- retrieved_at(opts) do
      validate_result(
        %{
          status: "unknown",
          provider: "openai_codex",
          authentication_mode: "api_key",
          source: "official_client",
          source_methods: [],
          source_version: source_version,
          retrieved_at: retrieved_at,
          buckets: [],
          reset_credits: nil,
          token_activity: nil,
          unknown_fields: [
            "api_key_quota",
            "api_key_billing",
            "reset_credits",
            "paid_continuation",
            "token_activity"
          ]
        },
        "api_key"
      )
    end
  end

  def fetch(
        _account,
        %{
          provider: "openai_codex",
          authentication_mode: "chatgpt",
          worker_profile_ref: worker_profile_ref
        },
        opts
      )
      when is_binary(worker_profile_ref) do
    with {:ok, server} <- server(opts),
         {:ok, source_version} <- source_version(server, opts),
         {:ok, retrieved_at} <- retrieved_at(opts),
         {:ok, rate_limits} <- read_rate_limits(server, opts),
         {:ok, token_activity} <- read_token_activity(server, opts),
         {:ok, result} <-
           build_chatgpt_result(rate_limits, token_activity, source_version, retrieved_at),
         false <- contains_value?(result, worker_profile_ref) do
      {:ok, result}
    else
      true -> {:error, :invalid_response}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch(_account, _connection, _opts), do: {:error, :invalid_request}

  @doc "Validates a sparse rolling update and requires a complete refetch."
  @spec handle_notification(String.t(), term()) ::
          {:ok, :refetch} | {:error, :invalid_response}
  def handle_notification("account/rateLimits/updated", params) when is_map(params) do
    with true <- exact_keys?(params, ["rateLimits"], ["rateLimits"]),
         {:ok, _bucket} <- normalize_rate_limit_snapshot(params["rateLimits"], "general", nil) do
      {:ok, :refetch}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def handle_notification(_method, _params), do: {:error, :invalid_response}

  @doc "Alias used by notification consumers that only need the action."
  def notification_action(method, params), do: handle_notification(method, params)

  defp read_rate_limits(server, opts) do
    app_server = Keyword.get(opts, :app_server_module, CodexAppServer)

    case app_server.request(server, "account/rateLimits/read", nil, request_opts(opts)) do
      {:ok, result} -> validate_rate_limit_response(result)
      {:error, :unsupported_method} -> {:ok, :unknown}
      {:error, reason} -> {:error, normalize_app_server_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  defp read_token_activity(server, opts) do
    app_server = Keyword.get(opts, :app_server_module, CodexAppServer)

    case app_server.request(server, "account/usage/read", nil, request_opts(opts)) do
      {:ok, result} -> validate_usage_response(result)
      {:error, :unsupported_method} -> {:ok, :unknown}
      {:error, reason} -> {:error, normalize_app_server_error(reason)}
      _other -> {:error, :invalid_response}
    end
  end

  defp validate_rate_limit_response(result) when is_map(result) do
    with true <-
           exact_keys?(result, ["rateLimits"], @rate_limit_response_keys),
         {:ok, general} <- normalize_rate_limit_snapshot(result["rateLimits"], "general", nil),
         {:ok, provider_buckets} <- normalize_provider_buckets(result["rateLimitsByLimitId"]),
         {:ok, reset_credits} <- normalize_reset_credits(result["rateLimitResetCredits"]) do
      buckets = merge_rate_limit_buckets(general, provider_buckets)

      {:ok,
       %{
         buckets: buckets,
         reset_credits: reset_credits,
         unknown_fields:
           []
           |> add_unknown("reset_credits", is_nil(reset_credits))
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_rate_limit_response(_result), do: {:error, :invalid_response}

  defp normalize_provider_buckets(nil), do: {:ok, []}

  defp normalize_provider_buckets(buckets)
       when is_map(buckets) and map_size(buckets) <= @max_provider_buckets do
    buckets
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {limit_id, snapshot}, {:ok, normalized} ->
      with :ok <- bounded_string(limit_id, @max_identifier_bytes),
           {:ok, bucket} <-
             normalize_rate_limit_snapshot(snapshot, "provider_defined", limit_id) do
        {:cont, {:ok, [bucket | normalized]}}
      else
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_provider_buckets(_buckets), do: {:error, :invalid_response}

  defp merge_rate_limit_buckets(general, []), do: [general]

  defp merge_rate_limit_buckets(general, provider_buckets) do
    if Enum.any?(provider_buckets, &(&1.id == general.id)) do
      provider_buckets
    else
      [general | provider_buckets]
    end
  end

  defp normalize_rate_limit_snapshot(snapshot, scope, provider_limit_id)
       when is_map(snapshot) do
    with true <- exact_keys?(snapshot, [], @rate_limit_snapshot_keys),
         :ok <- validate_optional_plan_type(snapshot["planType"]),
         {:ok, id} <- normalized_bucket_id(snapshot["limitId"], provider_limit_id, scope),
         :ok <- nullable_bounded_string(snapshot["limitName"], @max_text_bytes),
         {:ok, primary_window} <- normalize_window(snapshot["primary"]),
         {:ok, secondary_window} <- normalize_window(snapshot["secondary"]),
         {:ok, credits} <- normalize_credits(snapshot["credits"]),
         {:ok, spend_control} <- normalize_spend_control(snapshot["individualLimit"]),
         :ok <- nullable_boolean(snapshot["spendControlReached"]),
         :ok <- validate_limit_reached_type(snapshot["rateLimitReachedType"]) do
      unknown_fields =
        if(scope == "provider_defined", do: ["scope", "model"], else: [])
        |> add_unknown("display_name", is_nil(snapshot["limitName"]))
        |> add_unknown("primary_window", is_nil(primary_window))
        |> add_unknown("secondary_window", is_nil(secondary_window))
        |> add_unknown("credits", is_nil(credits))
        |> add_unknown("paid_continuation", true)
        |> add_unknown("spend_control", is_nil(spend_control))
        |> add_unknown("spend_control_reached", is_nil(snapshot["spendControlReached"]))
        |> add_unknown("limit_reached_reason", is_nil(snapshot["rateLimitReachedType"]))

      {:ok,
       %{
         id: id,
         scope: scope,
         model: if(scope == "model_specific", do: provider_limit_id, else: nil),
         display_name: snapshot["limitName"],
         primary_window: primary_window,
         secondary_window: secondary_window,
         credits: credits,
         paid_continuation: "unknown",
         spend_control: spend_control,
         spend_control_reached: snapshot["spendControlReached"],
         limit_reached_reason: snapshot["rateLimitReachedType"],
         unknown_fields: unknown_fields
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_rate_limit_snapshot(_snapshot, _scope, _provider_limit_id),
    do: {:error, :invalid_response}

  defp normalized_bucket_id(limit_id, nil, "general") do
    case limit_id do
      nil -> {:ok, "general"}
      value -> with :ok <- bounded_string(value, @max_identifier_bytes), do: {:ok, value}
    end
  end

  defp normalized_bucket_id(nil, provider_limit_id, scope)
       when scope in ["model_specific", "provider_defined"],
       do: {:ok, provider_limit_id}

  defp normalized_bucket_id(limit_id, provider_limit_id, scope)
       when scope in ["model_specific", "provider_defined"] do
    with :ok <- bounded_string(limit_id, @max_identifier_bytes),
         true <- limit_id == provider_limit_id do
      {:ok, limit_id}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_window(nil), do: {:ok, nil}

  defp normalize_window(window) when is_map(window) do
    with true <- exact_keys?(window, ["usedPercent"], @window_keys),
         true <- is_integer(window["usedPercent"]) and window["usedPercent"] in 0..100,
         {:ok, resets_at} <- unix_datetime(window["resetsAt"]),
         :ok <- nullable_positive_integer(window["windowDurationMins"]) do
      unknown_fields =
        []
        |> add_unknown("resets_at", is_nil(resets_at))
        |> add_unknown("duration_minutes", is_nil(window["windowDurationMins"]))

      {:ok,
       %{
         used_percent: window["usedPercent"],
         resets_at: resets_at,
         duration_minutes: window["windowDurationMins"],
         unknown_fields: unknown_fields
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_window(_window), do: {:error, :invalid_response}

  defp normalize_credits(nil), do: {:ok, nil}

  defp normalize_credits(credits) when is_map(credits) do
    with true <- exact_keys?(credits, ["hasCredits", "unlimited"], @credits_keys),
         true <- is_boolean(credits["hasCredits"]),
         true <- is_boolean(credits["unlimited"]),
         :ok <- nullable_bounded_string(credits["balance"], @max_value_bytes) do
      {:ok,
       %{
         has_credits: credits["hasCredits"],
         unlimited: credits["unlimited"],
         balance: credits["balance"],
         unknown_fields: if(is_nil(credits["balance"]), do: ["balance"], else: [])
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_credits(_credits), do: {:error, :invalid_response}

  defp normalize_spend_control(nil), do: {:ok, nil}

  defp normalize_spend_control(spend_control) when is_map(spend_control) do
    with true <- exact_keys?(spend_control, @spend_control_keys, @spend_control_keys),
         :ok <- bounded_string(spend_control["limit"], @max_value_bytes),
         :ok <- bounded_string(spend_control["used"], @max_value_bytes),
         true <-
           is_integer(spend_control["remainingPercent"]) and
             spend_control["remainingPercent"] in 0..100,
         {:ok, resets_at} <- unix_datetime_required(spend_control["resetsAt"]) do
      {:ok,
       %{
         limit: spend_control["limit"],
         used: spend_control["used"],
         remaining_percent: spend_control["remainingPercent"],
         resets_at: resets_at,
         unknown_fields: []
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_spend_control(_spend_control), do: {:error, :invalid_response}

  defp normalize_reset_credits(nil), do: {:ok, nil}

  defp normalize_reset_credits(summary) when is_map(summary) do
    with true <- exact_keys?(summary, ["availableCount"], @reset_summary_keys),
         true <- is_integer(summary["availableCount"]) and summary["availableCount"] >= 0,
         :ok <- validate_reset_credit_details(summary["credits"]) do
      unknown_fields = if(is_nil(summary["credits"]), do: ["credit_details"], else: [])
      {:ok, %{available_count: summary["availableCount"], unknown_fields: unknown_fields}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_reset_credits(_summary), do: {:error, :invalid_response}

  defp validate_reset_credit_details(nil), do: :ok

  defp validate_reset_credit_details(details)
       when is_list(details) and length(details) <= @max_reset_credit_details do
    if Enum.all?(details, &valid_reset_credit_detail?/1),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_reset_credit_details(_details), do: {:error, :invalid_response}

  defp valid_reset_credit_detail?(detail) when is_map(detail) do
    with true <-
           exact_keys?(
             detail,
             ["grantedAt", "id", "resetType", "status"],
             @reset_credit_keys
           ),
         :ok <- bounded_string(detail["id"], @max_identifier_bytes),
         true <- is_integer(detail["grantedAt"]) and detail["grantedAt"] >= 0,
         :ok <- nullable_non_negative_integer(detail["expiresAt"]),
         true <- detail["resetType"] in @reset_types,
         true <- detail["status"] in @reset_statuses,
         :ok <- nullable_bounded_text(detail["title"], @max_text_bytes),
         :ok <- nullable_bounded_text(detail["description"], @max_text_bytes) do
      true
    else
      _ -> false
    end
  end

  defp valid_reset_credit_detail?(_detail), do: false

  defp validate_usage_response(result) when is_map(result) do
    with true <- exact_keys?(result, ["summary"], @usage_response_keys),
         :ok <- validate_daily_usage(result["dailyUsageBuckets"]),
         {:ok, summary} <- normalize_usage_summary(result["summary"]) do
      {:ok, summary}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_usage_response(_result), do: {:error, :invalid_response}

  defp validate_daily_usage(nil), do: :ok

  defp validate_daily_usage(buckets)
       when is_list(buckets) and length(buckets) <= @max_daily_usage_buckets do
    if Enum.all?(buckets, &valid_daily_usage_bucket?/1),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_daily_usage(_buckets), do: {:error, :invalid_response}

  defp valid_daily_usage_bucket?(bucket) when is_map(bucket) do
    with true <- exact_keys?(bucket, @daily_usage_keys, @daily_usage_keys),
         true <- is_binary(bucket["startDate"]),
         {:ok, _date} <- Date.from_iso8601(bucket["startDate"]),
         true <- is_integer(bucket["tokens"]) and bucket["tokens"] >= 0 do
      true
    else
      _ -> false
    end
  end

  defp valid_daily_usage_bucket?(_bucket), do: false

  defp normalize_usage_summary(summary) when is_map(summary) do
    with true <- exact_keys?(summary, [], @usage_summary_keys),
         :ok <- nullable_non_negative_integer(summary["lifetimeTokens"]),
         :ok <- nullable_non_negative_integer(summary["peakDailyTokens"]),
         :ok <- nullable_non_negative_integer(summary["currentStreakDays"]),
         :ok <- nullable_non_negative_integer(summary["longestStreakDays"]),
         :ok <- nullable_non_negative_integer(summary["longestRunningTurnSec"]) do
      fields = [
        {"lifetime_tokens", summary["lifetimeTokens"]},
        {"peak_daily_tokens", summary["peakDailyTokens"]},
        {"current_streak_days", summary["currentStreakDays"]},
        {"longest_streak_days", summary["longestStreakDays"]},
        {"longest_running_turn_seconds", summary["longestRunningTurnSec"]}
      ]

      {:ok,
       %{
         lifetime_tokens: summary["lifetimeTokens"],
         peak_daily_tokens: summary["peakDailyTokens"],
         current_streak_days: summary["currentStreakDays"],
         longest_streak_days: summary["longestStreakDays"],
         longest_running_turn_seconds: summary["longestRunningTurnSec"],
         unknown_fields: for({name, nil} <- fields, do: name)
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_usage_summary(_summary), do: {:error, :invalid_response}

  defp build_chatgpt_result(rate_limits, token_activity, source_version, retrieved_at) do
    methods =
      []
      |> maybe_add_method(rate_limits != :unknown, "account/rateLimits/read")
      |> maybe_add_method(token_activity != :unknown, "account/usage/read")

    buckets = if rate_limits == :unknown, do: [], else: rate_limits.buckets
    reset_credits = if rate_limits == :unknown, do: nil, else: rate_limits.reset_credits
    token_activity = if token_activity == :unknown, do: nil, else: token_activity

    unknown_fields =
      ["provider_billing"]
      |> append_unknowns(
        if(rate_limits == :unknown,
          do: ["quota_buckets", "reset_credits", "paid_continuation"],
          else: rate_limits.unknown_fields
        )
      )
      |> append_unknowns(if(is_nil(token_activity), do: ["token_activity"], else: []))

    status =
      cond do
        "account/rateLimits/read" in methods -> "reported"
        methods != [] -> "partial"
        true -> "unknown"
      end

    validate_result(
      %{
        status: status,
        provider: "openai_codex",
        authentication_mode: "chatgpt",
        source: "official_client",
        source_methods: methods,
        source_version: source_version,
        retrieved_at: retrieved_at,
        buckets: buckets,
        reset_credits: reset_credits,
        token_activity: token_activity,
        unknown_fields: unknown_fields
      },
      "chatgpt"
    )
  end

  defp validate_result(result, authentication_mode) do
    QuotaAdapter.validate_result(result, "openai_codex", authentication_mode)
  end

  defp source_version(server, opts) do
    app_server = Keyword.get(opts, :app_server_module, CodexAppServer)

    case app_server.compatibility(server) do
      {:ok, %{codex_version: version, schema_digest: digest} = pair}
      when map_size(pair) == 2 and is_binary(version) and is_binary(digest) ->
        value = version <> "|schema:" <> digest

        with :ok <- bounded_string(version, 100),
             true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
             :ok <-
               QuotaAdapter.validate_provenance(
                 "openai_codex",
                 "official_client",
                 [],
                 value
               ) do
          {:ok, value}
        else
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, normalize_app_server_error(reason)}

      _other ->
        {:error, :invalid_response}
    end
  end

  defp retrieved_at(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp server(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} when is_pid(server) or is_atom(server) or is_tuple(server) -> {:ok, server}
      _other -> {:error, :invalid_request}
    end
  end

  defp request_opts(opts), do: Keyword.take(opts, [:timeout_ms])

  defp normalize_app_server_error(reason)
       when reason in [:timeout, :process_unavailable, :process_crashed, :not_initialized],
       do: :worker_unavailable

  defp normalize_app_server_error(_reason), do: :invalid_response

  defp validate_optional_plan_type(nil), do: :ok
  defp validate_optional_plan_type(plan_type) when plan_type in @plan_types, do: :ok
  defp validate_optional_plan_type(_plan_type), do: {:error, :invalid_response}

  defp validate_limit_reached_type(nil), do: :ok
  defp validate_limit_reached_type(value) when value in @limit_reached_types, do: :ok
  defp validate_limit_reached_type(_value), do: {:error, :invalid_response}

  defp unix_datetime(nil), do: {:ok, nil}
  defp unix_datetime(value), do: unix_datetime_required(value)

  defp unix_datetime_required(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value, :second) do
      {:ok, datetime} -> {:ok, DateTime.truncate(datetime, :second)}
      _ -> {:error, :invalid_response}
    end
  end

  defp unix_datetime_required(_value), do: {:error, :invalid_response}

  defp exact_keys?(map, required, allowed) when is_map(map) do
    keys = Map.keys(map)

    Enum.all?(keys, &is_binary/1) and Enum.all?(required, &Map.has_key?(map, &1)) and
      Enum.all?(keys, &(&1 in allowed))
  end

  defp nullable_boolean(nil), do: :ok
  defp nullable_boolean(value) when is_boolean(value), do: :ok
  defp nullable_boolean(_value), do: {:error, :invalid_response}

  defp nullable_positive_integer(nil), do: :ok
  defp nullable_positive_integer(value) when is_integer(value) and value > 0, do: :ok
  defp nullable_positive_integer(_value), do: {:error, :invalid_response}

  defp nullable_non_negative_integer(nil), do: :ok
  defp nullable_non_negative_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp nullable_non_negative_integer(_value), do: {:error, :invalid_response}

  defp nullable_bounded_string(nil, _max_bytes), do: :ok
  defp nullable_bounded_string(value, max_bytes), do: bounded_string(value, max_bytes)

  defp nullable_bounded_text(nil, _max_bytes), do: :ok
  defp nullable_bounded_text(value, max_bytes), do: bounded_text(value, max_bytes)

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_response}

  defp bounded_text(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes and not forbidden_content?(value),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp bounded_text(_value, _max_bytes), do: {:error, :invalid_response}

  defp add_unknown(fields, field, true), do: fields ++ [field]
  defp add_unknown(fields, _field, false), do: fields

  defp append_unknowns(fields, additions), do: Enum.uniq(fields ++ additions)

  defp maybe_add_method(methods, true, method), do: methods ++ [method]
  defp maybe_add_method(methods, false, _method), do: methods

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

  defp contains_value?(value, forbidden) when is_binary(value),
    do: String.contains?(value, forbidden)

  defp contains_value?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, forbidden))

  defp contains_value?(value, forbidden) when is_map(value),
    do: Enum.any?(Map.values(value), &contains_value?(&1, forbidden))

  defp contains_value?(_value, _forbidden), do: false
end
