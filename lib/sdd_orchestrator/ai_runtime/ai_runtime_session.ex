defmodule SddOrchestrator.AIRuntime.AIRuntimeSession do
  @moduledoc """
  One immutable pinned runtime configuration for a support conversation or run.

  A session records the opaque connection reference, the proven model and
  reasoning effort, the catalog provenance that proved them, the configuration
  version, the explicit owner opt-ins that were in force, and any API-key
  spending ceiling. Credentials, provider identity, plan detail, and raw
  provider errors never belong in this schema, and every pinned column is
  frozen by a database trigger after insertion.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @consumer_kinds ~w(support_assistant working_agent)
  @providers ~w(openai_codex)
  @authentication_modes ~w(chatgpt api_key)
  @catalog_sources ~w(official_client)

  @opt_in_kinds ~w(scarce_model model_specific_quota provider_paid_continuation)a
  @cost_boundaries ~w(scarce_model quota provider_paid_continuation)a
  @opt_in_keys ~w(id kind bucket_id cost_boundary valid_from expires_at)a

  @configuration_version 1
  @max_opt_ins 32
  @max_identifier_bytes 255
  @max_model_bytes 255
  @max_effort_bytes 64
  @max_source_method_bytes 100
  @max_source_version_bytes 200
  @max_ceiling_amount Decimal.new(1_000_000)

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :connection_id,
             :consumer_kind,
             :provider,
             :authentication_mode,
             :model,
             :reasoning_effort,
             :configuration_version,
             :catalog_source,
             :catalog_source_method,
             :catalog_retrieved_at,
             :catalog_expires_at,
             :spending_ceiling_currency,
             :pinned_at,
             :inserted_at
           ]}

  @type t :: %__MODULE__{}

  schema "ai_runtime_sessions" do
    field :consumer_kind, :string
    field :consumer_ref, :string
    field :provider, :string
    field :authentication_mode, :string
    field :model, :string
    field :reasoning_effort, :string
    field :configuration_version, :integer, default: @configuration_version
    field :catalog_snapshot_ref, :binary_id
    field :catalog_source, :string
    field :catalog_source_method, :string
    field :catalog_source_version, :string
    field :catalog_retrieved_at, :utc_datetime
    field :catalog_expires_at, :utc_datetime
    field :opt_ins, :map
    field :spending_ceiling_amount, :decimal
    field :spending_ceiling_currency, :string
    field :pinned_at, :utc_datetime

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :connection, SddOrchestrator.AIRuntime.PersonalAIConnection

    timestamps()
  end

  @doc "Builds one immutable pin from an already authorized runtime selection."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :account_id,
      :connection_id,
      :consumer_kind,
      :consumer_ref,
      :provider,
      :authentication_mode,
      :model,
      :reasoning_effort,
      :configuration_version,
      :catalog_snapshot_ref,
      :catalog_source,
      :catalog_source_method,
      :catalog_source_version,
      :catalog_retrieved_at,
      :catalog_expires_at,
      :opt_ins,
      :spending_ceiling_amount,
      :spending_ceiling_currency,
      :pinned_at
    ])
    |> validate_required([
      :account_id,
      :connection_id,
      :consumer_kind,
      :consumer_ref,
      :provider,
      :authentication_mode,
      :model,
      :reasoning_effort,
      :configuration_version,
      :catalog_snapshot_ref,
      :catalog_source,
      :catalog_source_method,
      :catalog_source_version,
      :catalog_retrieved_at,
      :catalog_expires_at,
      :opt_ins,
      :pinned_at
    ])
    |> validate_inclusion(:consumer_kind, @consumer_kinds)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:authentication_mode, @authentication_modes)
    |> validate_inclusion(:catalog_source, @catalog_sources)
    |> validate_length(:consumer_ref, min: 1, max: @max_identifier_bytes)
    |> validate_length(:model, min: 1, max: @max_model_bytes)
    |> validate_length(:reasoning_effort, min: 1, max: @max_effort_bytes)
    |> validate_length(:catalog_source_method, min: 1, max: @max_source_method_bytes)
    |> validate_length(:catalog_source_version, min: 1, max: @max_source_version_bytes)
    |> validate_number(:configuration_version, greater_than_or_equal_to: 1)
    |> validate_catalog_expiry()
    |> validate_opt_in_map()
    |> validate_spending_ceiling()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:connection_id)
    |> unique_constraint([:account_id, :consumer_kind, :consumer_ref],
      name: :ai_runtime_sessions_consumer_index,
      error_key: :consumer_ref
    )
    |> check_constraint(:consumer_kind, name: :ai_runtime_sessions_consumer_kind_check)
    |> check_constraint(:consumer_ref, name: :ai_runtime_sessions_consumer_ref_check)
    |> check_constraint(:provider, name: :ai_runtime_sessions_provider_check)
    |> check_constraint(:authentication_mode,
      name: :ai_runtime_sessions_authentication_mode_check
    )
    |> check_constraint(:model, name: :ai_runtime_sessions_selection_check)
    |> check_constraint(:configuration_version,
      name: :ai_runtime_sessions_configuration_version_check
    )
    |> check_constraint(:catalog_source, name: :ai_runtime_sessions_catalog_source_check)
    |> check_constraint(:catalog_expires_at, name: :ai_runtime_sessions_catalog_expiry_check)
    |> check_constraint(:opt_ins, name: :ai_runtime_sessions_opt_ins_check)
    |> check_constraint(:spending_ceiling_amount,
      name: :ai_runtime_sessions_spending_ceiling_check
    )
  end

  @doc "The consumer kinds that share one runtime contract."
  def consumer_kinds, do: @consumer_kinds

  @doc "The version stamped on a newly pinned configuration."
  def configuration_version, do: @configuration_version

  @doc false
  def max_ceiling_amount, do: @max_ceiling_amount

  @doc """
  Validates the minimized opt-in references a session may pin.

  Every reference keeps only the owner choice identifier, kind, applicable
  bucket, approved cost boundary, and validity window. Owner, connection, and
  model already belong to the session itself.
  """
  @spec validate_opt_ins(term()) :: {:ok, [map()]} | {:error, :invalid_opt_ins}
  def validate_opt_ins(items) when is_list(items) and length(items) <= @max_opt_ins do
    with {:ok, normalized} <- map_ok(items, &normalize_opt_in/1),
         true <- normalized |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_opt_ins}
    end
  end

  def validate_opt_ins(_items), do: {:error, :invalid_opt_ins}

  @doc false
  @spec decode_opt_ins(map()) :: [map()]
  def decode_opt_ins(%{"items" => items}) when is_list(items) do
    case validate_opt_ins(items) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> []
    end
  end

  def decode_opt_ins(_opt_ins), do: []

  defp encode_opt_ins(items) do
    Enum.map(items, fn item ->
      %{
        "id" => item.id,
        "kind" => Atom.to_string(item.kind),
        "bucket_id" => item.bucket_id,
        "cost_boundary" => Atom.to_string(item.cost_boundary),
        "valid_from" => DateTime.to_iso8601(item.valid_from),
        "expires_at" => DateTime.to_iso8601(item.expires_at)
      }
    end)
  end

  defp validate_opt_in_map(changeset) do
    case get_field(changeset, :opt_ins) do
      %{"items" => items} = opt_ins when map_size(opt_ins) == 1 ->
        case validate_opt_ins(items) do
          {:ok, normalized} ->
            put_change(changeset, :opt_ins, %{"items" => encode_opt_ins(normalized)})

          {:error, _reason} ->
            add_error(changeset, :opt_ins, "is invalid")
        end

      _other ->
        add_error(changeset, :opt_ins, "is invalid")
    end
  end

  defp validate_catalog_expiry(changeset) do
    case {get_field(changeset, :catalog_retrieved_at), get_field(changeset, :catalog_expires_at)} do
      {%DateTime{} = retrieved_at, %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, retrieved_at) == :gt,
          do: changeset,
          else: add_error(changeset, :catalog_expires_at, "must be after retrieval")

      _other ->
        changeset
    end
  end

  defp validate_spending_ceiling(changeset) do
    amount = get_field(changeset, :spending_ceiling_amount)
    currency = get_field(changeset, :spending_ceiling_currency)

    case get_field(changeset, :authentication_mode) do
      "api_key" -> validate_required_ceiling(changeset, amount, currency)
      _other -> validate_absent_ceiling(changeset, amount, currency)
    end
  end

  defp validate_required_ceiling(changeset, amount, currency) do
    changeset
    |> validate_required([:spending_ceiling_amount, :spending_ceiling_currency])
    |> then(fn changeset ->
      if is_nil(amount) or ceiling_amount?(amount),
        do: changeset,
        else: add_error(changeset, :spending_ceiling_amount, "is out of range")
    end)
    |> then(fn changeset ->
      if is_nil(currency) or ceiling_currency?(currency),
        do: changeset,
        else: add_error(changeset, :spending_ceiling_currency, "is invalid")
    end)
  end

  defp validate_absent_ceiling(changeset, amount, currency) do
    changeset
    |> then(fn changeset ->
      if is_nil(amount),
        do: changeset,
        else: add_error(changeset, :spending_ceiling_amount, "does not apply")
    end)
    |> then(fn changeset ->
      if is_nil(currency),
        do: changeset,
        else: add_error(changeset, :spending_ceiling_currency, "does not apply")
    end)
  end

  defp ceiling_amount?(%Decimal{} = amount) do
    Regex.match?(~r/\A\d+(\.\d{1,4})?\z/, Decimal.to_string(amount)) and
      Decimal.compare(amount, 0) == :gt and
      Decimal.compare(amount, @max_ceiling_amount) != :gt
  end

  defp ceiling_amount?(_amount), do: false

  defp ceiling_currency?(currency) when is_binary(currency),
    do: Regex.match?(~r/\A[A-Z]{3}\z/, currency)

  defp ceiling_currency?(_currency), do: false

  defp normalize_opt_in(item) when is_map(item) do
    with {:ok, item} <- exact_map(item, @opt_in_keys),
         :ok <- bounded_string(item.id, @max_identifier_bytes),
         {:ok, kind} <- normalize_member(item.kind, @opt_in_kinds),
         {:ok, bucket_id} <- normalize_bucket_id(item.bucket_id),
         {:ok, cost_boundary} <- normalize_member(item.cost_boundary, @cost_boundaries),
         :ok <- validate_opt_in_shape(kind, bucket_id, cost_boundary),
         {:ok, valid_from} <- normalize_datetime(item.valid_from),
         {:ok, expires_at} <- normalize_datetime(item.expires_at),
         :gt <- DateTime.compare(expires_at, valid_from) do
      {:ok,
       %{
         id: item.id,
         kind: kind,
         bucket_id: bucket_id,
         cost_boundary: cost_boundary,
         valid_from: valid_from,
         expires_at: expires_at
       }}
    else
      _ -> {:error, :invalid_opt_ins}
    end
  end

  defp normalize_opt_in(_item), do: {:error, :invalid_opt_ins}

  defp validate_opt_in_shape(:scarce_model, nil, :scarce_model), do: :ok

  defp validate_opt_in_shape(:model_specific_quota, bucket_id, :quota)
       when is_binary(bucket_id),
       do: :ok

  defp validate_opt_in_shape(:provider_paid_continuation, bucket_id, :provider_paid_continuation)
       when is_binary(bucket_id),
       do: :ok

  defp validate_opt_in_shape(_kind, _bucket_id, _cost_boundary),
    do: {:error, :invalid_opt_ins}

  defp normalize_bucket_id(nil), do: {:ok, nil}

  defp normalize_bucket_id(bucket_id) do
    case bounded_string(bucket_id, @max_identifier_bytes) do
      :ok -> {:ok, bucket_id}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _other -> {:error, :invalid_opt_ins}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_opt_ins}

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes,
      do: :ok,
      else: {:error, :invalid_opt_ins}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_opt_ins}

  defp normalize_member(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_opt_ins}
  end

  defp normalize_member(value, allowed) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, :invalid_opt_ins}
      member -> {:ok, member}
    end
  end

  defp normalize_member(_value, _allowed), do: {:error, :invalid_opt_ins}

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :invalid_opt_ins}
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
