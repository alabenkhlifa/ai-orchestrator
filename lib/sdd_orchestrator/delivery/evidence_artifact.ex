defmodule SddOrchestrator.Delivery.EvidenceArtifact do
  @moduledoc """
  One immutable, digest-addressed artifact belonging to one hosted project.

  The bytes are the private part of an item of evidence: a screenshot, or a log
  too large to keep inline. They are encrypted at rest through
  `SddOrchestrator.Encrypted.Binary` and marked `redact: true`, so they never
  appear in an inspected struct, a log line, or a crash report.

  There is no URL column and no `updated_at`. An artifact is addressed by the
  digest of its own content within its own project, so the row is never
  rewritten: superseding one means storing different bytes under a different
  digest and leaving this one to retention.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Projects.Project

  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "evidence_artifacts" do
    field :digest, :string
    field :content_type, :string
    field :byte_size, :integer
    field :redacted, :boolean, default: false
    field :content, SddOrchestrator.Encrypted.Binary, redact: true

    belongs_to :project, Project

    timestamps()
  end

  @doc """
  Stores one artifact. There is deliberately no update changeset.

  The limits restated here are the same ones `ArtifactStore` already applied, so
  a console session or a future caller that bypasses the store still cannot
  write an artifact neither adapter would accept.
  """
  def store_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, [:project_id, :digest, :content_type, :byte_size, :redacted, :content])
    |> put_default_redacted()
    |> validate_required([:project_id, :digest, :content_type, :byte_size, :content])
    |> validate_format(:digest, @digest_pattern)
    |> validate_inclusion(:content_type, ArtifactStore.content_types())
    |> validate_number(:byte_size,
      greater_than: 0,
      less_than_or_equal_to: ArtifactStore.max_bytes()
    )
    |> unique_constraint([:project_id, :digest],
      name: :evidence_artifacts_project_id_digest_index
    )
    |> check_constraint(:digest, name: :evidence_artifacts_digest_format)
    |> check_constraint(:content_type, name: :evidence_artifacts_content_type_allowed)
    |> check_constraint(:byte_size, name: :evidence_artifacts_byte_size_bounded)
    |> foreign_key_constraint(:project_id)
  end

  defp put_default_redacted(changeset) do
    case get_field(changeset, :redacted) do
      nil -> put_change(changeset, :redacted, false)
      _present -> changeset
    end
  end
end
