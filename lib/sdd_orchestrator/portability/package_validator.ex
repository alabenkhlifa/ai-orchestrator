defmodule SddOrchestrator.Portability.PackageValidator do
  @moduledoc """
  Compatibility, structure, and resource validation for untrusted packages.

  Validation is pure data handling: no path is opened, no attachment is
  extracted, and no package value is executed or interpreted as a command.
  """

  alias SddOrchestrator.Devices.PortableRepositoryIdentity

  alias SddOrchestrator.Portability.{
    PackageCodec,
    PackageEncryption,
    PackageSection,
    PayloadPolicy,
    ProjectPackage
  }

  @format "sdd-orchestrator-project-package"
  @supported_major 1
  @compression "deflate"
  @encryption "aes-256-gcm"
  @kdf "argon2id"
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16

  @type error ::
          :package_too_large
          | :unsupported_version
          | :malformed_package
          | :unsafe_package
          | :invalid_package_or_passphrase

  @spec decrypt_and_validate(binary(), String.t()) ::
          {:ok, ProjectPackage.t()} | {:error, error()}
  def decrypt_and_validate(encrypted_package, passphrase) do
    with :ok <- validate_encrypted_container(encrypted_package),
         {:ok, package} <-
           PackageEncryption.decrypt(
             encrypted_package,
             passphrase,
             max_decompressed_bytes: limit(:max_decompressed_bytes),
             max_expansion_ratio: limit(:max_expansion_ratio)
           ),
         :ok <- validate(package) do
      {:ok, package}
    else
      {:error, reason}
      when reason in [
             :package_too_large,
             :unsupported_version,
             :malformed_package,
             :unsafe_package
           ] ->
        {:error, reason}

      _reason ->
        {:error, :invalid_package_or_passphrase}
    end
  end

  @spec validate_encrypted_container(binary()) :: :ok | {:error, error()}
  def validate_encrypted_container(package) when is_binary(package) do
    if byte_size(package) > limit(:max_encrypted_package_bytes),
      do: {:error, :package_too_large},
      else: validate_envelope(package)
  end

  def validate_encrypted_container(_package), do: {:error, :malformed_package}

  @spec validate(ProjectPackage.t()) :: :ok | {:error, :unsafe_package}
  def validate(%ProjectPackage{} = package) do
    with :ok <- PayloadPolicy.validate(package),
         :ok <- validate_project(package.project),
         :ok <- validate_repository(package.repository),
         :ok <- validate_specifications(package.specifications) do
      :ok
    else
      _reason -> {:error, :unsafe_package}
    end
  end

  def validate(_package), do: {:error, :unsafe_package}

  defp validate_envelope(package) do
    case PackageCodec.unframe(package) do
      {:ok,
       %{
         "body_length" => body_length,
         "compression" => @compression,
         "encryption" => @encryption,
         "format" => @format,
         "format_version" => @supported_major,
         "kdf" => @kdf,
         "kdf_memory_kib" => memory_kib,
         "kdf_parallelism" => parallelism,
         "kdf_time_cost" => time_cost,
         "nonce" => nonce,
         "payload_schema_version" => @supported_major,
         "salt" => salt,
         "tag_length" => @tag_bytes
       }, body} ->
        validate_encryption_parameters(
          body_length,
          body,
          time_cost,
          memory_kib,
          parallelism,
          salt,
          nonce
        )

      {:ok,
       %{
         "format" => @format,
         "format_version" => format_version,
         "payload_schema_version" => payload_version
       }, _body}
      when format_version != @supported_major or payload_version != @supported_major ->
        {:error, :unsupported_version}

      {:ok, _envelope, _body} ->
        {:error, :malformed_package}

      {:error, _reason} ->
        {:error, :malformed_package}
    end
  end

  defp validate_encryption_parameters(
         body_length,
         body,
         time_cost,
         memory_kib,
         parallelism,
         salt,
         nonce
       ) do
    with :ok <-
           validate_encryption_shape(
             body_length,
             body,
             time_cost,
             memory_kib,
             parallelism,
             salt,
             nonce
           ),
         :ok <- validate_kdf_limits(time_cost, memory_kib, parallelism),
         :ok <- validate_encoded_material(salt, nonce) do
      :ok
    else
      _reason -> {:error, :malformed_package}
    end
  end

  defp validate_encryption_shape(
         body_length,
         body,
         time_cost,
         memory_kib,
         parallelism,
         salt,
         nonce
       ) do
    with :ok <- validate_body_shape(body_length, body),
         :ok <- validate_positive_kdf_value(time_cost),
         :ok <- validate_memory_shape(memory_kib),
         :ok <- validate_positive_kdf_value(parallelism),
         true <- is_binary(salt) and is_binary(nonce) do
      :ok
    else
      _reason -> {:error, :invalid_encryption_shape}
    end
  end

  defp validate_body_shape(body_length, body)
       when is_integer(body_length) and is_binary(body) and body_length == byte_size(body),
       do: :ok

  defp validate_body_shape(_body_length, _body), do: {:error, :invalid_body}

  defp validate_positive_kdf_value(value) when is_integer(value) and value > 0, do: :ok
  defp validate_positive_kdf_value(_value), do: {:error, :invalid_kdf_value}

  defp validate_memory_shape(memory_kib) when is_integer(memory_kib) and memory_kib >= 8, do: :ok
  defp validate_memory_shape(_memory_kib), do: {:error, :invalid_memory}

  defp validate_kdf_limits(time_cost, memory_kib, parallelism) do
    if time_cost <= limit(:max_kdf_time_cost) and
         memory_kib <= limit(:max_kdf_memory_kib) and
         parallelism <= limit(:max_kdf_parallelism),
       do: :ok,
       else: {:error, :unsafe_kdf_parameters}
  end

  defp validate_encoded_material(salt, nonce) do
    with {:ok, decoded_salt} <- Base.decode64(salt),
         true <- byte_size(decoded_salt) == @salt_bytes,
         {:ok, decoded_nonce} <- Base.decode64(nonce),
         true <- byte_size(decoded_nonce) == @nonce_bytes do
      :ok
    else
      _reason -> {:error, :invalid_encryption_material}
    end
  end

  defp validate_project(%PackageSection{
         version: @supported_major,
         content: %{"id" => id, "name" => name}
       }) do
    case Ecto.UUID.cast(id) do
      {:ok, _id} -> bounded_string(name, :max_project_name_bytes)
      :error -> {:error, :invalid_project}
    end
  end

  defp validate_project(_project), do: {:error, :invalid_project}

  defp validate_repository(%PackageSection{
         version: @supported_major,
         content: %{"provider" => provider, "repository_id" => repository_id}
       }) do
    with true <- provider in ["github", "local"],
         :ok <- bounded_string(provider, :max_provider_bytes),
         :ok <- bounded_string(repository_id, :max_repository_id_bytes),
         :ok <- validate_repository_identity(provider, repository_id) do
      :ok
    else
      _reason -> {:error, :invalid_repository}
    end
  end

  defp validate_repository(_repository), do: {:error, :invalid_repository}

  defp validate_repository_identity("github", _repository_id), do: :ok

  defp validate_repository_identity("local", repository_id) do
    case PortableRepositoryIdentity.parse(repository_id) do
      {:ok, _portable} -> :ok
      {:error, _legacy_or_invalid} -> {:error, :invalid_repository_identity}
    end
  end

  defp validate_specifications(%PackageSection{
         version: @supported_major,
         content: specifications
       })
       when is_list(specifications) do
    with true <- length(specifications) <= limit(:max_specifications),
         :ok <- unique_specification_ids(specifications) do
      validate_specification_list(specifications)
    else
      _reason -> {:error, :invalid_specifications}
    end
  end

  defp validate_specifications(_specifications), do: {:error, :invalid_specifications}

  defp validate_specification_list(specifications) do
    Enum.reduce_while(specifications, :ok, fn specification, :ok ->
      case validate_specification(specification) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_specification(%{
         "id" => id,
         "title" => title,
         "requirements" => requirements,
         "design" => design,
         "tasks" => tasks
       }) do
    case Ecto.UUID.cast(id) do
      {:ok, _id} ->
        validate_specification_fields(id, title, requirements, design, tasks)

      :error ->
        {:error, :invalid_specification}
    end
  end

  defp validate_specification(_specification), do: {:error, :invalid_specification}

  defp validate_specification_fields(id, title, requirements, design, tasks) do
    with :ok <- bounded_string(id, :max_specification_id_bytes),
         :ok <- bounded_string(title, :max_specification_title_bytes),
         :ok <- bounded_string(requirements, :max_document_bytes),
         :ok <- bounded_string(design, :max_document_bytes) do
      bounded_string(tasks, :max_document_bytes)
    end
  end

  defp unique_specification_ids(specifications) do
    ids = Enum.map(specifications, &Map.get(&1, "id"))
    if length(ids) == MapSet.size(MapSet.new(ids)), do: :ok, else: {:error, :duplicate_identity}
  end

  defp bounded_string(value, limit_name) when is_binary(value) and value != "" do
    if byte_size(value) <= limit(limit_name), do: :ok, else: {:error, :field_too_large}
  end

  defp bounded_string(_value, _limit_name), do: {:error, :invalid_field}

  defp limit(name) do
    :sdd_orchestrator
    |> Application.fetch_env!(:portability_limits)
    |> Keyword.fetch!(name)
  end
end
