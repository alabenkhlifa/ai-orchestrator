defmodule SddOrchestrator.RepositoryInitialization.Plan do
  @moduledoc """
  One versioned, pre-project empty-repository initialization plan.

  `current_field` is a cursor through the product-first and
  technical-foundation question gate: `purpose -> users -> first_outcome ->
  constraints -> technical_foundation -> ready`. Only the current field may be
  answered; every accepted answer both advances the cursor and bumps
  `version` by one, so the version history is exactly the sequence of
  accepted answers. `target_reference` is an opaque token issued once
  eligibility succeeds — the real selected path never appears here.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @field_order ~w(purpose users first_outcome constraints technical_foundation ready)
  @answerable_fields ~w(purpose users first_outcome constraints technical_foundation)
  @eligibilities ~w(empty_directory unborn_repository)

  @field_atoms %{
    "purpose" => :purpose,
    "users" => :users,
    "first_outcome" => :first_outcome,
    "constraints" => :constraints,
    "technical_foundation" => :technical_foundation
  }

  @type t :: %__MODULE__{}

  schema "repository_initialization_plans" do
    field :device_workspace_id, :binary_id
    field :account_id, :binary_id
    field :target_reference, :string

    field :version, :integer, default: 1
    field :current_field, :string, default: "purpose"

    field :purpose, :string
    field :users, :string
    field :first_outcome, :string
    field :constraints, :string
    field :technical_foundation, :map, default: %{}

    field :eligibility, :string

    timestamps()
  end

  @doc """
  Changeset for a newly created plan, at version 1 with the cursor on
  `purpose` (the schema defaults for both apply unless `attrs` overrides them).
  """
  def create_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :device_workspace_id,
      :account_id,
      :target_reference,
      :eligibility,
      :version,
      :current_field
    ])
    |> validate_required([:device_workspace_id, :target_reference, :eligibility])
    |> validate_inclusion(:eligibility, @eligibilities)
    |> validate_inclusion(:current_field, @field_order)
    |> validate_length(:target_reference, min: 1, max: 255)
  end

  @doc "Changeset that accepts one answered field, advances the cursor, and bumps `version`."
  def answer_changeset(plan, attrs) do
    plan
    |> cast(attrs, Map.values(@field_atoms) ++ [:current_field, :version])
    |> validate_required([:current_field, :version])
    |> validate_inclusion(:current_field, @field_order)
  end

  @doc "The full cursor sequence, ending in the terminal `\"ready\"` value."
  def field_order, do: @field_order

  @doc "The fields a user may actually answer (excludes the terminal `\"ready\"` value)."
  def answerable_fields, do: @answerable_fields

  @doc "The schema field atom for one answerable field name."
  def field_atom(field) when field in @answerable_fields, do: Map.fetch!(@field_atoms, field)

  @doc "The next cursor value after `field`, or `nil` if `field` is already terminal."
  def next_field(field) do
    case Enum.find_index(@field_order, &(&1 == field)) do
      nil -> nil
      index -> Enum.at(@field_order, index + 1)
    end
  end
end
