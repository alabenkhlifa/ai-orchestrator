defmodule SddOrchestrator.RepositoryPilots.RepositoryPilotSelection do
  @moduledoc """
  One project's current pilot: a reference to one authoritative specification
  revision bound to one approved repository execution profile version.

  The record stores stable identifiers and one content digest only. It carries
  no specification title and no `requirements`, `design`, or `tasks` document,
  because a pilot points at the authoritative specification rather than becoming
  a second copy of it. Selecting a pilot imports no repository backlog item and
  writes nothing to the repository.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @fields [
    :id,
    :project_id,
    :profile_id,
    :profile_version,
    :specification_id,
    :revision_id,
    :revision_digest,
    :selected_by_actor_ref,
    :selected_at,
    :inserted_at
  ]

  @value_keys MapSet.new(Enum.map(@fields, &Atom.to_string/1))

  @type t :: %__MODULE__{}

  schema "repository_pilot_selections" do
    field :profile_version, :integer
    field :specification_id, :string
    field :revision_id, :string
    field :revision_digest, :string
    field :selected_by_actor_ref, :binary_id
    field :selected_at, :utc_datetime_usec

    belongs_to :project, SddOrchestrator.Projects.Project

    belongs_to :profile,
               SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfile

    timestamps()
  end

  @doc "Builds one validated pilot selection from resolved references only."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_pilot_selection}
  def new(attrs) when is_map(attrs) do
    selected_at = attrs |> Map.get(:selected_at) |> truncate()

    attrs
    |> Map.merge(%{
      id: Map.get(attrs, :id) || Ecto.UUID.generate(),
      selected_at: selected_at,
      inserted_at: selected_at
    })
    |> build()
  end

  def new(_attrs), do: {:error, :invalid_pilot_selection}

  @doc "Create-only changeset for the single current pilot of one project."
  @spec create_changeset(t()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = selection) do
    %__MODULE__{}
    |> changeset(Map.take(selection, @fields))
    |> unique_constraint(:project_id, name: :repository_pilot_selections_project_id_index)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:profile_id)
    |> check_constraint(:profile_version,
      name: :repository_pilot_selections_profile_version_positive
    )
  end

  @doc "Serializes the exact device-authoritative value without Ecto metadata."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = selection) do
    selection
    |> Map.take(@fields)
    |> Map.new(fn
      {key, %DateTime{} = value} -> {Atom.to_string(key), DateTime.to_iso8601(value)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  @doc "Restores only the exact stored device value, rejecting anything else."
  @spec from_value(term()) :: {:ok, t()} | {:error, :invalid_pilot_selection}
  def from_value(value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @value_keys,
         {:ok, selected_at, 0} <- DateTime.from_iso8601(value["selected_at"]),
         {:ok, inserted_at, 0} <- DateTime.from_iso8601(value["inserted_at"]) do
      value
      |> Map.new(fn {key, field_value} -> {String.to_existing_atom(key), field_value} end)
      |> Map.merge(%{selected_at: selected_at, inserted_at: inserted_at})
      |> build()
    else
      _invalid -> {:error, :invalid_pilot_selection}
    end
  rescue
    _error -> {:error, :invalid_pilot_selection}
  end

  def from_value(_value), do: {:error, :invalid_pilot_selection}

  defp build(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
    |> case do
      {:ok, selection} -> {:ok, selection}
      {:error, _changeset} -> {:error, :invalid_pilot_selection}
    end
  end

  defp changeset(selection, attrs) do
    selection
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_number(:profile_version, greater_than: 0)
    |> validate_length(:specification_id, max: 255, count: :bytes)
    |> validate_length(:revision_id, max: 255, count: :bytes)
    |> validate_format(:revision_digest, ~r/\A[0-9a-f]{64}\z/)
  end

  defp truncate(%DateTime{} = selected_at), do: DateTime.truncate(selected_at, :microsecond)
  defp truncate(other), do: other
end
