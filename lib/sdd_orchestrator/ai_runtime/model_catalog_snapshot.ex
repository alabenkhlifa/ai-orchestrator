defmodule SddOrchestrator.AIRuntime.ModelCatalogSnapshot do
  @moduledoc """
  One short-lived minimized projection of an authenticated model catalog.

  Snapshots are account and personal-connection scoped. They contain only
  proven model compatibility and bounded provenance; worker-local profile and
  provider-account identity never belong in this schema.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.AIRuntime.ModelCatalogAdapter

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @statuses ~w(enumerated enumeration_unsupported)
  @sources ~w(official_client)

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :connection_id,
             :provider,
             :status,
             :source,
             :source_method,
             :source_version,
             :retrieved_at,
             :expires_at,
             :inserted_at
           ]}

  @type t :: %__MODULE__{}

  schema "model_catalog_snapshots" do
    field :provider, :string
    field :status, :string
    field :source, :string
    field :source_method, :string
    field :source_version, :string
    field :retrieved_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :models, :map

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :connection, SddOrchestrator.AIRuntime.PersonalAIConnection

    timestamps()
  end

  @doc "Builds an immutable catalog snapshot from already authenticated facts."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :account_id,
      :connection_id,
      :provider,
      :status,
      :source,
      :source_method,
      :source_version,
      :retrieved_at,
      :expires_at,
      :models
    ])
    |> validate_required([
      :account_id,
      :connection_id,
      :provider,
      :status,
      :source,
      :source_method,
      :source_version,
      :retrieved_at,
      :expires_at,
      :models
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:provider, min: 1, max: 100)
    |> validate_length(:source_method, min: 1, max: 100)
    |> validate_length(:source_version,
      min: 1,
      max: ModelCatalogAdapter.max_source_version_bytes()
    )
    |> validate_provenance()
    |> validate_models()
    |> validate_expiry()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:connection_id)
    |> check_constraint(:status, name: :model_catalog_snapshots_status_check)
    |> check_constraint(:source, name: :model_catalog_snapshots_source_check)
    |> check_constraint(:expires_at, name: :model_catalog_snapshots_expiry_check)
    |> check_constraint(:models, name: :model_catalog_snapshots_models_check)
  end

  defp validate_models(changeset) do
    case get_field(changeset, :models) do
      %{"items" => items} = models when map_size(models) == 1 ->
        case ModelCatalogAdapter.validate_models(items) do
          {:ok, normalized} ->
            put_change(changeset, :models, %{"items" => encode_models(normalized)})

          {:error, _reason} ->
            add_error(changeset, :models, "is invalid")
        end

      _other ->
        add_error(changeset, :models, "is invalid")
    end
  end

  defp validate_provenance(changeset) do
    result =
      ModelCatalogAdapter.validate_provenance(
        get_field(changeset, :provider),
        get_field(changeset, :source),
        get_field(changeset, :source_method),
        get_field(changeset, :source_version)
      )

    case result do
      :ok -> changeset
      {:error, _reason} -> add_error(changeset, :source_version, "has invalid provenance")
    end
  end

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

  defp encode_models(models) do
    Enum.map(models, fn model ->
      %{
        "id" => model.id,
        "model" => model.model,
        "display_name" => model.display_name,
        "current" => model.current,
        "default" => model.default,
        "default_reasoning_effort" => model.default_reasoning_effort,
        "supported_reasoning_efforts" =>
          Enum.map(model.supported_reasoning_efforts, fn effort ->
            %{
              "reasoning_effort" => effort.reasoning_effort,
              "description" => effort.description
            }
          end)
      }
    end)
  end
end
