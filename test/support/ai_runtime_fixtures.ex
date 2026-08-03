defmodule SddOrchestrator.AIRuntimeFixtures do
  @moduledoc "Test fixtures for personal AI connections, catalogs, and quota snapshots."

  import SddOrchestrator.AccountsFixtures

  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections, Quotas}
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.ModelCatalogAdapterDouble
  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.QuotaAdapterDouble

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

  @doc "Builds one exact provider-neutral quota bucket."
  def quota_bucket(attrs \\ %{}) do
    %{
      id: Map.get(attrs, :id, "general"),
      scope: Map.get(attrs, :scope, "general"),
      model: Map.get(attrs, :model),
      display_name: Map.get(attrs, :display_name, "General Codex"),
      primary_window:
        Map.get(attrs, :primary_window, %{
          used_percent: 35,
          resets_at: ~U[2026-08-03 13:00:00Z],
          duration_minutes: 300,
          unknown_fields: []
        }),
      secondary_window: Map.get(attrs, :secondary_window),
      credits:
        Map.get(attrs, :credits, %{
          has_credits: true,
          unlimited: false,
          balance: "12.50",
          unknown_fields: []
        }),
      paid_continuation: Map.get(attrs, :paid_continuation, "unknown"),
      spend_control: Map.get(attrs, :spend_control),
      spend_control_reached: Map.get(attrs, :spend_control_reached),
      limit_reached_reason: Map.get(attrs, :limit_reached_reason),
      unknown_fields:
        Map.get(attrs, :unknown_fields, [
          "secondary_window",
          "paid_continuation",
          "spend_control",
          "spend_control_reached",
          "limit_reached_reason"
        ])
    }
  end

  @doc "Builds one exact provider-neutral quota adapter result."
  def quota_adapter_result(attrs \\ %{}) do
    authentication_mode = Map.get(attrs, :authentication_mode, "chatgpt")

    if authentication_mode == "api_key" do
      %{
        status: "unknown",
        provider: Map.get(attrs, :provider, "openai_codex"),
        authentication_mode: "api_key",
        source: Map.get(attrs, :source, "official_client"),
        source_methods: [],
        source_version: Map.get(attrs, :source_version, @catalog_source_version),
        retrieved_at: Map.get(attrs, :retrieved_at, ~U[2026-08-03 12:00:00Z]),
        buckets: [],
        reset_credits: nil,
        token_activity: nil,
        unknown_fields: [
          "api_key_quota",
          "api_key_billing",
          "reset_credits",
          "paid_continuation",
          "token_activity"
        ]
      }
    else
      %{
        status: Map.get(attrs, :status, "reported"),
        provider: Map.get(attrs, :provider, "openai_codex"),
        authentication_mode: "chatgpt",
        source: Map.get(attrs, :source, "official_client"),
        source_methods:
          Map.get(attrs, :source_methods, [
            "account/rateLimits/read",
            "account/usage/read"
          ]),
        source_version: Map.get(attrs, :source_version, @catalog_source_version),
        retrieved_at: Map.get(attrs, :retrieved_at, ~U[2026-08-03 12:00:00Z]),
        buckets: Map.get_lazy(attrs, :buckets, fn -> [quota_bucket()] end),
        reset_credits: Map.get(attrs, :reset_credits, %{available_count: 2, unknown_fields: []}),
        token_activity:
          Map.get(attrs, :token_activity, %{
            lifetime_tokens: 12_000,
            peak_daily_tokens: 2_500,
            current_streak_days: 3,
            longest_streak_days: 8,
            longest_running_turn_seconds: 90,
            unknown_fields: []
          }),
        unknown_fields: Map.get(attrs, :unknown_fields, ["provider_billing"])
      }
    end
  end

  @doc "Creates one current quota snapshot through the public refresh boundary."
  def quota_snapshot_fixture(attrs \\ %{}) do
    connection_fixture =
      Map.get_lazy(attrs, :connection_fixture, fn -> personal_ai_connection_fixture(attrs) end)

    result =
      Map.get_lazy(attrs, :adapter_result, fn ->
        quota_adapter_result(%{
          authentication_mode: connection_fixture.connection.authentication_mode,
          retrieved_at: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z]),
          buckets: Map.get(attrs, :buckets, [quota_bucket()])
        })
      end)

    {:ok, quota} =
      Quotas.refresh(
        connection_fixture.account,
        connection_fixture.connection.id,
        adapter: QuotaAdapterDouble,
        adapter_result: {:ok, result},
        now: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z]),
        ttl_seconds: Map.get(attrs, :ttl_seconds, 300)
      )

    Map.put(connection_fixture, :quota, quota)
  end
end
