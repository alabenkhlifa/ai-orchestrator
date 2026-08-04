defmodule SddOrchestrator.AIRuntime.QuotaPolicy do
  @moduledoc """
  Owner-scoped quota, scarcity, fallback, and paid-continuation boundary.

  The caller supplies one exact connection, model, and effort. This module
  re-authorizes that selection and normalizes only a proceed or pause decision;
  it has no interface for choosing a replacement connection or configuration.
  """

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    PersonalConnections,
    QuotaPolicyAdapter,
    Quotas
  }

  alias SddOrchestrator.AIRuntime.QuotaPolicyAdapter.Default

  @request_keys ~w(connection_id model effort scarcity choices)a
  @choice_keys ~w(
    id kind owner_account_id connection_id model bucket_id cost_boundary
    valid_from expires_at
  )a

  @choice_kinds ~w(scarce_model model_specific_quota provider_paid_continuation)a
  @cost_boundaries ~w(scarce_model quota provider_paid_continuation)a
  @scarcity ~w(standard scarce unknown)a

  @max_choices 32
  @max_identifier_bytes 255
  @max_model_bytes 255
  @max_effort_bytes 64
  @max_clock_skew_seconds 60
  @max_request_bytes 32 * 1_024

  @typedoc "Safe policy-boundary failures."
  @type error ::
          :invalid_request
          | :invalid_response
          | :not_found
          | :unavailable
          | :incompatible
          | :revoking
          | :revoked

  @doc "Evaluates one explicitly selected owner-funded runtime boundary."
  @spec evaluate(Account.t() | Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def evaluate(account_or_id, request, opts \\ []) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, request} <- normalize_request(request, account_id, now),
         {:ok, connection} <-
           PersonalConnections.resolve_for_consumer(
             account_id,
             request.connection_id,
             :working_agent
           ),
         quota_state <- quota_state(account_id, connection, now),
         context <- context(account_id, request, connection, quota_state, now),
         {:ok, result} <- call_adapter(context, opts),
         {:ok, result} <- QuotaPolicyAdapter.validate_result(result, context),
         {:ok, _connection} <-
           PersonalConnections.resolve_for_consumer(
             account_id,
             request.connection_id,
             :working_agent
           ) do
      {:ok, result}
    else
      {:error, reason}
      when reason in [:not_found, :unavailable, :incompatible, :revoking, :revoked] ->
        {:error, reason}

      {:error, :invalid_response} ->
        {:error, :invalid_response}

      _other ->
        {:error, :invalid_request}
    end
  end

  defp context(account_id, request, connection, {quota, quota_error}, now) do
    %{
      account_id: account_id,
      authentication_mode: connection.authentication_mode,
      selection: Map.take(request, [:connection_id, :model, :effort, :scarcity]),
      choices: request.choices,
      quota: quota,
      quota_error: quota_error,
      now: now
    }
  end

  defp quota_state(_account_id, %{authentication_mode: "api_key"}, _now), do: {nil, nil}

  defp quota_state(account_id, connection, now) do
    case Quotas.current_quota(account_id, connection.connection_id, now: now) do
      {:ok, quota} -> {quota, nil}
      {:error, reason} -> {nil, reason}
    end
  end

  defp call_adapter(context, opts) do
    adapter = Keyword.get(opts, :adapter, Default)
    adapter_opts = Keyword.drop(opts, [:adapter, :now])

    try do
      case adapter.evaluate(context, adapter_opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, QuotaPolicyAdapter.normalize_error(reason)}
        _other -> {:error, :invalid_response}
      end
    rescue
      _exception -> {:error, :invalid_response}
    catch
      _kind, _reason -> {:error, :invalid_response}
    end
  end

  defp normalize_request(request, account_id, now) when is_map(request) do
    with {:ok, request} <- exact_map(request, @request_keys),
         {:ok, connection_id} <- cast_id(request.connection_id),
         :ok <- bounded_string(request.model, @max_model_bytes),
         :ok <- bounded_string(request.effort, @max_effort_bytes),
         {:ok, scarcity} <- normalize_member(request.scarcity, @scarcity),
         {:ok, choices} <-
           normalize_choices(request.choices, account_id, connection_id, request.model, now),
         normalized = %{
           connection_id: connection_id,
           model: request.model,
           effort: request.effort,
           scarcity: scarcity,
           choices: choices
         },
         :ok <- validate_encoded_size(normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp normalize_request(_request, _account_id, _now), do: {:error, :invalid_request}

  defp normalize_choices(choices, account_id, connection_id, model, now)
       when is_list(choices) and length(choices) <= @max_choices do
    with {:ok, choices} <-
           map_ok(choices, &normalize_choice(&1, account_id, connection_id, model, now)),
         true <- unique_by?(choices, & &1.id),
         true <- unique_by?(choices, &{&1.kind, &1.bucket_id, &1.cost_boundary}) do
      {:ok, choices}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp normalize_choices(_choices, _account_id, _connection_id, _model, _now),
    do: {:error, :invalid_request}

  defp normalize_choice(choice, account_id, connection_id, model, now) when is_map(choice) do
    with {:ok, choice} <- exact_map(choice, @choice_keys),
         :ok <- bounded_string(choice.id, @max_identifier_bytes),
         {:ok, kind} <- normalize_member(choice.kind, @choice_kinds),
         {:ok, owner_account_id} <- cast_id(choice.owner_account_id),
         true <- owner_account_id == account_id,
         {:ok, choice_connection_id} <- cast_id(choice.connection_id),
         true <- choice_connection_id == connection_id,
         true <- choice.model == model,
         :ok <- bounded_string(choice.model, @max_model_bytes),
         {:ok, bucket_id} <- optional_bounded_string(choice.bucket_id, @max_identifier_bytes),
         {:ok, cost_boundary} <- normalize_member(choice.cost_boundary, @cost_boundaries),
         :ok <- validate_choice_shape(kind, bucket_id, cost_boundary),
         {:ok, valid_from} <- normalize_datetime(choice.valid_from),
         {:ok, expires_at} <- normalize_datetime(choice.expires_at),
         :ok <- validate_choice_window(valid_from, expires_at, now) do
      {:ok,
       %{
         id: choice.id,
         kind: kind,
         owner_account_id: owner_account_id,
         connection_id: choice_connection_id,
         model: choice.model,
         bucket_id: bucket_id,
         cost_boundary: cost_boundary,
         valid_from: valid_from,
         expires_at: expires_at
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp normalize_choice(_choice, _account_id, _connection_id, _model, _now),
    do: {:error, :invalid_request}

  defp validate_choice_shape(:scarce_model, nil, :scarce_model), do: :ok

  defp validate_choice_shape(:model_specific_quota, bucket_id, :quota)
       when is_binary(bucket_id),
       do: :ok

  defp validate_choice_shape(:provider_paid_continuation, bucket_id, :provider_paid_continuation)
       when is_binary(bucket_id),
       do: :ok

  defp validate_choice_shape(_kind, _bucket_id, _cost_boundary),
    do: {:error, :invalid_request}

  defp validate_choice_window(valid_from, expires_at, now) do
    future_limit = DateTime.add(now, @max_clock_skew_seconds, :second)
    lifetime = DateTime.diff(expires_at, valid_from, :second)

    cond do
      DateTime.compare(valid_from, future_limit) == :gt -> {:error, :invalid_request}
      DateTime.compare(valid_from, now) == :gt -> {:error, :invalid_request}
      DateTime.compare(expires_at, now) != :gt -> {:error, :invalid_request}
      lifetime <= 0 -> {:error, :invalid_request}
      true -> :ok
    end
  end

  defp account_id(%Account{id: id}), do: cast_id(id)
  defp account_id(id), do: cast_id(id)

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_id(_id), do: {:error, :invalid_request}

  defp normalized_now(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_request}

  defp optional_bounded_string(nil, _max_bytes), do: {:ok, nil}

  defp optional_bounded_string(value, max_bytes) do
    case bounded_string(value, max_bytes) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_request}

  defp forbidden_content?(value) do
    downcased = String.downcase(value)

    Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, value) or
      Regex.match?(~r/\bsk-[a-z0-9_-]{8,}\b/i, value) or
      String.contains?(downcased, "bearer ") or
      String.contains?(downcased, "api_key=") or
      String.contains?(downcased, "access_token=")
  end

  defp validate_encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_request_bytes -> :ok
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_member(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_request}
  end

  defp normalize_member(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_request}
      member -> {:ok, member}
    end
  end

  defp normalize_member(_value, _allowed), do: {:error, :invalid_request}

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :invalid_request}
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

  defp unique_by?(values, fun) do
    unique_count = values |> Enum.map(fun) |> Enum.uniq() |> length()
    length(values) == unique_count
  end
end
