defmodule SddOrchestrator.AIRuntime.ModelCatalogAdapter.Codex do
  @moduledoc """
  Worker-local Codex catalog adapter over the official App Server `model/list` method.

  Pagination is bounded and every page and entry is validated against the
  documented protocol before hidden entries and unused optional metadata are
  discarded. No model or reasoning-effort value is compiled into this module.
  """

  @behaviour SddOrchestrator.AIRuntime.ModelCatalogAdapter

  alias SddOrchestrator.AIRuntime.{CodexAppServer, ModelCatalogAdapter}

  @page_size 20
  @default_max_pages 5
  @max_cursor_bytes 255

  @required_entry_keys ~w(
    id model description displayName hidden defaultReasoningEffort supportedReasoningEfforts
    isDefault
  )
  @documented_optional_entry_keys ~w(
    additionalSpeedTiers availabilityNux defaultServiceTier inputModalities serviceTiers
    supportsPersonality upgrade upgradeInfo
  )
  @effort_keys ~w(reasoningEffort description)
  @service_tier_keys ~w(id name description)
  @upgrade_info_keys ~w(model migrationMarkdown modelLink upgradeCopy)
  @input_modalities ~w(text image audio)

  @impl true
  def fetch(_account, %{provider: "openai_codex"}, opts) do
    app_server = Keyword.get(opts, :app_server_module, CodexAppServer)

    with {:ok, server} <- server(opts),
         {:ok, source_version} <- source_version(server, app_server),
         {:ok, retrieved_at} <- retrieved_at(opts) do
      case fetch_pages(server, opts) do
        {:ok, models} ->
          validate_result("enumerated", models, source_version, retrieved_at)

        {:error, :unsupported_method} ->
          limited_result(opts, source_version, retrieved_at)

        {:error, reason} ->
          {:error, normalize_app_server_error(reason)}
      end
    end
  end

  def fetch(_account, _connection, _opts), do: {:error, :invalid_request}

  @doc "Builds a limited result only from one worker-proven current or default model."
  def limited_result(opts, source_version, retrieved_at) do
    case Keyword.fetch(opts, :proven_model) do
      {:ok, proven_model} ->
        validate_result(
          "enumeration_unsupported",
          [proven_model],
          source_version,
          retrieved_at
        )

      :error ->
        {:error, :enumeration_unsupported}
    end
  end

  defp fetch_pages(server, opts) do
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)

    if is_integer(max_pages) and max_pages > 0 and max_pages <= @default_max_pages do
      do_fetch_pages(server, opts, nil, max_pages, [], [])
    else
      {:error, :invalid_request}
    end
  end

  # `seen_cursors` is the repeated-cursor defence: a worker that answers with a
  # cursor it already handed out would otherwise loop the pagination. It is a
  # plain list because `max_pages` is bounded by `@default_max_pages`, so it
  # holds at most four entries and never needs a set's lookup cost.
  @spec do_fetch_pages(
          pid() | atom() | tuple(),
          keyword(),
          String.t() | nil,
          non_neg_integer(),
          [String.t()],
          [map()]
        ) :: {:ok, [map()]} | {:error, term()}
  defp do_fetch_pages(_server, _opts, _cursor, 0, _seen_cursors, _models),
    do: {:error, :invalid_response}

  defp do_fetch_pages(server, opts, cursor, pages_left, seen_cursors, models) do
    params =
      %{"limit" => @page_size, "includeHidden" => false}
      |> maybe_put_cursor(cursor)

    app_server = Keyword.get(opts, :app_server_module, CodexAppServer)
    request_opts = Keyword.take(opts, [:timeout_ms])

    case app_server.request(server, "model/list", params, request_opts) do
      {:ok, result} ->
        with {:ok, entries, next_cursor} <- validate_page(result),
             {:ok, entries} <- normalize_entries(entries),
             combined = models ++ Enum.reject(entries, & &1.hidden),
             true <- length(combined) <= ModelCatalogAdapter.max_models(),
             :ok <- validate_next_cursor(next_cursor, seen_cursors) do
          finish_or_fetch_next(server, opts, next_cursor, pages_left, seen_cursors, combined)
        else
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_response}
    end
  end

  @spec finish_or_fetch_next(
          pid() | atom() | tuple(),
          keyword(),
          String.t() | nil,
          non_neg_integer(),
          [String.t()],
          [map()]
        ) :: {:ok, [map()]} | {:error, term()}
  defp finish_or_fetch_next(server, opts, next_cursor, pages_left, seen_cursors, combined) do
    if is_nil(next_cursor) do
      {:ok, Enum.map(combined, &Map.delete(&1, :hidden))}
    else
      do_fetch_pages(
        server,
        opts,
        next_cursor,
        pages_left - 1,
        [next_cursor | seen_cursors],
        combined
      )
    end
  end

  defp validate_page(result) when is_map(result) do
    keys = Map.keys(result) |> Enum.sort()

    cond do
      keys == ["data"] and is_list(result["data"]) and
          length(result["data"]) <= @page_size ->
        {:ok, result["data"], nil}

      keys == ["data", "nextCursor"] and is_list(result["data"]) and
          length(result["data"]) <= @page_size ->
        {:ok, result["data"], result["nextCursor"]}

      true ->
        {:error, :invalid_response}
    end
  end

  defp validate_page(_result), do: {:error, :invalid_response}

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      case normalize_entry(entry) do
        {:ok, model} -> {:cont, {:ok, [model | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_entry(entry) when is_map(entry) do
    keys = Map.keys(entry)
    allowed = @required_entry_keys ++ @documented_optional_entry_keys

    with true <- Enum.all?(@required_entry_keys, &Map.has_key?(entry, &1)),
         true <- Enum.all?(keys, &(&1 in allowed)),
         true <- Enum.all?(keys, &is_binary/1),
         :ok <- validate_documented_optional_fields(entry),
         :ok <- bounded_string(entry["id"], 255),
         :ok <- bounded_string(entry["model"], 255),
         :ok <- bounded_text(entry["description"], 1_000),
         :ok <- bounded_string(entry["displayName"], 200),
         true <- is_boolean(entry["hidden"]),
         true <- is_boolean(entry["isDefault"]),
         {:ok, efforts} <- normalize_efforts(entry["supportedReasoningEfforts"]),
         :ok <- validate_default_effort(entry["defaultReasoningEffort"], efforts) do
      {:ok,
       %{
         id: entry["id"],
         model: entry["model"],
         display_name: entry["displayName"],
         hidden: entry["hidden"],
         current: false,
         default: entry["isDefault"],
         default_reasoning_effort: entry["defaultReasoningEffort"],
         supported_reasoning_efforts: efforts
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp normalize_entry(_entry), do: {:error, :invalid_response}

  defp normalize_efforts(efforts) when is_list(efforts) and length(efforts) <= 16 do
    Enum.reduce_while(efforts, {:ok, []}, fn effort, {:ok, normalized} ->
      with true <- is_map(effort),
           true <- Map.keys(effort) |> Enum.sort() == Enum.sort(@effort_keys),
           :ok <- bounded_string(effort["reasoningEffort"], 64),
           :ok <- bounded_string(effort["description"], 500) do
        item = %{
          reasoning_effort: effort["reasoningEffort"],
          description: effort["description"]
        }

        {:cont, {:ok, [item | normalized]}}
      else
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_efforts(_efforts), do: {:error, :invalid_response}

  defp validate_default_effort(nil, _efforts), do: :ok

  defp validate_default_effort(value, efforts) do
    with :ok <- bounded_string(value, 64),
         true <- Enum.any?(efforts, &(&1.reasoning_effort == value)) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_documented_optional_fields(entry) do
    Enum.reduce_while(@documented_optional_entry_keys, :ok, fn key, :ok ->
      case Map.fetch(entry, key) do
        :error -> :ok
        {:ok, value} -> validate_optional_field(key, value)
      end
      |> case do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_optional_field("additionalSpeedTiers", values) do
    validate_string_list(values, 16, 64)
  end

  defp validate_optional_field("availabilityNux", nil), do: :ok

  defp validate_optional_field("availabilityNux", value) when is_map(value) do
    with true <- Map.keys(value) == ["message"],
         :ok <- bounded_text(value["message"], 1_000) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_optional_field("defaultServiceTier", nil), do: :ok
  defp validate_optional_field("defaultServiceTier", value), do: bounded_string(value, 64)

  defp validate_optional_field("inputModalities", values)
       when is_list(values) and length(values) <= length(@input_modalities) do
    if Enum.all?(values, &(&1 in @input_modalities)) and unique?(values),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_optional_field("serviceTiers", values)
       when is_list(values) and length(values) <= 16 do
    with {:ok, tiers} <- map_ok(values, &validate_service_tier/1),
         true <- unique?(Enum.map(tiers, & &1["id"])) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_optional_field("supportsPersonality", value) when is_boolean(value), do: :ok

  defp validate_optional_field("upgrade", nil), do: :ok
  defp validate_optional_field("upgrade", value), do: bounded_string(value, 255)

  defp validate_optional_field("upgradeInfo", nil), do: :ok

  defp validate_optional_field("upgradeInfo", value) when is_map(value) do
    with true <- Map.keys(value) |> Enum.sort() == Enum.sort(@upgrade_info_keys),
         :ok <- bounded_string(value["model"], 255),
         :ok <- nullable_bounded_text(value["migrationMarkdown"], 4_096),
         :ok <- nullable_bounded_text(value["modelLink"], 1_000),
         :ok <- nullable_bounded_text(value["upgradeCopy"], 1_000) do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_optional_field(_key, _value), do: {:error, :invalid_response}

  defp validate_service_tier(tier) when is_map(tier) do
    with true <- Map.keys(tier) |> Enum.sort() == Enum.sort(@service_tier_keys),
         :ok <- bounded_string(tier["id"], 64),
         :ok <- bounded_string(tier["name"], 100),
         :ok <- bounded_text(tier["description"], 500) do
      {:ok, tier}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_service_tier(_tier), do: {:error, :invalid_response}

  defp validate_string_list(values, max_items, max_bytes)
       when is_list(values) and length(values) <= max_items do
    if Enum.all?(values, &match?(:ok, bounded_string(&1, max_bytes))) and unique?(values),
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp validate_string_list(_values, _max_items, _max_bytes),
    do: {:error, :invalid_response}

  defp nullable_bounded_text(nil, _max_bytes), do: :ok
  defp nullable_bounded_text(value, max_bytes), do: bounded_text(value, max_bytes)

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

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))

  @spec validate_next_cursor(String.t() | nil, [String.t()]) :: :ok | {:error, :invalid_response}
  defp validate_next_cursor(nil, _seen), do: :ok

  defp validate_next_cursor(cursor, seen) do
    with :ok <- bounded_string(cursor, @max_cursor_bytes),
         false <- cursor in seen do
      :ok
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp validate_result(status, models, source_version, retrieved_at) do
    ModelCatalogAdapter.validate_result(
      %{
        status: status,
        provider: "openai_codex",
        source: "official_client",
        source_method: "model/list",
        source_version: source_version,
        retrieved_at: retrieved_at,
        models: models
      },
      "openai_codex"
    )
  end

  defp source_version(server, app_server) do
    case app_server.compatibility(server) do
      {:ok, %{codex_version: version, schema_digest: digest} = pair}
      when map_size(pair) == 2 and is_binary(version) and is_binary(digest) ->
        value = version <> "|schema:" <> digest

        with :ok <- bounded_string(version, 100),
             true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
             :ok <-
               ModelCatalogAdapter.validate_provenance(
                 "openai_codex",
                 "official_client",
                 "model/list",
                 value
               ) do
          {:ok, value}
        else
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, normalize_app_server_error(reason)}

      _other ->
        {:error, :invalid_response}
    end
  end

  defp retrieved_at(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp server(opts) do
    case Keyword.fetch(opts, :server) do
      {:ok, server} when is_pid(server) or is_atom(server) or is_tuple(server) -> {:ok, server}
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_app_server_error(reason)
       when reason in [:timeout, :process_unavailable, :process_crashed, :not_initialized],
       do: :worker_unavailable

  defp normalize_app_server_error(_reason), do: :invalid_response

  defp maybe_put_cursor(params, nil), do: params
  defp maybe_put_cursor(params, cursor), do: Map.put(params, "cursor", cursor)

  defp bounded_string(value, max_bytes) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_bytes,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_bytes), do: {:error, :invalid_response}

  defp bounded_text(value, max_bytes) when is_binary(value) do
    if byte_size(value) <= max_bytes,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp bounded_text(_value, _max_bytes), do: {:error, :invalid_response}
end
