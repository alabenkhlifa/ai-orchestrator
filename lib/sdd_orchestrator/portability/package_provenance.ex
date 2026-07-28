defmodule SddOrchestrator.Portability.PackageProvenance do
  @moduledoc """
  Minimal project-bound evidence that a project was restored.

  The project identity is the primary and foreign key. Beyond that association,
  provenance stores only the package payload schema version and restoration
  time—never a package hash, filename, source identity, workspace, device,
  exporter, network value, or source storage mode.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "package_provenances" do
    field :payload_schema_version, :integer
    field :restored_at, :utc_datetime

    belongs_to :project, SddOrchestrator.Projects.Project,
      define_field: false,
      foreign_key: :project_id
  end

  @doc "Builds the minimal provenance inserted in the project restore transaction."
  def create_changeset(provenance, attrs) do
    provenance
    |> cast(attrs, [:project_id, :payload_schema_version, :restored_at])
    |> validate_required([:project_id, :payload_schema_version, :restored_at])
    |> validate_number(:payload_schema_version, greater_than: 0)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:project_id, name: :package_provenances_pkey)
    |> check_constraint(:payload_schema_version,
      name: :package_provenances_schema_version_positive
    )
  end
end
