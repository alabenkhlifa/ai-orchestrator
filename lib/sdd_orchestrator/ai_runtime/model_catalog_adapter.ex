defmodule SddOrchestrator.AIRuntime.ModelCatalogAdapter do
  @moduledoc """
  Provider-neutral boundary for an authenticated personal model catalog.

  Adapter results use one exact, bounded vocabulary. Unknown fields, models,
  effort compatibility, provenance, and timestamps are rejected before any
  result can be persisted or presented.
  """

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{PersonalAIConnection}

  @result_keys ~w(status provider source source_method source_version retrieved_at models)a
  @model_keys ~w(
    id model display_name current default default_reasoning_effort
    supported_reasoning_efforts
  )a
  @effort_keys ~w(reasoning_effort description)a

  @statuses ~w(enumerated enumeration_unsupported)
  @max_models 100
  @max_efforts 16
  @max_identifier_bytes 255
  @max_display_name_bytes 200
  @max_effort_bytes 64
  @max_description_bytes 500
  @max_source_version_bytes 200
  @max_result_bytes 60 * 1_024
  @codex_source_version_pattern ~r/\Acodex-cli [0-9A-Za-z._+-]+\|schema:[0-9a-f]{64}\z/

  @typedoc "Failures safe to expose outside an adapter."
  @type error ::
          :worker_unavailable
          | :timeout
          | :incompatible
          | :enumeration_unsupported
          | :invalid_request
          | :invalid_response

  @type effort :: %{reasoning_effort: String.t(), description: String.t()}

  @type model :: %{
          id: String.t(),
          model: String.t(),
          display_name: String.t(),
          current: boolean(),
          default: boolean(),
          default_reasoning_effort: String.t() | nil,
          supported_reasoning_efforts: [effort()]
        }

  @type result :: %{
          status: String.t(),
          provider: String.t(),
          source: String.t(),
          source_method: String.t(),
          source_version: String.t(),
          retrieved_at: DateTime.t(),
          models: [model()]
        }

  @callback fetch(Account.t(), PersonalAIConnection.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Validates an adapter result and binds it to the selected connection provider."
  @spec validate_result(map(), String.t()) :: {:ok, result()} | {:error, :invalid_response}
  def validate_result(result, expected_provider)
      when is_map(result) and is_binary(expected_provider) do
    with {:ok, normalized} <- exact_map(result, @result_keys),
         true <- normalized.status in @statuses,
         true <- normalized.provider == expected_provider,
         :ok <-
           validate_provenance(
             normalized.provider,
             normalized.source,
             normalized.source_method,
             normalized.source_version
           ),
         {:ok, retrieved_at} <- normalize_datetime(normalized.retrieved_at),
         {:ok, models} <- validate_models(normalized.models),
         :ok <- validate_status_models(normalized.status, models),
         safe = %{normalized | retrieved_at: retrieved_at, models: models},
         :ok <- validate_encoded_size(safe) do
      {:ok, safe}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_result(_result, _expected_provider), do: {:error, :invalid_response}

  @doc "Validates the implemented provider's exact authenticated catalog provenance."
  @spec validate_provenance(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_response}
  def validate_provenance("openai_codex", source, method, source_version) do
    with true <- source == "official_client",
         true <- method == "model/list",
         true <- is_binary(source_version),
         true <- byte_size(source_version) <= @max_source_version_bytes,
         true <- Regex.match?(@codex_source_version_pattern, source_version) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_provenance(_provider, _source, _method, _source_version),
    do: {:error, :invalid_response}

  @doc "Validates normalized model and effort compatibility facts."
  @spec validate_models(term()) :: {:ok, [model()]} | {:error, :invalid_response}
  def validate_models(models) when is_list(models) and length(models) <= @max_models do
    with {:ok, models} <- map_ok(models, &validate_model/1),
         true <- unique_by?(models, & &1.id),
         true <- unique_by?(models, & &1.model),
         true <- Enum.count(models, & &1.current) <= 1,
         true <- Enum.count(models, & &1.default) <= 1 do
      {:ok, models}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_models(_models), do: {:error, :invalid_response}

  @doc "Collapses arbitrary provider and transport failures to a safe vocabulary."
  @spec normalize_error(term()) :: error()
  def normalize_error(reason)
      when reason in [
             :worker_unavailable,
             :timeout,
             :incompatible,
             :enumeration_unsupported,
             :invalid_request
           ],
      do: reason

  def normalize_error(:worker_disconnected), do: :worker_unavailable
  def normalize_error(:unsupported_capability), do: :incompatible
  def normalize_error(_reason), do: :invalid_response

  @doc false
  def max_models, do: @max_models

  @doc false
  def max_source_version_bytes, do: @max_source_version_bytes

  defp validate_model(model) when is_map(model) do
    with {:ok, normalized} <- exact_map(model, @model_keys),
         :ok <- bounded_string(normalized.id, @max_identifier_bytes),
         :ok <- bounded_string(normalized.model, @max_identifier_bytes),
         :ok <- bounded_string(normalized.display_name, @max_display_name_bytes),
         true <- is_boolean(normalized.current),
         true <- is_boolean(normalized.default),
         {:ok, efforts} <- validate_efforts(normalized.supported_reasoning_efforts),
         :ok <- validate_default_effort(normalized.default_reasoning_effort, efforts) do
      {:ok, %{normalized | supported_reasoning_efforts: efforts}}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_model(_model), do: {:error, :invalid_response}

  defp validate_efforts(efforts) when is_list(efforts) and length(efforts) <= @max_efforts do
    with {:ok, efforts} <- map_ok(efforts, &validate_effort/1),
         true <- unique_by?(efforts, & &1.reasoning_effort) do
      {:ok, efforts}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_efforts(_efforts), do: {:error, :invalid_response}

  defp validate_effort(effort) when is_map(effort) do
    with {:ok, normalized} <- exact_map(effort, @effort_keys),
         :ok <- bounded_string(normalized.reasoning_effort, @max_effort_bytes),
         :ok <- bounded_string(normalized.description, @max_description_bytes) do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_effort(_effort), do: {:error, :invalid_response}

  defp validate_default_effort(nil, _efforts), do: :ok

  defp validate_default_effort(default_effort, efforts) do
    with :ok <- bounded_string(default_effort, @max_effort_bytes),
         true <- Enum.any?(efforts, &(&1.reasoning_effort == default_effort)) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_status_models("enumerated", _models), do: :ok

  defp validate_status_models("enumeration_unsupported", [model]) do
    if model.current or model.default, do: :ok, else: {:error, :invalid_response}
  end

  defp validate_status_models(_status, _models), do: {:error, :invalid_response}

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :invalid_response}
    end
  end

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case fun.(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_datetime(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, 0} -> {:ok, DateTime.truncate(parsed, :second)}
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_response}

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes and
         not forbidden_content?(value),
       do: :ok,
       else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_response}

  defp validate_encoded_size(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_result_bytes -> :ok
      _other -> {:error, :invalid_response}
    end
  end

  defp unique_by?(values, fun) do
    values
    |> Enum.map(fun)
    |> then(&(length(&1) == MapSet.size(MapSet.new(&1))))
  end

  defp forbidden_content?(value) do
    Regex.match?(~r/\bBearer\s+\S+/i, value) or
      Regex.match?(~r/\bsk-[A-Za-z0-9_-]{8,}\b/, value) or
      Regex.match?(~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/, value) or
      Regex.match?(~r/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i, value)
  end
end
