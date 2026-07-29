defmodule SddOrchestrator.Delivery.CanonicalJson do
  @moduledoc """
  Deterministic JSON encoding and strict decoding for the worker protocol.

  Encoding sorts object keys so the same logical value always produces the same
  bytes, which lets execution-manifest digests and envelope comparisons stay
  stable across nodes, restarts, and map iteration order. Decoding rejects
  duplicate object keys so a peer cannot smuggle a second value past validation.
  """

  alias Jason.OrderedObject

  @type value :: map() | list() | String.t() | number() | boolean() | nil

  @spec encode(value()) :: {:ok, binary()} | {:error, atom()}
  def encode(value) do
    with {:ok, canonical} <- canonicalize(value) do
      case Jason.encode(canonical, maps: :strict) do
        {:ok, json} -> {:ok, json}
        {:error, _reason} -> {:error, :invalid_json_value}
      end
    end
  end

  @spec decode(binary()) :: {:ok, value()} | {:error, atom()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, decoded} -> strict_value(decoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def decode(_json), do: {:error, :invalid_json}

  defp canonicalize(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, nested} -> {canonical_key(key), nested} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> canonical_pairs([], nil)
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

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(_key), do: :invalid_key

  defp canonical_pairs([], acc, _previous_key),
    do: {:ok, acc |> Enum.reverse() |> OrderedObject.new()}

  defp canonical_pairs([{:invalid_key, _value} | _rest], _acc, _previous_key),
    do: {:error, :invalid_object_key}

  defp canonical_pairs([{key, _value} | _rest], _acc, key), do: {:error, :duplicate_object_key}

  defp canonical_pairs([{key, value} | rest], acc, _previous_key) do
    case canonicalize(value) do
      {:ok, canonical} -> canonical_pairs(rest, [{key, canonical} | acc], key)
      {:error, _reason} = error -> error
    end
  end

  defp strict_value(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) == MapSet.size(MapSet.new(keys)) do
      strict_pairs(pairs)
    else
      {:error, :duplicate_object_key}
    end
  end

  defp strict_value(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case strict_value(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp strict_value(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_nil(value),
       do: {:ok, value}

  defp strict_value(_value), do: {:error, :invalid_json}

  defp strict_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case strict_value(value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
