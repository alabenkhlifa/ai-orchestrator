defmodule SddOrchestrator.AIRuntime.ModelCatalogAdapter.CodexTest do
  @moduledoc "Task 2 proof for official-client model/list normalization."

  use ExUnit.Case, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{CodexAppServer, PersonalAIConnection}
  alias SddOrchestrator.AIRuntime.ModelCatalogAdapter.Codex
  alias SddOrchestrator.CodexAppServerFixtures
  alias SddOrchestrator.CodexAppServerProcessDouble

  @now ~U[2026-08-03 12:00:00Z]

  defmodule MalformedCompatibilityAppServer do
    def compatibility(_server), do: {:ok, %{codex_version: "spoofed"}}
    def request(_server, _method, _params, _opts), do: raise("must not request")
  end

  defmodule UnavailableCompatibilityAppServer do
    def compatibility(_server), do: {:error, :process_unavailable}
    def request(_server, _method, _params, _opts), do: raise("must not request")
  end

  defmodule SpoofedCompatibilityAppServer do
    def compatibility(_server) do
      {:ok,
       %{
         codex_version: "worker-reported-version",
         schema_digest: String.duplicate("a", 64)
       }}
    end

    def request(_server, _method, _params, _opts), do: raise("must not request")
  end

  setup do
    {:ok, adapter} = CodexAppServerFixtures.start_adapter(self())
    handshake = CodexAppServerFixtures.receive_handshake()
    on_exit(fn -> CodexAppServer.stop(adapter) end)

    connection = %PersonalAIConnection{
      provider: "openai_codex",
      adapter_compatibility_version: "catalog/1"
    }

    %{adapter: adapter, process: handshake.process, connection: connection}
  end

  test "uses the official request shape and projects default models and supported efforts",
       context do
    task = fetch_async(context, source_version: "caller-spoofed-source")
    request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    assert request["params"] == %{"limit" => 20, "includeHidden" => false}

    CodexAppServerProcessDouble.respond(context.process, request["id"], %{
      "data" => [
        official_entry(%{
          "id" => "live-id",
          "model" => "live-provider-model",
          "description" => "Live provider model details",
          "displayName" => "Live Provider Model",
          "isDefault" => true,
          "additionalSpeedTiers" => ["fast", "faster"],
          "availabilityNux" => %{"message" => "Available for this account"},
          "defaultServiceTier" => "standard",
          "inputModalities" => ["text", "image"],
          "serviceTiers" => [
            %{
              "id" => "standard",
              "name" => "Standard",
              "description" => "Standard service tier"
            }
          ],
          "supportsPersonality" => true,
          "upgrade" => "next-provider-model",
          "upgradeInfo" => %{
            "model" => "next-provider-model",
            "migrationMarkdown" => "Use the next model.",
            "modelLink" => nil,
            "upgradeCopy" => "Upgrade"
          }
        })
      ],
      "nextCursor" => nil
    })

    assert {:ok, result} = Task.await(task)
    assert result.status == "enumerated"
    assert result.source == "official_client"
    assert result.source_method == "model/list"
    assert result.source_version == verified_source_version()
    assert result.retrieved_at == @now

    assert [model] = result.models
    assert model.id == "live-id"
    assert model.model == "live-provider-model"
    assert model.display_name == "Live Provider Model"
    assert model.default
    refute model.current
    assert model.default_reasoning_effort == "medium"

    assert Enum.map(model.supported_reasoning_efforts, & &1.reasoning_effort) == [
             "low",
             "medium",
             "high"
           ]

    refute Map.has_key?(model, :input_modalities)
    refute Map.has_key?(model, :upgrade_info)
  end

  test "paginates with bounded cursors and excludes hidden models", context do
    task = fetch_async(context)
    first = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, first["id"], %{
      "data" => [
        official_entry(%{"id" => "visible-1", "model" => "live-one", "isDefault" => true}),
        official_entry(%{
          "id" => "hidden-1",
          "model" => "hidden-provider-model",
          "displayName" => "Hidden",
          "hidden" => true
        })
      ],
      "nextCursor" => "cursor-page-2"
    })

    second = CodexAppServerFixtures.receive_write(context.process, "model/list")

    assert second["params"] == %{
             "limit" => 20,
             "includeHidden" => false,
             "cursor" => "cursor-page-2"
           }

    CodexAppServerProcessDouble.respond(context.process, second["id"], %{
      "data" => [official_entry(%{"id" => "visible-2", "model" => "live-two"})]
    })

    assert {:ok, result} = Task.await(task)
    assert Enum.map(result.models, & &1.model) == ["live-one", "live-two"]
    refute Enum.any?(result.models, &(&1.model == "hidden-provider-model"))
  end

  test "fails closed when pagination exceeds the configured bound", context do
    task = fetch_async(context, max_pages: 1)
    request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, request["id"], %{
      "data" => [official_entry(%{"id" => "page-one", "model" => "page-one"})],
      "nextCursor" => "more-pages"
    })

    assert Task.await(task) == {:error, :invalid_response}
  end

  test "rejects repeated cursors, unknown fields, and malformed documented optional fields",
       context do
    repeated = fetch_async(context, max_pages: 3)
    first = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, first["id"], %{
      "data" => [official_entry(%{"id" => "one", "model" => "one"})],
      "nextCursor" => "same-cursor"
    })

    second = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, second["id"], %{
      "data" => [official_entry(%{"id" => "two", "model" => "two"})],
      "nextCursor" => "same-cursor"
    })

    assert Task.await(repeated) == {:error, :invalid_response}

    unknown = fetch_async(context)
    unknown_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, unknown_request["id"], %{
      "data" => [Map.put(official_entry(), "plan", "pro")]
    })

    assert Task.await(unknown) == {:error, :invalid_response}

    malformed = fetch_async(context)
    malformed_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, malformed_request["id"], %{
      "data" => [official_entry(%{"inputModalities" => "text"})]
    })

    assert Task.await(malformed) == {:error, :invalid_response}

    malformed_upgrade = fetch_async(context)

    malformed_upgrade_request =
      CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, malformed_upgrade_request["id"], %{
      "data" => [official_entry(%{"upgrade" => %{"model" => "not-the-documented-id"}})]
    })

    assert Task.await(malformed_upgrade) == {:error, :invalid_response}

    malformed_upgrade_info = fetch_async(context)

    malformed_upgrade_info_request =
      CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, malformed_upgrade_info_request["id"], %{
      "data" => [official_entry(%{"upgradeInfo" => %{"message" => "old schema"}})]
    })

    assert Task.await(malformed_upgrade_info) == {:error, :invalid_response}
  end

  test "rejects duplicate, incompatible-default, and oversized official entries", context do
    duplicate = fetch_async(context)
    duplicate_request = CodexAppServerFixtures.receive_write(context.process, "model/list")
    entry = official_entry(%{"id" => "duplicate", "model" => "duplicate"})

    CodexAppServerProcessDouble.respond(context.process, duplicate_request["id"], %{
      "data" => [entry, entry]
    })

    assert Task.await(duplicate) == {:error, :invalid_response}

    incompatible = fetch_async(context)
    incompatible_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, incompatible_request["id"], %{
      "data" => [official_entry(%{"defaultReasoningEffort" => "unlisted"})]
    })

    assert Task.await(incompatible) == {:error, :invalid_response}

    oversized = fetch_async(context)
    oversized_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.respond(context.process, oversized_request["id"], %{
      "data" => [official_entry(%{"displayName" => String.duplicate("x", 201)})]
    })

    assert Task.await(oversized) == {:error, :invalid_response}
  end

  test "returns only a worker-proven current model when enumeration is unsupported", context do
    proven =
      model_catalog_model(%{
        model: "authenticated-current-model",
        current: true,
        default: false,
        efforts: ["medium"],
        default_reasoning_effort: "medium"
      })

    limited = fetch_async(context, proven_model: proven)
    limited_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.error(context.process, limited_request["id"], %{
      "code" => -32_601,
      "message" => "raw unsupported method detail"
    })

    assert {:ok, result} = Task.await(limited)

    assert result.status == "enumeration_unsupported"
    assert Enum.map(result.models, & &1.model) == ["authenticated-current-model"]
    assert hd(result.models).current
    assert result.source_version == verified_source_version()

    missing = fetch_async(context)
    missing_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.error(context.process, missing_request["id"], %{
      "code" => -32_601,
      "message" => "must not escape"
    })

    assert Task.await(missing) == {:error, :enumeration_unsupported}

    unproven = fetch_async(context, proven_model: %{proven | current: false, default: false})
    unproven_request = CodexAppServerFixtures.receive_write(context.process, "model/list")

    CodexAppServerProcessDouble.error(context.process, unproven_request["id"], %{
      "code" => -32_601,
      "message" => "must not escape"
    })

    assert Task.await(unproven) == {:error, :invalid_response}
  end

  test "fails closed when verified compatibility facts are unavailable or malformed", context do
    assert {:error, :worker_unavailable} =
             Codex.fetch(nil, context.connection,
               server: self(),
               app_server_module: UnavailableCompatibilityAppServer,
               now: @now
             )

    assert {:error, :invalid_response} =
             Codex.fetch(nil, context.connection,
               server: self(),
               app_server_module: MalformedCompatibilityAppServer,
               now: @now
             )

    assert {:error, :invalid_response} =
             Codex.fetch(nil, context.connection,
               server: self(),
               app_server_module: SpoofedCompatibilityAppServer,
               now: @now
             )
  end

  defp fetch_async(context, extra_opts \\ []) do
    Task.async(fn ->
      Codex.fetch(
        nil,
        context.connection,
        Keyword.merge(
          [server: context.adapter, now: @now],
          extra_opts
        )
      )
    end)
  end

  defp verified_source_version do
    CodexAppServerFixtures.codex_version() <>
      "|schema:" <> CodexAppServerFixtures.schema_digest()
  end

  defp official_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "catalog-live-id",
        "model" => "catalog-live-model",
        "description" => "Authenticated model catalog entry",
        "displayName" => "Catalog Live Model",
        "hidden" => false,
        "defaultReasoningEffort" => "medium",
        "supportedReasoningEfforts" => [
          %{"reasoningEffort" => "low", "description" => "Authenticated low reasoning"},
          %{"reasoningEffort" => "medium", "description" => "Authenticated medium reasoning"},
          %{"reasoningEffort" => "high", "description" => "Authenticated high reasoning"}
        ],
        "isDefault" => false
      },
      overrides
    )
  end
end
