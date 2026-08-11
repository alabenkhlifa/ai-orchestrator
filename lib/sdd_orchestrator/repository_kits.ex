defmodule SddOrchestrator.RepositoryKits do
  @moduledoc """
  Global, immutable catalog of vendored SDD kit packages.

  A package is inspectable, versioned, and content-addressed. Publication is
  in-memory ingestion only: `publish_package/2` performs no disk or network
  I/O and never executes package content — reading files off disk is the
  `mix repository_kits.publish` task's job. The catalog is global rather than
  project-scoped, so every function here takes no project or account
  authority; any authenticated participant may read it, and the LiveView
  route enforces the authentication boundary.
  """

  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryKits.RepositoryKitPackage

  @max_files 500
  @max_file_bytes 512_000
  @max_package_bytes 5_000_000

  @package_attrs [
    :source,
    :publisher,
    :version,
    :license,
    :provenance,
    :supported_adapters,
    :required_permissions,
    :scripts
  ]

  @field_error_priority [
    {:source, :invalid_source},
    {:publisher, :invalid_publisher},
    {:version, :invalid_version},
    {:license, :invalid_license},
    {:digest, :invalid_digest},
    {:provenance, :invalid_provenance},
    {:supported_adapters, :invalid_adapters},
    {:required_permissions, :invalid_permissions},
    {:scripts, :invalid_scripts}
  ]

  @type file_input :: %{path: binary(), content: binary(), executable: boolean()}

  @doc """
  Publishes one immutable kit package from already-read attrs and files.

  `attrs` carries only in-memory scalar and structural fields; `files` carries
  already-read file bytes. Neither this function nor anything it calls
  touches disk or the network, and package content is never executed — it is
  only measured, hashed, and base64-encoded.
  """
  @spec publish_package(map(), [file_input()]) ::
          {:ok, RepositoryKitPackage.t()} | {:error, atom()}
  def publish_package(attrs, files) when is_map(attrs) and is_list(files) do
    with :ok <- validate_files(files) do
      file_manifest = build_file_manifest(files)
      digest = RepositoryKitPackage.digest_of(file_manifest)

      package_attrs =
        attrs
        |> Map.take(@package_attrs)
        |> normalize_provenance()
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:digest, digest)
        |> Map.put(:file_manifest, file_manifest)

      %RepositoryKitPackage{}
      |> RepositoryKitPackage.publish_changeset(package_attrs)
      |> Repo.insert()
      |> case do
        {:ok, package} -> {:ok, package}
        {:error, changeset} -> {:error, error_atom(changeset)}
      end
    end
  end

  def publish_package(_attrs, _files), do: {:error, :invalid_request}

  @doc "Reads one package by id."
  @spec get_package(Ecto.UUID.t()) :: {:ok, RepositoryKitPackage.t()} | {:error, :not_found}
  def get_package(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found_or_not_found(Repo.get(RepositoryKitPackage, uuid))
      :error -> {:error, :not_found}
    end
  end

  def get_package(_id), do: {:error, :not_found}

  @doc "Reads one package by its exact content digest."
  @spec get_by_digest(String.t()) :: {:ok, RepositoryKitPackage.t()} | {:error, :not_found}
  def get_by_digest(digest) when is_binary(digest) do
    found_or_not_found(Repo.get_by(RepositoryKitPackage, digest: digest))
  end

  def get_by_digest(_digest), do: {:error, :not_found}

  @doc "Lists every package ordered by source, publisher, then real semver."
  @spec list_packages() :: [RepositoryKitPackage.t()]
  def list_packages do
    RepositoryKitPackage
    |> Repo.all()
    |> Enum.sort(&package_lte?/2)
  end

  @doc """
  Returns the newest other package sharing this package's `source` and
  `publisher` whose version compares strictly greater, or `nil`.

  Supersession is always derived at read time from the immutable catalog; no
  row is ever mutated or linked to record it.
  """
  @spec superseded_by(RepositoryKitPackage.t(), [RepositoryKitPackage.t()]) ::
          RepositoryKitPackage.t() | nil
  def superseded_by(%RepositoryKitPackage{} = package, all_packages \\ list_packages()) do
    all_packages
    |> Enum.filter(fn candidate ->
      candidate.id != package.id and candidate.source == package.source and
        candidate.publisher == package.publisher and
        Version.compare(candidate.version, package.version) == :gt
    end)
    |> Enum.reduce(nil, &newest/2)
  end

  ## Attrs normalization (pure, no I/O)

  # Provenance is always stored (and read back from jsonb) with string keys.
  # Callers such as the mix task naturally build it with atom keys, so this
  # normalizes either shape to one canonical stored representation.
  defp normalize_provenance(attrs) do
    case Map.fetch(attrs, :provenance) do
      {:ok, %{} = provenance} ->
        Map.put(attrs, :provenance, Map.new(provenance, fn {k, v} -> {to_string(k), v} end))

      _other ->
        attrs
    end
  end

  ## File validation (pure, no I/O)

  defp validate_files([]), do: {:error, :no_files}

  defp validate_files(files) when length(files) > @max_files, do: {:error, :too_many_files}

  defp validate_files(files) do
    Enum.reduce_while(files, {:ok, MapSet.new(), 0}, fn file, {:ok, seen_paths, total_size} ->
      with {:ok, path} <- validate_path(Map.get(file, :path)),
           :ok <- ensure_unique_path(path, seen_paths),
           {:ok, content} <- validate_content(Map.get(file, :content)) do
        {:cont, {:ok, MapSet.put(seen_paths, path), total_size + byte_size(content)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _paths, total_size} when total_size > @max_package_bytes ->
        {:error, :package_too_large}

      {:ok, _paths, _total_size} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      byte_size(path) > 255 -> {:error, :invalid_path}
      String.starts_with?(path, "/") -> {:error, :invalid_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      ".." in Path.split(path) -> {:error, :path_escape}
      true -> {:ok, path}
    end
  end

  defp validate_path(_path), do: {:error, :invalid_path}

  defp ensure_unique_path(path, seen_paths) do
    if MapSet.member?(seen_paths, path), do: {:error, :duplicate_path}, else: :ok
  end

  defp validate_content(content) when is_binary(content) do
    if byte_size(content) > @max_file_bytes,
      do: {:error, :file_too_large},
      else: {:ok, content}
  end

  defp validate_content(_content), do: {:error, :invalid_path}

  defp build_file_manifest(files) do
    built =
      Enum.map(files, fn %{path: path, content: content, executable: executable} ->
        %{
          "path" => path,
          "content" => Base.encode64(content),
          "sha256" => content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
          "size" => byte_size(content),
          "executable" => !!executable
        }
      end)

    %{"files" => built}
  end

  ## Ordering and supersession

  defp package_lte?(a, b) do
    cond do
      a.source != b.source -> a.source < b.source
      a.publisher != b.publisher -> a.publisher < b.publisher
      true -> Version.compare(a.version, b.version) != :gt
    end
  end

  defp newest(candidate, nil), do: candidate

  defp newest(candidate, current) do
    if Version.compare(candidate.version, current.version) == :gt, do: candidate, else: current
  end

  ## Error mapping

  defp found_or_not_found(nil), do: {:error, :not_found}
  defp found_or_not_found(package), do: {:ok, package}

  defp error_atom(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end) do
      :already_exists
    else
      error_atom_for_field(errors)
    end
  end

  defp error_atom_for_field(errors) do
    Enum.find_value(@field_error_priority, :invalid_package, fn {field, atom} ->
      if Keyword.has_key?(errors, field), do: atom
    end)
  end
end
