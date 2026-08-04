defmodule SddOrchestrator.AIRuntimeFixtures do
  @moduledoc """
  Test fixtures for personal AI connections, catalogs, quotas, and sessions.
  """

  import SddOrchestrator.AccountsFixtures

  alias SddOrchestrator.AIRuntime.{
    ModelCatalogs,
    PersonalConnections,
    Quotas,
    RuntimeCosts,
    RuntimeObservations,
    RuntimeSessions
  }

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.ModelCatalogAdapterDouble
  alias SddOrchestrator.ObservationAdapterDouble
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

  @doc "Builds one exact Task 10 quota-policy request."
  def quota_policy_request(context, attrs \\ %{}) do
    %{
      connection_id: Map.get(attrs, :connection_id, context.connection.id),
      model: Map.get(attrs, :model, "codex-test-model"),
      effort: Map.get(attrs, :effort, "medium"),
      scarcity: Map.get(attrs, :scarcity, :standard),
      choices: Map.get(attrs, :choices, [])
    }
  end

  @doc "Builds one bounded owner choice tied to a connection, model, and cost boundary."
  def quota_policy_choice(context, kind, attrs \\ %{}) do
    now = Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z])
    kind = normalize_policy_choice_kind(kind)

    {bucket_id, cost_boundary} =
      case kind do
        :scarce_model ->
          {nil, :scarce_model}

        :model_specific_quota ->
          {Map.get(attrs, :bucket_id, "model-bucket"), :quota}

        :provider_paid_continuation ->
          {Map.get(attrs, :bucket_id, "general"), :provider_paid_continuation}
      end

    %{
      id:
        Map.get_lazy(attrs, :id, fn ->
          "choice-#{kind}-#{System.unique_integer([:positive])}"
        end),
      kind: kind,
      owner_account_id: Map.get(attrs, :owner_account_id, context.account.id),
      connection_id: Map.get(attrs, :connection_id, context.connection.id),
      model: Map.get(attrs, :model, "codex-test-model"),
      bucket_id: Map.get(attrs, :bucket_id, bucket_id),
      cost_boundary: Map.get(attrs, :cost_boundary, cost_boundary),
      valid_from: Map.get(attrs, :valid_from, now),
      expires_at: Map.get(attrs, :expires_at, DateTime.add(now, 900, :second))
    }
  end

  @doc "Creates one connection with a current catalog and quota snapshot."
  def runtime_session_context_fixture(attrs \\ %{}) do
    now = Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z])
    ttl_seconds = Map.get(attrs, :ttl_seconds, 300)

    connection_fixture =
      Map.get_lazy(attrs, :connection_fixture, fn -> personal_ai_connection_fixture(attrs) end)

    catalog_fixture =
      model_catalog_snapshot_fixture(%{
        connection_fixture: connection_fixture,
        now: now,
        models: Map.get_lazy(attrs, :models, fn -> [model_catalog_model()] end),
        ttl_seconds: ttl_seconds
      })

    quota_snapshot_fixture(%{
      connection_fixture: catalog_fixture,
      now: now,
      buckets: Map.get_lazy(attrs, :buckets, fn -> [quota_bucket()] end),
      ttl_seconds: ttl_seconds
    })
  end

  @doc "Builds one exact Task 4 runtime-session pin request."
  def runtime_session_request(context, attrs \\ %{}) do
    %{
      consumer: Map.get(attrs, :consumer, :working_agent),
      consumer_ref:
        Map.get_lazy(attrs, :consumer_ref, fn ->
          "run-#{System.unique_integer([:positive])}"
        end),
      connection_id: Map.get(attrs, :connection_id, context.connection.id),
      model: Map.get(attrs, :model, "codex-test-model"),
      effort: Map.get(attrs, :effort, "medium"),
      scarcity: Map.get(attrs, :scarcity, :standard),
      choices: Map.get(attrs, :choices, []),
      spending_ceiling: Map.get(attrs, :spending_ceiling, default_spending_ceiling(context))
    }
  end

  @doc "Pins one immutable runtime session through the public boundary."
  def ai_runtime_session_fixture(context, attrs \\ %{}) do
    {:ok, session} =
      RuntimeSessions.pin_session(
        context.account,
        runtime_session_request(context, attrs),
        now: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z])
      )

    session
  end

  @doc "Builds one exact Task 11 versioned official-price registration."
  def official_price_snapshot(attrs \\ %{}) do
    %{
      version: Map.get(attrs, :version, "2026-08-01"),
      source: Map.get(attrs, :source, "official_price_list"),
      published_at: Map.get(attrs, :published_at, ~U[2026-08-01 00:00:00Z]),
      expires_at: Map.get(attrs, :expires_at, ~U[2026-09-01 00:00:00Z]),
      currency: Map.get(attrs, :currency, "USD"),
      models:
        Map.get(attrs, :models, %{
          Map.get(attrs, :model, "codex-test-model") => %{
            input: Map.get(attrs, :input, "2.00"),
            output: Map.get(attrs, :output, "10.00")
          }
        })
    }
  end

  @doc "Builds one versioned official-price registry keyed by version."
  def official_price_snapshots(attrs \\ %{}) do
    snapshot = official_price_snapshot(attrs)
    %{snapshot.version => snapshot}
  end

  @doc "Creates one pinned API-key session with a current catalog and quota."
  def runtime_cost_context_fixture(attrs \\ %{}) do
    now = Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z])

    context =
      attrs
      |> Map.put(:now, now)
      |> Map.put_new(:authentication_mode, "api_key")
      |> Map.put_new(:label, "API Key Codex")
      |> Map.put_new_lazy(:worker_profile_ref, fn ->
        "profile-api-key-#{System.unique_integer([:positive])}"
      end)
      |> runtime_session_context_fixture()

    session =
      ai_runtime_session_fixture(context, %{
        now: now,
        consumer_ref:
          Map.get_lazy(attrs, :consumer_ref, fn ->
            "run-cost-#{System.unique_integer([:positive])}"
          end),
        spending_ceiling: Map.get(attrs, :spending_ceiling, default_cost_ceiling(attrs))
      })

    Map.put(context, :session, session)
  end

  @doc "Builds one exact Task 11 bounded request configuration."
  def runtime_cost_open_request(attrs \\ %{}) do
    %{
      max_input_tokens: Map.get(attrs, :max_input_tokens, 100_000),
      max_output_tokens: Map.get(attrs, :max_output_tokens, 10_000)
    }
  end

  @doc "Builds one exact Task 11 bounded reservation request."
  def runtime_cost_reserve_request(attrs \\ %{}) do
    attrs
    |> runtime_cost_open_request()
    |> Map.put(
      :idempotency_key,
      Map.get_lazy(attrs, :idempotency_key, fn ->
        "turn-#{System.unique_integer([:positive])}"
      end)
    )
  end

  @doc "Opens one strict ceiling row through the public cost boundary."
  def runtime_cost_ledger_fixture(context, attrs \\ %{}) do
    {:ok, ledger} =
      RuntimeCosts.open_ledger(
        context.account,
        context.session.session_id,
        runtime_cost_open_request(attrs),
        now: Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z]),
        snapshots: Map.get_lazy(attrs, :snapshots, fn -> official_price_snapshots() end)
      )

    ledger
  end

  @doc "Builds one applicable quota bucket reference for an observation."
  def observation_quota_bucket(attrs \\ %{}) do
    %{
      id: Map.get(attrs, :id, "general"),
      scope: Map.get(attrs, :scope, "general"),
      model: Map.get(attrs, :model)
    }
  end

  @doc "Builds the versioned basis one local cost estimate was calculated from."
  def observation_estimate_basis(attrs \\ %{}) do
    %{
      price_version: Map.get(attrs, :price_version, "2026-08-01"),
      price_source: Map.get(attrs, :price_source, "official_price_list"),
      model: Map.get(attrs, :model, "codex-test-model"),
      input_tokens: Map.get(attrs, :input_tokens, 1_200),
      output_tokens: Map.get(attrs, :output_tokens, 300),
      input_unit_price: Map.get(attrs, :input_unit_price, "2.00"),
      output_unit_price: Map.get(attrs, :output_unit_price, "10.00")
    }
  end

  @doc "Builds one exact Task 12 provider-neutral observation adapter result."
  def observation_adapter_result(attrs \\ %{}) do
    %{
      provider: Map.get(attrs, :provider, "openai_codex"),
      source: Map.get(attrs, :source, "official_client"),
      source_version: Map.get(attrs, :source_version, @catalog_source_version),
      event_key:
        Map.get_lazy(attrs, :event_key, fn ->
          "event-#{System.unique_integer([:positive])}"
        end),
      sequence: Map.get(attrs, :sequence, 1),
      observed_at: Map.get(attrs, :observed_at, ~U[2026-08-03 12:00:30Z]),
      elapsed: Map.get(attrs, :elapsed, %{seconds: 30, source: "worker_observed"}),
      tokens:
        Map.get(attrs, :tokens, %{
          input: 1_200,
          output: 300,
          total: 1_500,
          source: "worker_observed"
        }),
      estimated_cost:
        Map.get(attrs, :estimated_cost, %{
          amount: "0.0054",
          currency: "USD",
          basis: observation_estimate_basis(),
          source: "local_estimate"
        }),
      quota:
        Map.get(attrs, :quota, %{
          buckets: [observation_quota_bucket()],
          source: "provider_fact"
        }),
      status:
        Map.get(attrs, :status, %{
          state: "available",
          pause_reason: nil,
          source: "provider_fact"
        }),
      unknown_fields: Map.get(attrs, :unknown_fields, [])
    }
  end

  @doc "Creates one connection, catalog, quota, and pinned session ready to observe."
  def runtime_observation_context_fixture(attrs \\ %{}) do
    now = Map.get(attrs, :now, ~U[2026-08-03 12:00:00Z])

    context =
      attrs
      |> Map.put(:now, now)
      |> runtime_session_context_fixture()

    session =
      ai_runtime_session_fixture(context, %{
        now: now,
        consumer: Map.get(attrs, :consumer, :working_agent),
        consumer_ref:
          Map.get_lazy(attrs, :consumer_ref, fn ->
            "run-observation-#{System.unique_integer([:positive])}"
          end)
      })

    Map.put(context, :session, session)
  end

  @doc "Appends one observation through the public ordered-append boundary."
  def runtime_observation_fixture(context, attrs \\ %{}) do
    {:ok, observation} =
      RuntimeObservations.ingest(context.account, context.session.session_id,
        adapter: ObservationAdapterDouble,
        adapter_result: {:ok, observation_adapter_result(attrs)},
        now: Map.get(attrs, :now, ~U[2026-08-03 12:05:00Z])
      )

    observation
  end

  defp default_cost_ceiling(attrs),
    do: %{amount: Decimal.new(Map.get(attrs, :ceiling, "1.00")), currency: "USD"}

  defp default_spending_ceiling(%{connection: %{authentication_mode: "api_key"}}),
    do: %{amount: Decimal.new("25.00"), currency: "USD"}

  defp default_spending_ceiling(_context), do: nil

  defp normalize_policy_choice_kind(kind)
       when kind in [:scarce_model, :model_specific_quota, :provider_paid_continuation],
       do: kind

  defp normalize_policy_choice_kind("scarce_model"), do: :scarce_model
  defp normalize_policy_choice_kind("model_specific_quota"), do: :model_specific_quota

  defp normalize_policy_choice_kind("provider_paid_continuation"),
    do: :provider_paid_continuation
end
