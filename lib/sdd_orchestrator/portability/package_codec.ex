defmodule SddOrchestrator.Portability.PackageCodec do
  @moduledoc """
  Deterministic JSON, DEFLATE, and single-file framing for project packages.

  Encryption is intentionally outside this module. The later cryptographic
  boundary can authenticate the canonical envelope bytes and frame ciphertext
  with the same container primitives.
  """

  alias Jason.OrderedObject
  alias SddOrchestrator.Portability.{PackageSection, ProjectPackage}

  @magic "SDDPKG\r\n"
  @format "sdd-orchestrator-project-package"
  @format_version 1
  @payload_schema_version 1
  @section_version 1
  @compression "deflate"
  @max_header_bytes 16_384

  @type envelope :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @spec section_version() :: pos_integer()
  def section_version, do: @section_version

  @spec encode(ProjectPackage.t()) :: {:ok, binary()} | {:error, atom()}
  def encode(%ProjectPackage{} = package) do
    with {:ok, payload} <- encode_payload(package),
         {:ok, compressed} <- compress(payload) do
      envelope = default_envelope(byte_size(compressed), package.payload_schema_version)
      frame(envelope, compressed)
    end
  end

  @spec decode(binary(), keyword()) :: {:ok, ProjectPackage.t()} | {:error, atom()}
  def decode(package, opts \\ []) when is_binary(package) do
    max_decompressed_bytes = Keyword.get(opts, :max_decompressed_bytes, 16 * 1_024 * 1_024)

    with {:ok, envelope, compressed} <- unframe(package),
         :ok <- validate_default_envelope(envelope, byte_size(compressed)),
         {:ok, payload} <- decompress(compressed, max_decompressed_bytes) do
      decode_payload(payload)
    end
  end

  @spec encode_payload(ProjectPackage.t()) :: {:ok, binary()} | {:error, atom()}
  def encode_payload(%ProjectPackage{} = package) do
    with :ok <- validate_package(package),
         {:ok, canonical} <- canonical_object(payload_map(package)) do
      case Jason.encode(canonical, maps: :strict) do
        {:ok, json} -> {:ok, json}
        {:error, _reason} -> {:error, :invalid_payload}
      end
    end
  end

  @spec decode_payload(binary()) :: {:ok, ProjectPackage.t()} | {:error, atom()}
  def decode_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- decode_json(payload),
         {:ok, sections} <- fetch_payload_sections(decoded),
         {:ok, project} <- decode_section(Enum.at(sections, 0), :project),
         {:ok, repository} <- decode_section(Enum.at(sections, 1), :repository),
         {:ok, specifications} <- decode_section(Enum.at(sections, 2), :specifications) do
      ProjectPackage.new(project, repository, specifications)
    end
  end

  @spec compress(binary()) :: {:ok, binary()} | {:error, atom()}
  def compress(payload) when is_binary(payload) do
    {:ok, :zlib.compress(payload)}
  rescue
    _error -> {:error, :compression_failed}
  end

  @spec decompress(binary(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def decompress(compressed, max_decompressed_bytes)
      when is_binary(compressed) and is_integer(max_decompressed_bytes) and
             max_decompressed_bytes > 0 do
    zstream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zstream)
      inflate_bounded(zstream, compressed, max_decompressed_bytes, [], 0)
    rescue
      _error -> {:error, :invalid_compressed_payload}
    catch
      _kind, _reason -> {:error, :invalid_compressed_payload}
    after
      safe_inflate_end(zstream)
      :zlib.close(zstream)
    end
  end

  def decompress(_compressed, _max_decompressed_bytes), do: {:error, :invalid_limit}

  @spec frame(envelope(), binary()) :: {:ok, binary()} | {:error, atom()}
  def frame(envelope, body) when is_map(envelope) and is_binary(body) do
    with {:ok, canonical} <- canonical_object(envelope),
         {:ok, header} <- Jason.encode(canonical, maps: :strict),
         :ok <- validate_header_size(byte_size(header)) do
      {:ok, <<@magic, byte_size(header)::unsigned-big-32, header::binary, body::binary>>}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_envelope}
      {:error, _reason} = error -> error
    end
  end

  @spec unframe(binary()) :: {:ok, map(), binary()} | {:error, atom()}
  def unframe(<<@magic, header_size::unsigned-big-32, remainder::binary>>) do
    with :ok <- validate_header_size(header_size),
         true <- byte_size(remainder) >= header_size,
         <<header::binary-size(^header_size), body::binary>> <- remainder,
         {:ok, envelope} <- decode_json(header),
         true <- is_map(envelope),
         :ok <- validate_declared_body_length(envelope, body) do
      {:ok, envelope, body}
    else
      false -> {:error, :malformed_frame}
      {:error, _reason} = error -> error
      _other -> {:error, :malformed_frame}
    end
  end

  def unframe(_package), do: {:error, :malformed_frame}

  @spec default_envelope(non_neg_integer(), pos_integer()) :: envelope()
  def default_envelope(body_length, payload_schema_version)
      when is_integer(body_length) and body_length >= 0 and is_integer(payload_schema_version) and
             payload_schema_version > 0 do
    %{
      "body_length" => body_length,
      "compression" => @compression,
      "format" => @format,
      "format_version" => @format_version,
      "payload_schema_version" => payload_schema_version
    }
  end

  defp payload_map(package) do
    %{
      "payload_schema_version" => package.payload_schema_version,
      "sections" => Enum.map(ProjectPackage.sections(package), &section_map/1)
    }
  end

  defp section_map(%PackageSection{} = section) do
    %{
      "content" => section.content,
      "name" => Atom.to_string(section.name),
      "version" => section.version
    }
  end

  defp validate_package(%ProjectPackage{
         payload_schema_version: payload_schema_version,
         project: %PackageSection{name: :project, version: @section_version},
         repository: %PackageSection{name: :repository, version: @section_version},
         specifications: %PackageSection{name: :specifications, version: @section_version}
       })
       when payload_schema_version == @payload_schema_version,
       do: :ok

  defp validate_package(_package), do: {:error, :invalid_package}

  defp validate_default_envelope(
         %{
           "body_length" => body_length,
           "compression" => @compression,
           "format" => @format,
           "format_version" => @format_version,
           "payload_schema_version" => payload_schema_version
         } = envelope,
         body_length
       )
       when payload_schema_version == @payload_schema_version and
              map_size(envelope) == 5,
       do: :ok

  defp validate_default_envelope(_envelope, _actual_body_length),
    do: {:error, :unsupported_envelope}

  defp fetch_payload_sections(%{
         "payload_schema_version" => payload_schema_version,
         "sections" => sections
       })
       when payload_schema_version == @payload_schema_version and
              is_list(sections) and length(sections) == 3,
       do: {:ok, sections}

  defp fetch_payload_sections(_decoded), do: {:error, :invalid_payload}

  defp decode_section(
         %{"content" => content, "name" => expected_name, "version" => @section_version},
         expected_name_atom
       ) do
    if expected_name == Atom.to_string(expected_name_atom) do
      PackageSection.new(expected_name_atom, @section_version, content)
    else
      {:error, :invalid_section}
    end
  end

  defp decode_section(_section, _expected_name), do: {:error, :invalid_section}

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp canonical_object(value) do
    case canonicalize(value) do
      {:ok, %OrderedObject{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, :expected_object}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> canonical_pairs([], nil)
  rescue
    Protocol.UndefinedError -> {:error, :invalid_map_key}
  end

  defp canonicalize(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case canonicalize(item) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value),
       do: {:ok, value}

  defp canonicalize(_value), do: {:error, :unsupported_json_value}

  defp canonical_pairs([], acc, _previous_key) do
    {:ok, acc |> Enum.reverse() |> OrderedObject.new()}
  end

  defp canonical_pairs([{key, _value} | _rest], _acc, key),
    do: {:error, :duplicate_canonical_key}

  defp canonical_pairs([{key, value} | rest], acc, _previous_key) do
    case canonicalize(value) do
      {:ok, canonical} -> canonical_pairs(rest, [{key, canonical} | acc], key)
      {:error, _reason} = error -> error
    end
  end

  defp inflate_bounded(zstream, input, max_bytes, acc, size) do
    case :zlib.safeInflate(zstream, input) do
      {:continue, output} ->
        with {:ok, acc, size} <- collect_output(output, max_bytes, acc, size) do
          inflate_bounded(zstream, <<>>, max_bytes, acc, size)
        end

      {:finished, output} ->
        with {:ok, acc, _size} <- collect_output(output, max_bytes, acc, size) do
          {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
        end
    end
  end

  defp collect_output(output, max_bytes, acc, size) do
    output_size = IO.iodata_length(output)
    new_size = size + output_size

    if new_size <= max_bytes do
      {:ok, [output | acc], new_size}
    else
      {:error, :decompressed_size_exceeded}
    end
  end

  defp validate_header_size(size) when size >= 2 and size <= @max_header_bytes, do: :ok
  defp validate_header_size(_size), do: {:error, :invalid_header_size}

  defp validate_declared_body_length(%{"body_length" => body_length}, body)
       when is_integer(body_length) and body_length >= 0 do
    if byte_size(body) == body_length,
      do: :ok,
      else: {:error, :body_length_mismatch}
  end

  defp validate_declared_body_length(_envelope, _body), do: {:error, :missing_body_length}

  defp safe_inflate_end(zstream) do
    :zlib.inflateEnd(zstream)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
