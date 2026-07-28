defmodule SddOrchestrator.Portability.HostedLocalRepositoryBinding do
  @moduledoc """
  The minimum hosted routing record for one explicitly connected local repository.

  Project ownership, canonical repository identity, and device-workspace authority
  remain on their existing records. The binding stores only the project, the
  selected worker, and the time that worker last proved the exact project-held
  portable repository identity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:project_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @derive {Inspect, only: [:project_id, :last_validated_at]}

  @type t :: %__MODULE__{}

  schema "hosted_local_repository_bindings" do
    field :last_validated_at, :utc_datetime

    belongs_to :project, SddOrchestrator.Projects.Project,
      define_field: false,
      foreign_key: :project_id

    belongs_to :worker, SddOrchestrator.Devices.LocalWorker
  end

  @doc "Builds the exact minimized binding persisted after successful worker validation."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:project_id, :worker_id, :last_validated_at])
    |> validate_required([:project_id, :worker_id, :last_validated_at])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:worker_id)
    |> unique_constraint(:project_id, name: :hosted_local_repository_bindings_pkey)
  end
end
