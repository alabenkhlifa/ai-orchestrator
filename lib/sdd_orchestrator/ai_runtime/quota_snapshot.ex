defmodule SddOrchestrator.AIRuntime.QuotaSnapshot do
  @moduledoc """
  One short-lived minimized projection of authenticated quota facts.

  Snapshots are account and personal-connection scoped. They contain only
  normalized quota, reset-credit, paid-continuation, and token-activity facts;
  worker profile references, provider account identity, plan detail, raw
  errors, and credentials never belong in this schema.

  Every row carries the expiry its refresh derived from the source's retrieval
  timestamp, and the database refuses a row that does not expire after it was
  retrieved. The row is storage-limited by that value: retention deletes it once
  the expiry has passed, and deletes it outright once its connection is terminal
  or scheduled for deletion. Deleting the account or the connection cascades.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.AIRuntime.QuotaAdapter

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @statuses ~w(reported partial unknown)
  @authentication_modes ~w(chatgpt api_key)
  @sources ~w(official_client)

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :connection_id,
             :provider,
             :authentication_mode,
             :status,
             :source,
             :source_methods,
             :source_version,
             :retrieved_at,
             :expires_at,
             :inserted_at
           ]}

  @type t :: %__MODULE__{}

  schema "quota_snapshots" do
    field :provider, :string
    field :authentication_mode, :string
    field :status, :string
    field :source, :string
    field :source_methods, {:array, :string}
    field :source_version, :string
    field :retrieved_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :buckets, :map
    field :reset_credits, :map
    field :token_activity, :map
    field :unknown_fields, {:array, :string}

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :connection, SddOrchestrator.AIRuntime.PersonalAIConnection

    timestamps()
  end

  @doc "Builds an immutable quota snapshot from already authenticated facts."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :account_id,
      :connection_id,
      :provider,
      :authentication_mode,
      :status,
      :source,
      :source_methods,
      :source_version,
      :retrieved_at,
      :expires_at,
      :buckets,
      :reset_credits,
      :token_activity,
      :unknown_fields
    ])
    |> validate_required([
      :account_id,
      :connection_id,
      :provider,
      :authentication_mode,
      :status,
      :source,
      :source_version,
      :retrieved_at,
      :expires_at,
      :buckets,
      :unknown_fields
    ])
    |> validate_inclusion(:authentication_mode, @authentication_modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:provider, min: 1, max: 100)
    |> validate_length(:source_version,
      min: 1,
      max: QuotaAdapter.max_source_version_bytes()
    )
    |> validate_result()
    |> validate_expiry()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:connection_id, name: :quota_snapshots_account_connection_fkey)
    |> unique_constraint([:account_id, :connection_id],
      name: :quota_snapshots_account_connection_index,
      error_key: :connection_id
    )
    |> check_constraint(:authentication_mode,
      name: :quota_snapshots_authentication_mode_check
    )
    |> check_constraint(:status, name: :quota_snapshots_status_check)
    |> check_constraint(:source, name: :quota_snapshots_source_check)
    |> check_constraint(:expires_at, name: :quota_snapshots_expiry_check)
    |> check_constraint(:buckets, name: :quota_snapshots_buckets_check)
  end

  defp validate_result(changeset) do
    result = %{
      provider: get_field(changeset, :provider),
      authentication_mode: get_field(changeset, :authentication_mode),
      status: get_field(changeset, :status),
      source: get_field(changeset, :source),
      source_methods: get_field(changeset, :source_methods),
      source_version: get_field(changeset, :source_version),
      retrieved_at: get_field(changeset, :retrieved_at),
      buckets: bucket_items(get_field(changeset, :buckets)),
      reset_credits: get_field(changeset, :reset_credits),
      token_activity: get_field(changeset, :token_activity),
      unknown_fields: get_field(changeset, :unknown_fields)
    }

    case QuotaAdapter.validate_result(
           result,
           result.provider,
           result.authentication_mode
         ) do
      {:ok, normalized} ->
        changeset
        |> put_change(:buckets, %{"items" => encode(normalized.buckets)})
        |> put_change(:reset_credits, encode(normalized.reset_credits))
        |> put_change(:token_activity, encode(normalized.token_activity))

      {:error, _reason} ->
        add_error(changeset, :buckets, "contains invalid quota facts")
    end
  end

  defp bucket_items(%{"items" => items} = buckets) when map_size(buckets) == 1, do: items
  defp bucket_items(_buckets), do: :invalid

  defp validate_expiry(changeset) do
    case {get_field(changeset, :retrieved_at), get_field(changeset, :expires_at)} do
      {%DateTime{} = retrieved_at, %DateTime{} = expires_at} ->
        if DateTime.compare(expires_at, retrieved_at) == :gt,
          do: changeset,
          else: add_error(changeset, :expires_at, "must be after retrieval")

      _other ->
        changeset
    end
  end

  defp encode(nil), do: nil

  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp encode(value) when is_list(value), do: Enum.map(value, &encode/1)

  defp encode(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), encode(item)} end)
  end

  defp encode(value), do: value
end
