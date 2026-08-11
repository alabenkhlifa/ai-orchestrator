defmodule SddOrchestrator.RepositoryKits.RepositoryKitPackage do
  @moduledoc """
  One immutable, globally catalogued SDD kit package version.

  A package is content-addressed by a digest computed over its vendored file
  manifest and identified by source, publisher, and semantic version. It
  carries complete provenance bound to one exact commit (never a mutable
  branch or tag reference), license, the vendored file manifest, referenced
  scripts, supported agent adapters, and required permissions. Catalog data
  is global, not project-scoped: there is no `project_id`. Only a create-only
  changeset is exposed here; there is no update changeset, and the database
  additionally rejects any `UPDATE` through an immutability trigger.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @adapters ~w(claude_code codex)
  @commit_ref_format ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @digest_format ~r/\A[0-9a-f]{64}\z/
  @provenance_keys MapSet.new(["ref_type", "ref", "repository"])

  @fields [
    :id,
    :source,
    :publisher,
    :version,
    :digest,
    :license,
    :provenance,
    :file_manifest,
    :supported_adapters,
    :required_permissions,
    :scripts
  ]

  @required_fields [
    :id,
    :source,
    :publisher,
    :version,
    :digest,
    :license,
    :provenance,
    :file_manifest,
    :supported_adapters
  ]

  @type t :: %__MODULE__{}

  schema "repository_kit_packages" do
    field :source, :string
    field :publisher, :string
    field :version, :string
    field :digest, :string
    field :license, :string
    field :provenance, :map
    field :file_manifest, :map
    field :supported_adapters, {:array, :string}
    field :required_permissions, {:array, :string}, default: []
    field :scripts, {:array, :string}, default: []

    timestamps()
  end

  @doc """
  Computes the package content digest.

  The digest is `sha256`, hex-encoded lowercase, of the canonical JSON
  encoding of `file_manifest["files"]` sorted by `"path"`, where each file
  contributes exactly the 4-element array `[path, sha256, size, executable]`
  in that field order — never the raw base64 `content` itself. Hashing the
  already-computed per-file `sha256` (instead of the content blob) keeps
  digest computation cheap while still detecting any tamper to path, content,
  size, or executable bit, and recomputing it from a stored manifest always
  reproduces the same value for the same file set.
  """
  @spec digest_of(map()) :: String.t()
  def digest_of(%{"files" => files}) when is_list(files) do
    files
    |> Enum.sort_by(& &1["path"])
    |> Enum.map(fn file -> [file["path"], file["sha256"], file["size"], file["executable"]] end)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Create-only changeset validating one immutable package publication."
  @spec publish_changeset(t(), map()) :: Ecto.Changeset.t()
  def publish_changeset(%__MODULE__{} = package, attrs) do
    changeset =
      package
      |> cast(attrs, @fields)
      |> validate_required(@required_fields)
      |> validate_length(:source, max: 255, count: :bytes)
      |> validate_length(:publisher, max: 255, count: :bytes)
      |> validate_length(:license, max: 255, count: :bytes)
      |> validate_change(:version, &validate_semver/2)
      |> validate_format(:digest, @digest_format)
      |> validate_change(:provenance, &validate_provenance/2)
      |> validate_change(:supported_adapters, &validate_adapters/2)
      |> validate_change(:required_permissions, &validate_bounded_unique_strings/2)
      |> validate_change(:scripts, &validate_bounded_unique_strings/2)

    changeset
    |> validate_change(:scripts, fn :scripts, scripts ->
      validate_scripts_against_manifest(scripts, get_field(changeset, :file_manifest))
    end)
    |> check_constraint(:digest, name: :repository_kit_packages_digest_shape)
    |> check_constraint(:provenance, name: :repository_kit_packages_provenance_shape)
    |> unique_constraint(:digest, name: :repository_kit_packages_digest_index)
    |> unique_constraint([:source, :publisher, :version],
      name: :repository_kit_packages_source_publisher_version_index
    )
  end

  defp validate_semver(:version, value) do
    case Version.parse(value) do
      {:ok, _version} -> []
      :error -> [version: "must be a valid semantic version"]
    end
  end

  defp validate_provenance(:provenance, value) when is_map(value) do
    with true <- MapSet.new(Map.keys(value)) == @provenance_keys,
         true <- value["ref_type"] == "commit",
         ref when is_binary(ref) <- value["ref"],
         true <- Regex.match?(@commit_ref_format, ref),
         repository when is_binary(repository) <- value["repository"],
         true <- byte_size(repository) in 1..1024 do
      []
    else
      _invalid ->
        [
          provenance:
            "must have exactly ref_type \"commit\", an exact commit ref, and a repository"
        ]
    end
  end

  defp validate_provenance(:provenance, _value),
    do: [provenance: "must be a map with ref_type, ref, and repository"]

  defp validate_adapters(:supported_adapters, value) when is_list(value) do
    with true <- value != [],
         true <- Enum.all?(value, &(&1 in @adapters)),
         true <- Enum.uniq(value) == value do
      []
    else
      _invalid ->
        [
          supported_adapters:
            "must be a non-empty, duplicate-free subset of #{Enum.join(@adapters, ", ")}"
        ]
    end
  end

  defp validate_adapters(:supported_adapters, _value),
    do: [supported_adapters: "must be a list"]

  defp validate_bounded_unique_strings(field, value) when is_list(value) do
    with true <- Enum.all?(value, &(is_binary(&1) and byte_size(&1) in 1..255)),
         true <- Enum.uniq(value) == value do
      []
    else
      _invalid -> [{field, "must be a list of unique bounded strings"}]
    end
  end

  defp validate_bounded_unique_strings(field, _value), do: [{field, "must be a list"}]

  defp validate_scripts_against_manifest([], _file_manifest), do: []

  defp validate_scripts_against_manifest(scripts, %{"files" => files}) when is_list(files) do
    executable_paths =
      files
      |> Enum.filter(&(&1["executable"] == true))
      |> Enum.map(& &1["path"])
      |> MapSet.new()

    if Enum.all?(scripts, &MapSet.member?(executable_paths, &1)) do
      []
    else
      [scripts: "must reference only executable files present in the file manifest"]
    end
  end

  defp validate_scripts_against_manifest(_scripts, _file_manifest),
    do: [scripts: "must reference only executable files present in the file manifest"]
end
