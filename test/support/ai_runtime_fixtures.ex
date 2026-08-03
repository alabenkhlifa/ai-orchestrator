defmodule SddOrchestrator.AIRuntimeFixtures do
  @moduledoc "Test fixtures for account-owned personal AI connections and catalogs."

  import SddOrchestrator.AccountsFixtures

  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections}
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.ModelCatalogAdapterDouble
  alias SddOrchestrator.PersonalConnectionAdapterDouble

  @catalog_source_version "codex-cli 0.test.8|schema:" <> String.duplicate("8", 64)

  @doc "Creates one active paired local worker through the real pairing boundary."
  def personal_ai_worker_fixture(attrs \\ %{}) do
    device_workspace_id =
      Map.get_lazy(attrs, :device_workspace_id, fn -> Ecto.UUID.generate() end)

    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: Map.get(attrs, :os_family, "macos"),
        app_version: Map.get(attrs, :app_version, "1.0.0"),
        protocol_version: Map.get(attrs, :protocol_version, "personal-ai/1")
      })

    worker
  end

  @doc "Builds the exact safe result shape accepted from a connection adapter."
  def personal_connection_adapter_result(attrs \\ %{}) do
    %{
      worker_profile_ref:
        Map.get_lazy(attrs, :worker_profile_ref, fn ->
          "profile-#{System.unique_integer([:positive])}"
        end),
      provider: Map.get(attrs, :provider, "openai_codex"),
      authentication_mode: Map.get(attrs, :authentication_mode, "chatgpt"),
      availability: Map.get(attrs, :availability, "available"),
      adapter_compatibility_version:
        Map.get(attrs, :adapter_compatibility_version, "connection/1")
    }
  end

  @doc "Creates one personal connection through the public lifecycle boundary."
  def personal_ai_connection_fixture(attrs \\ %{}) do
    account = Map.get_lazy(attrs, :account, &account_fixture/0)
    worker = Map.get_lazy(attrs, :worker, &personal_ai_worker_fixture/0)
    authentication_mode = Map.get(attrs, :authentication_mode, "chatgpt")

    result =
      attrs
      |> Map.take([
        :worker_profile_ref,
        :provider,
        :authentication_mode,
        :availability,
        :adapter_compatibility_version
      ])
      |> Map.put_new(:authentication_mode, authentication_mode)
      |> personal_connection_adapter_result()

    link_attrs = %{
      label: Map.get(attrs, :label, "Personal Codex"),
      provider: Map.get(attrs, :provider, "openai_codex"),
      authentication_mode: authentication_mode
    }

    {:ok, connection} =
      PersonalConnections.link_personal_connection(account, worker, link_attrs,
        adapter: PersonalConnectionAdapterDouble,
        adapter_result: {:ok, result}
      )

    %{connection: connection, account: account, worker: worker}
  end

  @doc "Builds one exact safe model and effort compatibility result."
  def model_catalog_model(attrs \\ %{}) do
    model = Map.get(attrs, :model, "codex-test-model")
    efforts = Map.get(attrs, :efforts, ["low", "medium", "high"])

    %{
      id: Map.get(attrs, :id, "catalog-#{model}"),
      model: model,
      display_name: Map.get(attrs, :display_name, "Codex Test Model"),
      current: Map.get(attrs, :current, false),
      default: Map.get(attrs, :default, true),
      default_reasoning_effort: Map.get(attrs, :default_reasoning_effort, "medium"),
      supported_reasoning_efforts:
        Enum.map(efforts, fn effort ->
          %{
            reasoning_effort: effort,
            description: "Authenticated #{effort} reasoning"
          }
        end)
    }
  end

  @doc "Builds one exact provider-neutral catalog adapter result."
  def model_catalog_adapter_result(attrs \\ %{}) do
    now = Map.get(attrs, :retrieved_at, ~U[2026-08-03 12:00:00Z])

    %{
      status: Map.get(attrs, :status, "enumerated"),
      provider: Map.get(attrs, :provider, "openai_codex"),
      source: Map.get(attrs, :source, "official_client"),
      source_method: Map.get(attrs, :source_method, "model/list"),
      source_version: Map.get(attrs, :source_version, @catalog_source_version),
      retrieved_at: now,
      models: Map.get_lazy(attrs, :models, fn -> [model_catalog_model()] end)
    }
  end

  @doc "Creates one current catalog snapshot through the public refresh boundary."
  def model_catalog_snapshot_fixture(attrs \\ %{}) do
    connection_fixture =
      Map.get_lazy(attrs, :connection_fixture, fn -> personal_ai_connection_fixture(attrs) end)

    result =
      Map.get_lazy(attrs, :adapter_result, fn ->
        model_catalog_adapter_result(%{
          retrieved_at: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z]),
          models: Map.get(attrs, :models, [model_catalog_model()])
        })
      end)

    {:ok, catalog} =
      ModelCatalogs.refresh(
        connection_fixture.account,
        connection_fixture.connection.id,
        adapter: ModelCatalogAdapterDouble,
        adapter_result: {:ok, result},
        now: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z]),
        ttl_seconds: Map.get(attrs, :ttl_seconds, 300)
      )

    Map.put(connection_fixture, :catalog, catalog)
  end
end
