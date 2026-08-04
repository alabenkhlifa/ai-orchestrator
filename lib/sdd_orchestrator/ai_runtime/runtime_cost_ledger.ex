defmodule SddOrchestrator.AIRuntime.RuntimeCostLedger do
  @moduledoc """
  One API-key runtime session's strict non-exceeding spending-ceiling state.

  The ledger records the approved currency and ceiling, the versioned official
  price snapshot the reservations were calculated from, the bounded request
  configuration those calculations assume, the current atomic reservation, the
  reconciled observed cost, and the pause state. Provider invoices, payment
  credentials, provider account identity, and raw provider errors never belong
  in this schema.

  Outstanding reservations live in one minimized map keyed by idempotency key so
  one session owns exactly one ceiling row. `reserved_amount` is the sum of that
  map, and a database check constraint is the last line of defence against a
  concurrent over-allocation of the ceiling.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @amount_scale 4
  @max_amount Decimal.new(1_000_000)
  @max_unit_price Decimal.new(100_000)
  @max_tokens 10_000_000
  @max_outstanding 64
  @max_label_bytes 100
  @max_key_bytes 255
  @amount_format ~r/\A\d+(\.\d{1,4})?\z/
  @unit_price_format ~r/\A\d+(\.\d{1,8})?\z/
  @pause_reasons ~w(insufficient_capacity)
  @reservation_keys ~w(amount reserved_at max_input_tokens max_output_tokens)a

  @type t :: %__MODULE__{}

  @typedoc "One minimized outstanding reservation entry."
  @type reservation :: %{
          idempotency_key: String.t(),
          amount: Decimal.t(),
          reserved_at: DateTime.t(),
          max_input_tokens: pos_integer(),
          max_output_tokens: pos_integer()
        }

  schema "runtime_cost_ledgers" do
    field :currency, :string
    field :ceiling, :decimal
    field :price_version, :string
    field :price_source, :string
    field :price_published_at, :utc_datetime
    field :price_expires_at, :utc_datetime
    field :input_unit_price, :decimal
    field :output_unit_price, :decimal
    field :max_input_tokens, :integer
    field :max_output_tokens, :integer
    field :reserved_amount, :decimal
    field :observed_amount, :decimal
    field :outstanding_reservations, :map
    field :paused, :boolean, default: false
    field :pause_reason, :string
    field :paused_at, :utc_datetime

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :session, SddOrchestrator.AIRuntime.AIRuntimeSession

    timestamps()
  end

  @doc "Opens one ceiling row for an already authorized API-key session."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(ledger, attrs) do
    ledger
    |> cast(attrs, [
      :account_id,
      :session_id,
      :currency,
      :ceiling,
      :price_version,
      :price_source,
      :price_published_at,
      :price_expires_at,
      :input_unit_price,
      :output_unit_price,
      :max_input_tokens,
      :max_output_tokens,
      :reserved_amount,
      :observed_amount,
      :outstanding_reservations,
      :paused,
      :pause_reason,
      :paused_at
    ])
    |> validate_required([
      :account_id,
      :session_id,
      :currency,
      :ceiling,
      :price_version,
      :price_source,
      :price_published_at,
      :price_expires_at,
      :input_unit_price,
      :output_unit_price,
      :max_input_tokens,
      :max_output_tokens,
      :reserved_amount,
      :observed_amount,
      :outstanding_reservations
    ])
    |> shared_validations()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:session_id)
    |> unique_constraint(:session_id, name: :runtime_cost_ledgers_session_index)
  end

  @doc "Applies one atomic reservation, reconciliation, release, or pause."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(ledger, attrs) do
    ledger
    |> cast(attrs, [
      :price_version,
      :price_source,
      :price_published_at,
      :price_expires_at,
      :input_unit_price,
      :output_unit_price,
      :reserved_amount,
      :observed_amount,
      :outstanding_reservations,
      :paused,
      :pause_reason,
      :paused_at
    ])
    |> shared_validations()
  end

  @doc "The decimal scale every ledger amount is stored and rounded at."
  @spec amount_scale() :: non_neg_integer()
  def amount_scale, do: @amount_scale

  @doc "The largest amount a ceiling, reservation, or observation may reach."
  @spec max_amount() :: Decimal.t()
  def max_amount, do: @max_amount

  @doc "The largest bounded token count a request configuration may approve."
  @spec max_tokens() :: pos_integer()
  def max_tokens, do: @max_tokens

  @doc "The largest number of reservations one session may hold outstanding."
  @spec max_outstanding() :: pos_integer()
  def max_outstanding, do: @max_outstanding

  @doc "The resumable pause reasons a ceiling row may record."
  @spec pause_reasons() :: [String.t()]
  def pause_reasons, do: @pause_reasons

  @doc "Validates one idempotency key without persisting anything."
  @spec validate_idempotency_key(term()) :: {:ok, String.t()} | {:error, :invalid_request}
  def validate_idempotency_key(key) when is_binary(key) do
    if key == String.trim(key) and byte_size(key) in 1..@max_key_bytes and
         not forbidden_content?(key),
       do: {:ok, key},
       else: {:error, :invalid_request}
  end

  def validate_idempotency_key(_key), do: {:error, :invalid_request}

  @doc """
  Decodes the stored outstanding reservations into sorted minimized entries.

  An entry that cannot be decoded is dropped rather than surfaced, and the
  reservation-sum invariant checked on every write refuses such a row.
  """
  @spec decode_reservations(term()) :: [reservation()]
  def decode_reservations(reservations) when is_map(reservations) do
    reservations
    |> Enum.flat_map(fn entry ->
      case decode_reservation(entry) do
        {:ok, decoded} -> [decoded]
        {:error, _reason} -> []
      end
    end)
    |> Enum.sort_by(&{DateTime.to_unix(&1.reserved_at), &1.idempotency_key})
  end

  def decode_reservations(_reservations), do: []

  @doc "Encodes minimized reservation entries into their stored map form."
  @spec encode_reservations([reservation()]) :: map()
  def encode_reservations(reservations) when is_list(reservations) do
    Map.new(reservations, fn reservation ->
      {reservation.idempotency_key,
       %{
         "amount" => Decimal.to_string(reservation.amount, :normal),
         "reserved_at" => DateTime.to_iso8601(reservation.reserved_at),
         "max_input_tokens" => reservation.max_input_tokens,
         "max_output_tokens" => reservation.max_output_tokens
       }}
    end)
  end

  @doc "Sums the outstanding reservation amounts at the ledger scale."
  @spec reservation_sum([reservation()]) :: Decimal.t()
  def reservation_sum(reservations) when is_list(reservations) do
    reservations
    |> Enum.reduce(Decimal.new(0), fn reservation, total ->
      Decimal.add(total, reservation.amount)
    end)
    |> Decimal.round(@amount_scale)
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_inclusion(:pause_reason, @pause_reasons)
    |> validate_length(:currency, is: 3)
    |> validate_length(:price_version, min: 1, max: @max_label_bytes)
    |> validate_length(:price_source, min: 1, max: @max_label_bytes)
    |> validate_number(:max_input_tokens, greater_than: 0, less_than_or_equal_to: @max_tokens)
    |> validate_number(:max_output_tokens, greater_than: 0, less_than_or_equal_to: @max_tokens)
    |> validate_currency()
    |> validate_price_window()
    |> validate_unit_prices()
    |> validate_amounts()
    |> validate_reservations()
    |> validate_pause_state()
    |> check_constraint(:currency, name: :runtime_cost_ledgers_currency_check)
    |> check_constraint(:ceiling, name: :runtime_cost_ledgers_ceiling_check)
    |> check_constraint(:price_version, name: :runtime_cost_ledgers_price_check)
    |> check_constraint(:max_input_tokens,
      name: :runtime_cost_ledgers_bounded_request_check
    )
    |> check_constraint(:reserved_amount, name: :runtime_cost_ledgers_capacity_check)
    |> check_constraint(:outstanding_reservations,
      name: :runtime_cost_ledgers_reservations_check
    )
    |> check_constraint(:paused, name: :runtime_cost_ledgers_pause_check)
  end

  defp validate_currency(changeset) do
    case get_field(changeset, :currency) do
      nil -> changeset
      _currency -> validate_format(changeset, :currency, ~r/\A[A-Z]{3}\z/)
    end
  end

  defp validate_price_window(changeset) do
    published_at = get_field(changeset, :price_published_at)
    expires_at = get_field(changeset, :price_expires_at)

    if match?(%DateTime{}, published_at) and match?(%DateTime{}, expires_at) and
         DateTime.compare(expires_at, published_at) != :gt do
      add_error(changeset, :price_expires_at, "must be after publication")
    else
      changeset
    end
  end

  defp validate_unit_prices(changeset) do
    Enum.reduce([:input_unit_price, :output_unit_price], changeset, fn field, acc ->
      case get_field(acc, field) do
        nil -> acc
        value -> validate_bounded(acc, field, value, @unit_price_format, @max_unit_price, :gt)
      end
    end)
  end

  defp validate_amounts(changeset) do
    changeset =
      Enum.reduce([:reserved_amount, :observed_amount], changeset, fn field, acc ->
        case get_field(acc, field) do
          nil -> acc
          value -> validate_bounded(acc, field, value, @amount_format, @max_amount, :gt_or_eq)
        end
      end)

    case get_field(changeset, :ceiling) do
      nil ->
        validate_capacity(changeset)

      ceiling ->
        changeset
        |> validate_bounded(:ceiling, ceiling, @amount_format, @max_amount, :gt)
        |> validate_capacity()
    end
  end

  defp validate_bounded(changeset, field, value, format, maximum, comparison) do
    if bounded_decimal?(value, format, maximum, comparison),
      do: changeset,
      else: add_error(changeset, field, "is out of range")
  end

  defp bounded_decimal?(%Decimal{coef: coef}, _format, _maximum, _comparison)
       when coef in [:inf, :qNaN, :sNaN],
       do: false

  defp bounded_decimal?(%Decimal{} = value, format, maximum, comparison) do
    Regex.match?(format, Decimal.to_string(value, :normal)) and
      lower_bound?(value, comparison) and
      Decimal.compare(value, maximum) != :gt
  end

  defp bounded_decimal?(_value, _format, _maximum, _comparison), do: false

  defp lower_bound?(value, :gt), do: Decimal.compare(value, 0) == :gt
  defp lower_bound?(value, :gt_or_eq), do: Decimal.compare(value, 0) != :lt

  defp validate_capacity(changeset) do
    ceiling = get_field(changeset, :ceiling)
    reserved = get_field(changeset, :reserved_amount)
    observed = get_field(changeset, :observed_amount)

    if decimals?([ceiling, reserved, observed]) and
         Decimal.compare(Decimal.add(reserved, observed), ceiling) == :gt do
      add_error(changeset, :reserved_amount, "exceeds the approved ceiling")
    else
      changeset
    end
  end

  defp decimals?(values), do: Enum.all?(values, &match?(%Decimal{}, &1))

  defp validate_reservations(changeset) do
    stored = get_field(changeset, :outstanding_reservations)
    reserved = get_field(changeset, :reserved_amount)

    cond do
      is_nil(stored) ->
        changeset

      not valid_reservation_map?(stored) ->
        add_error(changeset, :outstanding_reservations, "is invalid")

      match?(%Decimal{}, reserved) and not balanced?(stored, reserved) ->
        add_error(changeset, :outstanding_reservations, "does not sum to the reservation")

      true ->
        changeset
    end
  end

  defp valid_reservation_map?(stored) when is_map(stored) and not is_struct(stored) do
    map_size(stored) <= @max_outstanding and
      Enum.all?(stored, fn entry -> match?({:ok, _decoded}, decode_reservation(entry)) end)
  end

  defp valid_reservation_map?(_stored), do: false

  defp balanced?(stored, reserved) do
    stored
    |> decode_reservations()
    |> reservation_sum()
    |> Decimal.compare(Decimal.round(reserved, @amount_scale)) == :eq
  end

  defp validate_pause_state(changeset) do
    paused = get_field(changeset, :paused)
    reason = get_field(changeset, :pause_reason)
    paused_at = get_field(changeset, :paused_at)

    consistent? =
      (paused == true and is_binary(reason) and match?(%DateTime{}, paused_at)) or
        (paused == false and is_nil(reason) and is_nil(paused_at))

    if consistent?, do: changeset, else: add_error(changeset, :paused, "is inconsistent")
  end

  defp decode_reservation({key, value}) when is_map(value) do
    with {:ok, key} <- validate_idempotency_key(key),
         {:ok, entry} <- exact_map(value, @reservation_keys),
         {:ok, amount} <- decode_amount(entry.amount),
         {:ok, reserved_at} <- decode_timestamp(entry.reserved_at),
         {:ok, max_input_tokens} <- decode_tokens(entry.max_input_tokens),
         {:ok, max_output_tokens} <- decode_tokens(entry.max_output_tokens) do
      {:ok,
       %{
         idempotency_key: key,
         amount: amount,
         reserved_at: reserved_at,
         max_input_tokens: max_input_tokens,
         max_output_tokens: max_output_tokens
       }}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp decode_reservation(_entry), do: {:error, :invalid_request}

  defp decode_amount(%Decimal{} = amount) do
    if bounded_decimal?(amount, @amount_format, @max_amount, :gt_or_eq),
      do: {:ok, amount},
      else: {:error, :invalid_request}
  end

  defp decode_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {%Decimal{} = parsed, ""} -> decode_amount(parsed)
      _other -> {:error, :invalid_request}
    end
  end

  defp decode_amount(_amount), do: {:error, :invalid_request}

  defp decode_timestamp(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp decode_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp decode_timestamp(_value), do: {:error, :invalid_request}

  defp decode_tokens(tokens) when is_integer(tokens) and tokens in 1..@max_tokens,
    do: {:ok, tokens}

  defp decode_tokens(_tokens), do: {:error, :invalid_request}

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
        {:error, :invalid_request}
    end
  end
end
