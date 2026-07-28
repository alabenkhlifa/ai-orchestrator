defmodule SddOrchestrator.Specifications.SpecificationDocuments do
  @moduledoc """
  Validation and stable digesting for one complete specification document set.

  Documents remain untrusted text values. This module performs no path
  resolution, interpolation, rendering, or command execution.
  """

  alias SddOrchestrator.Specifications.SpecificationLimits

  @keys [:requirements, :design, :tasks]
  @string_keys Enum.map(@keys, &Atom.to_string/1)

  @type t :: %{
          requirements: String.t(),
          design: String.t(),
          tasks: String.t()
        }

  @spec normalize(map()) :: {:ok, t()} | {:error, atom()}
  def normalize(documents) when is_map(documents) do
    with :ok <- validate_keys(documents),
         {:ok, normalized} <- normalize_values(documents),
         :ok <- validate_sizes(normalized) do
      {:ok, normalized}
    end
  end

  def normalize(_documents), do: {:error, :invalid_documents}

  @spec digest(t()) :: String.t()
  def digest(%{requirements: requirements, design: design, tasks: tasks}) do
    [requirements, design, tasks]
    |> Enum.map_join(fn value -> "#{byte_size(value)}:#{value}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec total_bytes(t()) :: non_neg_integer()
  def total_bytes(documents) do
    Enum.reduce(@keys, 0, fn key, total -> total + byte_size(Map.fetch!(documents, key)) end)
  end

  defp validate_keys(documents) do
    normalized_keys =
      documents
      |> Map.keys()
      |> Enum.map(&normalize_key/1)

    if Enum.sort(normalized_keys) == Enum.sort(@keys) and
         length(Enum.uniq(normalized_keys)) == length(@keys) do
      :ok
    else
      {:error, :invalid_document_set}
    end
  end

  defp normalize_values(documents) do
    Enum.reduce_while(@keys, {:ok, %{}}, fn key, {:ok, acc} ->
      value = Map.get(documents, key, Map.get(documents, Atom.to_string(key)))

      if is_binary(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:halt, {:error, :invalid_document}}
      end
    end)
  end

  defp validate_sizes(documents) do
    max_document_bytes = SpecificationLimits.get(:max_document_bytes)
    max_revision_bytes = SpecificationLimits.get(:max_revision_bytes)

    cond do
      Enum.any?(@keys, &(byte_size(Map.fetch!(documents, &1)) > max_document_bytes)) ->
        {:error, :document_too_large}

      total_bytes(documents) > max_revision_bytes ->
        {:error, :revision_too_large}

      true ->
        :ok
    end
  end

  defp normalize_key(key) when key in @keys, do: key
  defp normalize_key(key) when key in @string_keys, do: String.to_existing_atom(key)
  defp normalize_key(_key), do: :unsupported
end
