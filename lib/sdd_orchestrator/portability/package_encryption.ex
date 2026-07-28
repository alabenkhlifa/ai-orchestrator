defmodule SddOrchestrator.Portability.PackageEncryption do
  @moduledoc """
  Argon2id and AES-256-GCM package confidentiality boundary.

  Passphrases and derived keys exist only in the current function call. Neither
  is returned, persisted, logged, or included in the authenticated envelope.
  """

  import Bitwise

  alias SddOrchestrator.Portability.{PackageCodec, PayloadPolicy, ProjectPackage}

  @format "sdd-orchestrator-project-package"
  @format_version 1
  @payload_schema_version 1
  @encryption "aes-256-gcm"
  @kdf "argon2id"
  @compression "deflate"
  @salt_bytes 16
  @nonce_bytes 12
  @tag_bytes 16
  @key_bytes 32

  @opaque_error {:error, :invalid_package_or_passphrase}

  @spec encrypt(ProjectPackage.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, atom()}
  def encrypt(%ProjectPackage{} = package, passphrase, opts \\ []) do
    with :ok <- validate_passphrase(passphrase),
         :ok <- PayloadPolicy.validate(package),
         {:ok, payload} <- PackageCodec.encode_payload(package),
         {:ok, compressed} <- PackageCodec.compress(payload),
         {:ok, parameters} <- parameters(opts),
         {:ok, salt} <- encryption_material(opts, :salt, @salt_bytes),
         {:ok, nonce} <- encryption_material(opts, :nonce, @nonce_bytes),
         {:ok, key} <- derive_key(passphrase, salt, parameters),
         envelope <- envelope(byte_size(compressed) + @tag_bytes, salt, nonce, parameters),
         {:ok, aad} <- PackageCodec.encode_envelope(envelope),
         {ciphertext, tag} <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             compressed,
             aad,
             @tag_bytes,
             true
           ) do
      PackageCodec.frame(envelope, ciphertext <> tag)
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :encryption_failed}
  end

  @spec decrypt(binary(), String.t(), keyword()) ::
          {:ok, ProjectPackage.t()} | {:error, :invalid_package_or_passphrase}
  def decrypt(package_file, passphrase, opts \\ [])

  def decrypt(package_file, passphrase, opts)
      when is_binary(package_file) and is_binary(passphrase) and passphrase != "" do
    with {:ok, envelope, body} <- PackageCodec.unframe(package_file),
         {:ok, parameters, salt, nonce} <- decode_envelope(envelope),
         {:ok, key} <- derive_key(passphrase, salt, parameters),
         {:ok, ciphertext, tag} <- split_ciphertext(body),
         {:ok, aad} <- PackageCodec.encode_envelope(envelope),
         compressed when is_binary(compressed) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad,
             tag,
             false
           ),
         {:ok, payload} <-
           PackageCodec.decompress(
             compressed,
             Keyword.get(
               opts,
               :max_decompressed_bytes,
               configured(:max_decompressed_bytes)
             ),
             Keyword.get(
               opts,
               :max_expansion_ratio,
               configured(:max_expansion_ratio)
             )
           ),
         {:ok, project_package} <- PackageCodec.decode_payload(payload),
         :ok <- PayloadPolicy.validate(project_package) do
      {:ok, project_package}
    else
      {:error, reason}
      when reason in [
             :decompressed_size_exceeded,
             :expansion_ratio_exceeded,
             :invalid_compressed_payload,
             :invalid_json,
             :duplicate_json_key,
             :prohibited_payload_content,
             :invalid_payload,
             :invalid_section,
             :forbidden_payload_field,
             :secret_detected
           ] ->
        {:error, :unsafe_package}

      _reason ->
        @opaque_error
    end
  rescue
    _error -> @opaque_error
  catch
    _kind, _reason -> @opaque_error
  end

  def decrypt(_package_file, _passphrase, _opts), do: @opaque_error

  defp parameters(opts) do
    parameters = %{
      time_cost: Keyword.get(opts, :time_cost, configured(:time_cost)),
      memory_kib: Keyword.get(opts, :memory_kib, configured(:memory_kib)),
      parallelism: Keyword.get(opts, :parallelism, configured(:parallelism))
    }

    with true <- is_integer(parameters.time_cost) and parameters.time_cost > 0,
         true <- is_integer(parameters.memory_kib) and parameters.memory_kib >= 8,
         true <- is_integer(parameters.parallelism) and parameters.parallelism > 0,
         {:ok, _memory_exponent} <- memory_exponent(parameters.memory_kib) do
      {:ok, parameters}
    else
      _reason -> {:error, :invalid_encryption_parameters}
    end
  end

  defp derive_key(passphrase, salt, parameters) do
    with {:ok, memory_cost} <- memory_exponent(parameters.memory_kib) do
      raw_hex =
        Argon2.Base.hash_password(
          passphrase,
          salt,
          t_cost: parameters.time_cost,
          m_cost: memory_cost,
          parallelism: parameters.parallelism,
          format: :raw_hash,
          hashlen: @key_bytes,
          argon2_type: 2
        )

      case Base.decode16(raw_hex, case: :mixed) do
        {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
        _invalid -> {:error, :key_derivation_failed}
      end
    end
  rescue
    _error -> {:error, :key_derivation_failed}
  end

  defp memory_exponent(memory_kib) do
    exponent = memory_kib |> :math.log2() |> round()

    if 1 <<< exponent == memory_kib,
      do: {:ok, exponent},
      else: {:error, :invalid_memory_cost}
  end

  defp envelope(body_length, salt, nonce, parameters) do
    %{
      "body_length" => body_length,
      "compression" => @compression,
      "encryption" => @encryption,
      "format" => @format,
      "format_version" => @format_version,
      "kdf" => @kdf,
      "kdf_memory_kib" => parameters.memory_kib,
      "kdf_parallelism" => parameters.parallelism,
      "kdf_time_cost" => parameters.time_cost,
      "nonce" => Base.encode64(nonce),
      "payload_schema_version" => @payload_schema_version,
      "salt" => Base.encode64(salt),
      "tag_length" => @tag_bytes
    }
  end

  defp decode_envelope(
         %{
           "body_length" => body_length,
           "compression" => @compression,
           "encryption" => @encryption,
           "format" => @format,
           "format_version" => @format_version,
           "kdf" => @kdf,
           "kdf_memory_kib" => memory_kib,
           "kdf_parallelism" => parallelism,
           "kdf_time_cost" => time_cost,
           "nonce" => nonce,
           "payload_schema_version" => @payload_schema_version,
           "salt" => salt,
           "tag_length" => @tag_bytes
         } = envelope
       )
       when is_integer(body_length) and body_length >= @tag_bytes and
              is_map(envelope) do
    with {:ok, parameters} <-
           parameters(
             time_cost: time_cost,
             memory_kib: memory_kib,
             parallelism: parallelism
           ),
         {:ok, decoded_salt} <- Base.decode64(salt),
         true <- byte_size(decoded_salt) == @salt_bytes,
         {:ok, decoded_nonce} <- Base.decode64(nonce),
         true <- byte_size(decoded_nonce) == @nonce_bytes do
      {:ok, parameters, decoded_salt, decoded_nonce}
    else
      _reason -> {:error, :invalid_envelope}
    end
  end

  defp decode_envelope(_envelope), do: {:error, :invalid_envelope}

  defp split_ciphertext(body) when byte_size(body) >= @tag_bytes do
    ciphertext_size = byte_size(body) - @tag_bytes
    <<ciphertext::binary-size(^ciphertext_size), tag::binary-size(@tag_bytes)>> = body
    {:ok, ciphertext, tag}
  end

  defp split_ciphertext(_body), do: {:error, :invalid_ciphertext}

  defp validate_passphrase(passphrase) when is_binary(passphrase) and passphrase != "", do: :ok
  defp validate_passphrase(_passphrase), do: {:error, :passphrase_required}

  defp encryption_material(opts, key, size) do
    case Keyword.get(opts, key) do
      nil -> {:ok, :crypto.strong_rand_bytes(size)}
      value when is_binary(value) and byte_size(value) == size -> {:ok, value}
      _value -> {:error, :invalid_encryption_parameters}
    end
  end

  defp configured(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:package_encryption)
    |> Keyword.fetch!(key)
  end
end
