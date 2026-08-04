defmodule SddOrchestrator.AIRuntime.RuntimeCosts.PriceSnapshot do
  @moduledoc """
  Fail-closed versioned official-price registry for API-key cost reservation.

  A chargeable API-key turn may only be reserved from an explicitly registered
  official price list. Every registration carries its own version identifier,
  official source label, publication time, expiry time, currency, and per-model
  unit prices expressed in the ledger currency per one million tokens.

  The registry defaults to empty so an unconfigured deployment refuses
  execution rather than treating a model as free. Deployment registrations are
  price-source evidence and intentionally do not live in this module: they are
  supplied through `:official_price_snapshots` and gated at release.

  Every lookup revalidates the whole registry. A malformed, negative,
  unparseable, oversized, or credential-shaped entry makes the registry
  untrustworthy as a whole and fails closed with `:missing_price`; an expired
  current registration fails closed with `:stale_price`.
  """

  @application :sdd_orchestrator
  @setting :official_price_snapshots

  @snapshot_keys ~w(version source published_at expires_at currency models)a
  @price_keys ~w(input output)a

  @max_snapshots 64
  @max_models 512
  @max_label_bytes 100
  @max_model_bytes 255
  @max_unit_price Decimal.new(100_000)
  @max_tokens 10_000_000
  @unit_price_format ~r/\A\d+(\.\d{1,8})?\z/
  @tokens_per_unit Decimal.new(1_000_000)

  @typedoc "One validated official price for one pinned model."
  @type price :: %{
          version: String.t(),
          source: String.t(),
          published_at: DateTime.t(),
          expires_at: DateTime.t(),
          currency: String.t(),
          input_unit_price: Decimal.t(),
          output_unit_price: Decimal.t()
        }

  @typedoc "Safe fail-closed price-registry failures."
  @type error :: :missing_price | :stale_price

  @doc """
  Loads the current versioned official price for one pinned model.

  Options accept `:snapshots` to supply a registry explicitly and `:version` to
  require one exact registration. An unknown model, an unknown version, an
  unpublished registration, and any untrustworthy registry fail closed with
  `:missing_price`; an expired current registration fails with `:stale_price`.
  """
  @spec current(String.t(), DateTime.t(), keyword()) :: {:ok, price()} | {:error, error()}
  def current(model, now, opts \\ [])

  def current(model, %DateTime{} = now, opts) when is_binary(model) do
    with {:ok, snapshots} <- registry(opts),
         {:ok, candidate} <- candidate(snapshots, model, now, Keyword.get(opts, :version)) do
      if DateTime.compare(candidate.expires_at, now) == :gt,
        do: {:ok, candidate},
        else: {:error, :stale_price}
    end
  end

  def current(_model, _now, _opts), do: {:error, :missing_price}

  @doc """
  Calculates the conservative maximum cost of one bounded API-key turn.

  The bounded request configuration is charged at its full worst case and the
  result is rounded away from zero to the ledger scale, so the estimate can
  never under-reserve the turn it authorizes.
  """
  @spec conservative_maximum(price(), pos_integer(), pos_integer(), non_neg_integer()) ::
          {:ok, Decimal.t()} | {:error, :invalid_request}
  def conservative_maximum(price, max_input_tokens, max_output_tokens, scale)
      when is_map(price) and is_integer(scale) and scale >= 0 do
    with :ok <- bounded_tokens(max_input_tokens),
         :ok <- bounded_tokens(max_output_tokens),
         %Decimal{} = input <- unit_cost(price.input_unit_price, max_input_tokens),
         %Decimal{} = output <- unit_cost(price.output_unit_price, max_output_tokens) do
      {:ok, input |> Decimal.add(output) |> Decimal.round(scale, :ceiling)}
    else
      _other -> {:error, :invalid_request}
    end
  end

  def conservative_maximum(_price, _max_input_tokens, _max_output_tokens, _scale),
    do: {:error, :invalid_request}

  @doc "The largest bounded token count one registration may be charged for."
  @spec max_tokens() :: pos_integer()
  def max_tokens, do: @max_tokens

  defp unit_cost(unit_price, tokens) do
    unit_price
    |> Decimal.mult(Decimal.new(tokens))
    |> Decimal.div(@tokens_per_unit)
  end

  defp bounded_tokens(tokens) when is_integer(tokens) and tokens in 1..@max_tokens, do: :ok
  defp bounded_tokens(_tokens), do: {:error, :invalid_request}

  defp candidate(snapshots, model, now, version) do
    snapshots
    |> Enum.filter(&published?(&1, model, now, version))
    |> Enum.sort_by(&DateTime.to_unix(&1.published_at), :desc)
    |> case do
      [] -> {:error, :missing_price}
      [current | _older] -> {:ok, price(current, model)}
    end
  end

  defp published?(snapshot, model, now, version) do
    Map.has_key?(snapshot.models, model) and
      DateTime.compare(snapshot.published_at, now) != :gt and
      (is_nil(version) or snapshot.version == version)
  end

  defp price(snapshot, model) do
    %{input: input, output: output} = Map.fetch!(snapshot.models, model)

    %{
      version: snapshot.version,
      source: snapshot.source,
      published_at: snapshot.published_at,
      expires_at: snapshot.expires_at,
      currency: snapshot.currency,
      input_unit_price: input,
      output_unit_price: output
    }
  end

  defp registry(opts) do
    snapshots =
      Keyword.get_lazy(opts, :snapshots, fn ->
        Application.get_env(@application, @setting, %{})
      end)

    with true <- is_map(snapshots) and not is_struct(snapshots),
         true <- map_size(snapshots) <= @max_snapshots,
         {:ok, validated} <- map_ok(Map.to_list(snapshots), &normalize_snapshot/1),
         true <- unique?(validated) do
      {:ok, validated}
    else
      _other -> {:error, :missing_price}
    end
  end

  defp unique?(snapshots) do
    versions = Enum.map(snapshots, & &1.version)
    length(Enum.uniq(versions)) == length(versions)
  end

  defp normalize_snapshot({key, snapshot}) when is_map(snapshot) do
    with {:ok, snapshot} <- exact_map(snapshot, @snapshot_keys),
         {:ok, version} <- label(snapshot.version),
         true <- key == version,
         {:ok, source} <- label(snapshot.source),
         {:ok, currency} <- currency(snapshot.currency),
         {:ok, published_at} <- timestamp(snapshot.published_at),
         {:ok, expires_at} <- timestamp(snapshot.expires_at),
         :gt <- DateTime.compare(expires_at, published_at),
         {:ok, models} <- normalize_models(snapshot.models) do
      {:ok,
       %{
         version: version,
         source: source,
         published_at: published_at,
         expires_at: expires_at,
         currency: currency,
         models: models
       }}
    else
      _other -> {:error, :missing_price}
    end
  end

  defp normalize_snapshot(_entry), do: {:error, :missing_price}

  defp normalize_models(models) when is_map(models) and map_size(models) in 1..@max_models do
    models
    |> Map.to_list()
    |> map_ok(&normalize_model/1)
    |> case do
      {:ok, normalized} -> {:ok, Map.new(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_models(_models), do: {:error, :missing_price}

  defp normalize_model({model, prices}) when is_map(prices) do
    with :ok <- bounded_string(model, @max_model_bytes),
         {:ok, prices} <- exact_map(prices, @price_keys),
         {:ok, input} <- unit_price(prices.input),
         {:ok, output} <- unit_price(prices.output) do
      {:ok, {model, %{input: input, output: output}}}
    else
      _other -> {:error, :missing_price}
    end
  end

  defp normalize_model(_entry), do: {:error, :missing_price}

  defp unit_price(%Decimal{} = value), do: bounded_unit_price(value)

  defp unit_price(value) when is_integer(value), do: bounded_unit_price(Decimal.new(value))

  defp unit_price(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = parsed, ""} -> bounded_unit_price(parsed)
      _other -> {:error, :missing_price}
    end
  end

  defp unit_price(_value), do: {:error, :missing_price}

  defp bounded_unit_price(%Decimal{} = value) do
    with false <- decimal_special?(value),
         true <- Regex.match?(@unit_price_format, Decimal.to_string(value, :normal)),
         :gt <- Decimal.compare(value, 0),
         true <- Decimal.compare(value, @max_unit_price) != :gt do
      {:ok, value}
    else
      _other -> {:error, :missing_price}
    end
  end

  defp decimal_special?(%Decimal{coef: coef}), do: coef in [:inf, :qNaN, :sNaN]

  defp label(value) do
    case bounded_string(value, @max_label_bytes) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp currency(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Z]{3}\z/, value),
      do: {:ok, value},
      else: {:error, :missing_price}
  end

  defp currency(_value), do: {:error, :missing_price}

  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _other -> {:error, :missing_price}
    end
  end

  defp timestamp(_value), do: {:error, :missing_price}

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :missing_price}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :missing_price}

  defp forbidden_content?(value) do
    downcased = String.downcase(value)

    Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, value) or
      Regex.match?(~r/\bsk-[a-z0-9_-]{8,}\b/i, value) or
      String.contains?(downcased, "bearer ") or
      String.contains?(downcased, "api_key=") or
      String.contains?(downcased, "access_token=")
  end

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :missing_price}
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
end
