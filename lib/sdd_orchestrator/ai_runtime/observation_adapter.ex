defmodule SddOrchestrator.AIRuntime.ObservationAdapter do
  @moduledoc """
  Provider-neutral boundary for one minimized ordered runtime observation.

  An observation carries the facts an operator needs while an agent is working:
  elapsed time, token counters when available, an estimated cost and the basis
  it was calculated from when calculable, the quota buckets that apply, and the
  current status. Nothing else may cross this boundary. Prompt or completion
  content, provider account identity, credentials, raw provider errors, and the
  worker-local profile reference have no field to travel in.

  Every value carries one explicit label from the same constrained vocabulary:

    * `provider_fact` — reported by the provider through its official client.
    * `worker_observed` — counted by the personal worker running the agent.
    * `local_estimate` — calculated here from a versioned price basis.
    * `unknown` — not available.

  The vocabulary is structural, not cosmetic. A value a label can never
  honestly describe is refused: elapsed time is never a provider fact, and an
  estimated cost is never a provider fact either, because an estimate must
  never be presented as a provider invoice or an exact account charge. A
  missing value stays `unknown` and is named in `unknown_fields`; it is never
  normalized into zero, unlimited, safe, or exhausted.

  Provenance (`provider`, `source`, `source_version`) proves the facts came
  from a compatible official client. It is validated here and deliberately not
  persisted: the session already owns the provider, and the observation entity
  is limited to the values above plus their labels.
  """

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.AIRuntime.PersonalAIConnection

  @observation_keys ~w(
    event_key sequence observed_at elapsed tokens estimated_cost quota status unknown_fields
  )a
  @provenance_keys ~w(provider source source_version)a
  @result_keys @observation_keys ++ @provenance_keys

  @elapsed_keys ~w(seconds source)a
  @token_keys ~w(input output total source)a
  @cost_keys ~w(amount currency basis source)a
  @basis_keys ~w(
    price_version price_source model input_tokens output_tokens
    input_unit_price output_unit_price
  )a
  @quota_keys ~w(buckets source)a
  @bucket_keys ~w(id scope model)a
  @status_keys ~w(state pause_reason source)a

  @source_labels ~w(provider_fact worker_observed local_estimate unknown)
  @elapsed_sources ~w(worker_observed unknown)
  @token_sources ~w(provider_fact worker_observed unknown)
  @cost_sources ~w(local_estimate unknown)
  @quota_sources ~w(provider_fact unknown)
  @status_sources ~w(provider_fact worker_observed unknown)

  @states ~w(available constrained paused unknown)
  @pause_reasons ~w(quota_exhausted spending_ceiling_reached)
  @scopes ~w(general model_specific provider_defined)

  @max_buckets 32
  @max_unknown_fields 32
  @max_sequence 4_294_967_295
  @max_elapsed_seconds 2_592_000
  @max_tokens 10_000_000
  @max_identifier_bytes 255
  @max_label_bytes 100
  @max_source_version_bytes 200
  @max_result_bytes 16 * 1_024
  @max_amount Decimal.new(1_000_000)
  @max_unit_price Decimal.new(100_000)
  @amount_format ~r/\A\d+(\.\d{1,4})?\z/
  @unit_price_format ~r/\A\d+(\.\d{1,8})?\z/
  @codex_source_version_pattern ~r/\Acodex-cli [0-9A-Za-z._+-]+\|schema:[0-9a-f]{64}\z/
  @unknown_field_pattern ~r/\A[a-z][a-z0-9_.-]*\z/

  @typedoc "Failures safe to expose outside an adapter."
  @type error ::
          :worker_unavailable
          | :timeout
          | :incompatible
          | :invalid_request
          | :invalid_response

  @typedoc "One applicable quota bucket reference, never the quota values themselves."
  @type bucket :: %{id: String.t(), scope: String.t(), model: String.t() | nil}

  @typedoc "The versioned basis one local cost estimate was calculated from."
  @type basis :: %{
          price_version: String.t(),
          price_source: String.t(),
          model: String.t(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          input_unit_price: Decimal.t(),
          output_unit_price: Decimal.t()
        }

  @type observation :: %{
          event_key: String.t(),
          sequence: pos_integer(),
          observed_at: DateTime.t(),
          elapsed: %{seconds: non_neg_integer() | nil, source: String.t()},
          tokens: %{
            input: non_neg_integer() | nil,
            output: non_neg_integer() | nil,
            total: non_neg_integer() | nil,
            source: String.t()
          },
          estimated_cost: %{
            amount: Decimal.t() | nil,
            currency: String.t() | nil,
            basis: basis() | nil,
            source: String.t()
          },
          quota: %{buckets: [bucket()], source: String.t()},
          status: %{state: String.t(), pause_reason: String.t() | nil, source: String.t()},
          unknown_fields: [String.t()]
        }

  @type result :: %{
          optional(:provider) => String.t(),
          optional(:source) => String.t(),
          optional(:source_version) => String.t()
        }

  @callback observe(Account.t(), PersonalAIConnection.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Validates one exact observation result against the session's pinned provider.

  Returns the normalized observation together with its validated provenance.
  """
  @spec validate_result(map(), String.t()) :: {:ok, map()} | {:error, :invalid_response}
  def validate_result(result, expected_provider)
      when is_map(result) and is_binary(expected_provider) do
    with {:ok, normalized} <- exact_map(result, @result_keys),
         true <- normalized.provider == expected_provider,
         :ok <-
           validate_provenance(
             normalized.provider,
             normalized.source,
             normalized.source_version
           ),
         {:ok, observation} <- validate_observation(Map.take(normalized, @observation_keys)) do
      {:ok, Map.merge(observation, Map.take(normalized, @provenance_keys))}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_result(_result, _expected_provider), do: {:error, :invalid_response}

  @doc """
  Validates the storable part of one observation.

  This is the single definition of what an observation may contain. The adapter
  contract and the schema both run it, so a row can never hold a shape the
  boundary would refuse.
  """
  @spec validate_observation(map()) :: {:ok, observation()} | {:error, :invalid_response}
  def validate_observation(observation) when is_map(observation) do
    with {:ok, normalized} <- exact_map(observation, @observation_keys),
         :ok <- bounded_string(normalized.event_key, @max_identifier_bytes),
         true <- is_integer(normalized.sequence) and normalized.sequence in 1..@max_sequence,
         {:ok, observed_at} <- normalize_datetime(normalized.observed_at),
         {:ok, elapsed} <- validate_elapsed(normalized.elapsed),
         {:ok, tokens} <- validate_tokens(normalized.tokens),
         {:ok, cost} <- validate_estimated_cost(normalized.estimated_cost, tokens),
         {:ok, quota} <- validate_quota(normalized.quota),
         {:ok, status} <- validate_status(normalized.status),
         {:ok, unknown_fields} <- validate_unknown_fields(normalized.unknown_fields),
         :ok <- require_unknowns(unknown_fields, elapsed, tokens, cost, quota, status),
         safe = %{
           event_key: normalized.event_key,
           sequence: normalized.sequence,
           observed_at: observed_at,
           elapsed: elapsed,
           tokens: tokens,
           estimated_cost: cost,
           quota: quota,
           status: status,
           unknown_fields: unknown_fields
         },
         :ok <- validate_encoded_size(safe) do
      {:ok, safe}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_observation(_observation), do: {:error, :invalid_response}

  @doc "Validates compatible official-client provenance without accepting plan identity."
  @spec validate_provenance(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_response}
  def validate_provenance("openai_codex", "official_client", source_version)
      when is_binary(source_version) do
    if byte_size(source_version) <= @max_source_version_bytes and
         Regex.match?(@codex_source_version_pattern, source_version),
       do: :ok,
       else: {:error, :invalid_response}
  end

  def validate_provenance(_provider, _source, _source_version), do: {:error, :invalid_response}

  @doc "Collapses arbitrary provider and transport failures to a safe vocabulary."
  @spec normalize_error(term()) :: error()
  def normalize_error(reason)
      when reason in [:worker_unavailable, :timeout, :incompatible, :invalid_request],
      do: reason

  def normalize_error(:worker_disconnected), do: :worker_unavailable
  def normalize_error(:unsupported_capability), do: :incompatible
  def normalize_error(_reason), do: :invalid_response

  @doc "The complete source-label vocabulary every stored value is drawn from."
  @spec source_labels() :: [String.t()]
  def source_labels, do: @source_labels

  @doc "The complete agent status vocabulary."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "The resumable pause reasons a paused agent may report."
  @spec pause_reasons() :: [String.t()]
  def pause_reasons, do: @pause_reasons

  @doc false
  def max_buckets, do: @max_buckets

  @doc false
  def max_sequence, do: @max_sequence

  defp validate_elapsed(elapsed) when is_map(elapsed) do
    with {:ok, normalized} <- exact_map(elapsed, @elapsed_keys),
         {:ok, source} <- member(normalized.source, @elapsed_sources),
         {:ok, seconds} <- optional_value(source, normalized.seconds, &elapsed_seconds/1) do
      {:ok, %{seconds: seconds, source: source}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_elapsed(_elapsed), do: {:error, :invalid_response}

  defp elapsed_seconds(seconds) when is_integer(seconds) and seconds in 0..@max_elapsed_seconds,
    do: {:ok, seconds}

  defp elapsed_seconds(_seconds), do: {:error, :invalid_response}

  defp validate_tokens(tokens) when is_map(tokens) do
    with {:ok, normalized} <- exact_map(tokens, @token_keys),
         {:ok, source} <- member(normalized.source, @token_sources),
         {:ok, total} <- optional_value(source, normalized.total, &token_count/1),
         {:ok, input} <- nullable_token_count(source, normalized.input),
         {:ok, output} <- nullable_token_count(source, normalized.output),
         :ok <- validate_token_sum(total, input, output) do
      {:ok, %{input: input, output: output, total: total, source: source}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_tokens(_tokens), do: {:error, :invalid_response}

  defp token_count(count) when is_integer(count) and count in 0..@max_tokens, do: {:ok, count}
  defp token_count(_count), do: {:error, :invalid_response}

  defp nullable_token_count("unknown", nil), do: {:ok, nil}
  defp nullable_token_count("unknown", _count), do: {:error, :invalid_response}
  defp nullable_token_count(_source, nil), do: {:ok, nil}
  defp nullable_token_count(_source, count), do: token_count(count)

  defp validate_token_sum(nil, _input, _output), do: :ok

  defp validate_token_sum(total, input, output) do
    if total >= (input || 0) + (output || 0), do: :ok, else: {:error, :invalid_response}
  end

  defp validate_estimated_cost(cost, tokens) when is_map(cost) do
    with {:ok, normalized} <- exact_map(cost, @cost_keys),
         {:ok, source} <- member(normalized.source, @cost_sources) do
      validate_cost_values(normalized, source, tokens)
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_estimated_cost(_cost, _tokens), do: {:error, :invalid_response}

  defp validate_cost_values(%{amount: nil, currency: nil, basis: nil}, "unknown", _tokens),
    do: {:ok, %{amount: nil, currency: nil, basis: nil, source: "unknown"}}

  defp validate_cost_values(_normalized, "unknown", _tokens), do: {:error, :invalid_response}

  defp validate_cost_values(normalized, "local_estimate", tokens) do
    with {:ok, amount} <- normalize_decimal(normalized.amount, @amount_format, @max_amount),
         {:ok, currency} <- normalize_currency(normalized.currency),
         {:ok, basis} <- validate_basis(normalized.basis),
         :ok <- validate_basis_binding(basis, tokens) do
      {:ok, %{amount: amount, currency: currency, basis: basis, source: "local_estimate"}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_basis(basis) when is_map(basis) do
    with {:ok, normalized} <- exact_map(basis, @basis_keys),
         :ok <- bounded_string(normalized.price_version, @max_label_bytes),
         :ok <- bounded_string(normalized.price_source, @max_label_bytes),
         :ok <- bounded_string(normalized.model, @max_identifier_bytes),
         {:ok, input_tokens} <- token_count(normalized.input_tokens),
         {:ok, output_tokens} <- token_count(normalized.output_tokens),
         {:ok, input_unit_price} <-
           normalize_decimal(normalized.input_unit_price, @unit_price_format, @max_unit_price),
         {:ok, output_unit_price} <-
           normalize_decimal(normalized.output_unit_price, @unit_price_format, @max_unit_price) do
      {:ok,
       %{
         price_version: normalized.price_version,
         price_source: normalized.price_source,
         model: normalized.model,
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         input_unit_price: input_unit_price,
         output_unit_price: output_unit_price
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_basis(_basis), do: {:error, :invalid_response}

  # An estimate is only meaningful against the counters it was calculated from.
  defp validate_basis_binding(basis, %{input: input, output: output})
       when is_integer(input) and is_integer(output) do
    if basis.input_tokens == input and basis.output_tokens == output,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_basis_binding(_basis, _tokens), do: {:error, :invalid_response}

  defp validate_quota(quota) when is_map(quota) do
    with {:ok, normalized} <- exact_map(quota, @quota_keys),
         {:ok, source} <- member(normalized.source, @quota_sources),
         {:ok, buckets} <- validate_buckets(normalized.buckets),
         :ok <- validate_quota_binding(source, buckets) do
      {:ok, %{buckets: buckets, source: source}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_quota(_quota), do: {:error, :invalid_response}

  defp validate_quota_binding("unknown", []), do: :ok
  defp validate_quota_binding("provider_fact", [_first | _rest]), do: :ok
  defp validate_quota_binding(_source, _buckets), do: {:error, :invalid_response}

  defp validate_buckets(buckets) when is_list(buckets) and length(buckets) <= @max_buckets do
    with {:ok, normalized} <- map_ok(buckets, &validate_bucket/1),
         true <- unique_by?(normalized, &{&1.scope, &1.id}) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_buckets(_buckets), do: {:error, :invalid_response}

  defp validate_bucket(bucket) when is_map(bucket) do
    with {:ok, normalized} <- exact_map(bucket, @bucket_keys),
         :ok <- bounded_string(normalized.id, @max_identifier_bytes),
         {:ok, scope} <- member(normalized.scope, @scopes),
         :ok <- validate_model_scope(scope, normalized.model) do
      {:ok, %{id: normalized.id, scope: scope, model: normalized.model}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_bucket(_bucket), do: {:error, :invalid_response}

  defp validate_model_scope("model_specific", model),
    do: bounded_string(model, @max_identifier_bytes)

  defp validate_model_scope(_scope, nil), do: :ok
  defp validate_model_scope(_scope, _model), do: {:error, :invalid_response}

  defp validate_status(status) when is_map(status) do
    with {:ok, normalized} <- exact_map(status, @status_keys),
         {:ok, state} <- member(normalized.state, @states),
         {:ok, source} <- member(normalized.source, @status_sources),
         :ok <- validate_status_binding(state, source),
         {:ok, pause_reason} <- validate_pause_reason(state, normalized.pause_reason) do
      {:ok, %{state: state, pause_reason: pause_reason, source: source}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_status(_status), do: {:error, :invalid_response}

  defp validate_status_binding("unknown", "unknown"), do: :ok
  defp validate_status_binding("unknown", _source), do: {:error, :invalid_response}
  defp validate_status_binding(_state, "unknown"), do: {:error, :invalid_response}
  defp validate_status_binding(_state, _source), do: :ok

  # A pause is resumable evidence, never a terminal failure, so it must name
  # the resumable reason that produced it.
  defp validate_pause_reason("paused", reason) when reason in @pause_reasons, do: {:ok, reason}
  defp validate_pause_reason("paused", _reason), do: {:error, :invalid_response}
  defp validate_pause_reason(_state, nil), do: {:ok, nil}
  defp validate_pause_reason(_state, _reason), do: {:error, :invalid_response}

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

  # Every absent value must name itself. That is what keeps a missing counter
  # from silently reading as zero and a missing quota from reading as unlimited.
  defp require_unknowns(unknown_fields, elapsed, tokens, cost, quota, status) do
    required =
      []
      |> add_required("elapsed", elapsed.source == "unknown")
      |> add_required("tokens", tokens.source == "unknown")
      |> add_required("tokens.input", tokens.source != "unknown" and is_nil(tokens.input))
      |> add_required("tokens.output", tokens.source != "unknown" and is_nil(tokens.output))
      |> add_required("estimated_cost", cost.source == "unknown")
      |> add_required("quota", quota.source == "unknown")
      |> add_required("status", status.source == "unknown")

    if Enum.all?(required, &(&1 in unknown_fields)),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp add_required(required, _field, false), do: required
  defp add_required(required, field, true), do: [field | required]

  defp optional_value("unknown", nil, _fun), do: {:ok, nil}
  defp optional_value("unknown", _value, _fun), do: {:error, :invalid_response}
  defp optional_value(_source, value, fun), do: fun.(value)

  defp member(value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_response}
  end

  defp member(_value, _allowed), do: {:error, :invalid_response}

  defp normalize_currency(currency) when is_binary(currency) do
    if Regex.match?(~r/\A[A-Z]{3}\z/, currency),
      do: {:ok, currency},
      else: {:error, :invalid_response}
  end

  defp normalize_currency(_currency), do: {:error, :invalid_response}

  defp normalize_decimal(%Decimal{coef: coef}, _format, _maximum)
       when coef in [:inf, :qNaN, :sNaN],
       do: {:error, :invalid_response}

  defp normalize_decimal(%Decimal{} = value, format, maximum) do
    with true <- Regex.match?(format, Decimal.to_string(value, :normal)),
         true <- Decimal.compare(value, 0) != :lt,
         true <- Decimal.compare(value, maximum) != :gt do
      {:ok, value}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_decimal(value, format, maximum) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = parsed, ""} -> normalize_decimal(parsed, format, maximum)
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_decimal(value, format, maximum) when is_integer(value),
    do: normalize_decimal(Decimal.new(value), format, maximum)

  defp normalize_decimal(_value, _format, _maximum), do: {:error, :invalid_response}

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _other -> {:error, :invalid_response}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_response}

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_response}

  defp validate_encoded_size(value) do
    case Jason.encode(encodable(value)) do
      {:ok, encoded} when byte_size(encoded) <= @max_result_bytes -> :ok
      _other -> {:error, :invalid_response}
    end
  end

  defp encodable(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encodable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encodable(value) when is_list(value), do: Enum.map(value, &encodable/1)

  defp encodable(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), encodable(item)} end)
  end

  defp encodable(value), do: value

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
