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

  Once the cursor reaches `"ready"`, Task 3's review and confirmation fields
  apply: `kit_choice` (the permanent SDD kit is proposed by default, `nil`
  package fields when declined or unavailable), `disclosure_version` (the
  processing-boundary disclosure, AC-05), and `confirmed_at`/
  `confirmation_digest` (the exact-plan confirmation binding, AC-06/AC-07).
  Any kit-choice change always clears `confirmed_at`/`confirmation_digest` —
  a changed bound input invalidates a prior confirmation.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @field_order ~w(purpose users first_outcome constraints technical_foundation ready)
  @answerable_fields ~w(purpose users first_outcome constraints technical_foundation)
  @eligibilities ~w(empty_directory unborn_repository)
  @kit_choices ~w(included declined)
  @confirmation_digest_format ~r/\A[0-9a-f]{64}\z/

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

    field :kit_choice, :string, default: "included"
    field :kit_package_id, :binary_id
    field :kit_package_digest, :string
    field :disclosure_version, :integer
    field :confirmed_at, :utc_datetime
    field :confirmation_digest, :string

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

  @doc """
  Changeset that records the reviewed plan's kit choice.

  Always writes `confirmed_at`/`confirmation_digest` (both `nil` unless the
  caller explicitly re-supplies them, which `RepositoryInitialization` never
  does) so a kit-choice change always invalidates any prior confirmation.
  """
  def kit_choice_changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :kit_choice,
      :kit_package_id,
      :kit_package_digest,
      :confirmed_at,
      :confirmation_digest
    ])
    |> validate_required([:kit_choice])
    |> validate_inclusion(:kit_choice, @kit_choices)
  end

  @doc "Changeset that records the processing-boundary disclosure version (AC-05)."
  def disclosure_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:disclosure_version])
    |> validate_required([:disclosure_version])
    |> validate_number(:disclosure_version, greater_than: 0)
  end

  @doc "Changeset that records one exact-plan confirmation (AC-06/AC-07)."
  def confirm_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:confirmed_at, :confirmation_digest])
    |> validate_required([:confirmed_at, :confirmation_digest])
    |> validate_format(:confirmation_digest, @confirmation_digest_format)
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
