defmodule SddOrchestrator.AIRuntime.RuntimeObservationsTest do
  @moduledoc "Task 12 proof for ordered minimized runtime observation ingestion."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    CodexAppServer,
    ObservationAdapter,
    PersonalAIConnection,
    RuntimeObservations
  }

  alias SddOrchestrator.CodexAppServerFixtures
  alias SddOrchestrator.CodexAppServerProcessDouble
  alias SddOrchestrator.ObservationAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]
  @ingested_at ~U[2026-08-03 12:10:00Z]
  @profile_ref "profile-observation-boundary"

  @minimized_columns ~w(
    id account_id session_id sequence event_key observed_at
    elapsed_seconds elapsed_source
    input_tokens output_tokens total_tokens tokens_source
    estimated_cost_amount estimated_cost_currency estimated_cost_basis cost_source
    quota_refs quota_source
    status status_source pause_reason
    unknown_fields inserted_at updated_at
  )

  setup do
    runtime_observation_context_fixture(%{now: @now, worker_profile_ref: @profile_ref})
  end

  describe "ordered append" do
    test "records one complete operational projection with distinct labels", context do
      assert {:ok, observation} =
               ingest(context, %{
                 event_key: "event-complete",
                 sequence: 1,
                 observed_at: DateTime.add(@now, 30, :second)
               })

      assert observation.session_id == context.session.session_id
      assert observation.sequence == 1
      assert observation.event_key == "event-complete"
      assert observation.observed_at == DateTime.add(@now, 30, :second)

      assert observation.elapsed == %{seconds: 30, source: :worker_observed}

      assert observation.tokens == %{
               input: 1_200,
               output: 300,
               total: 1_500,
               source: :worker_observed
             }

      assert observation.estimated_cost.source == :local_estimate
      assert Decimal.equal?(observation.estimated_cost.amount, Decimal.new("0.0054"))
      assert observation.estimated_cost.currency == "USD"

      assert observation.estimated_cost.basis.price_version == "2026-08-01"
      assert observation.estimated_cost.basis.price_source == "official_price_list"
      assert observation.estimated_cost.basis.model == "codex-test-model"
      assert observation.estimated_cost.basis.input_tokens == 1_200
      assert observation.estimated_cost.basis.output_tokens == 300

      assert Decimal.equal?(
               observation.estimated_cost.basis.input_unit_price,
               Decimal.new("2.00")
             )

      assert observation.quota == %{
               buckets: [%{id: "general", scope: "general", model: nil}],
               source: :provider_fact
             }

      assert observation.status == %{
               state: :available,
               pause_reason: nil,
               source: :provider_fact
             }

      assert observation.unknown_fields == []
    end

    test "keeps one session's history in append order", context do
      for sequence <- 1..3 do
        assert {:ok, _observation} =
                 ingest(context, %{
                   event_key: "event-#{sequence}",
                   sequence: sequence,
                   observed_at: DateTime.add(@now, sequence * 30, :second)
                 })
      end

      assert {:ok, observations} =
               RuntimeObservations.list_observations(
                 context.account,
                 context.session.session_id
               )

      assert Enum.map(observations, & &1.sequence) == [1, 2, 3]
      assert Enum.map(observations, & &1.event_key) == ["event-1", "event-2", "event-3"]

      assert {:ok, latest} =
               RuntimeObservations.latest_observation(
                 context.account,
                 context.session.session_id
               )

      assert latest.sequence == 3
    end

    test "the database refuses a second row for one session and sequence", context do
      assert {:ok, _first} = insert_row(context, %{event_key: "event-one", sequence: 7})

      assert {:error, changeset} = insert_row(context, %{event_key: "event-two", sequence: 7})
      assert "has already been taken" in errors_on(changeset).sequence
    end

    test "the database refuses a second row for one session and event key", context do
      assert {:ok, _first} = insert_row(context, %{event_key: "event-same", sequence: 1})

      assert {:error, changeset} = insert_row(context, %{event_key: "event-same", sequence: 2})
      assert "has already been taken" in errors_on(changeset).event_key
    end
  end

  describe "idempotency and staleness" do
    test "replays a duplicate event instead of appending a second row", context do
      attrs = %{event_key: "event-replayed", sequence: 1}

      assert {:ok, first} = ingest(context, attrs)
      assert {:ok, replayed} = ingest(context, attrs)

      assert replayed == first
      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1
    end

    test "refuses one event key that carries different facts", context do
      assert {:ok, _first} = ingest(context, %{event_key: "event-conflict", sequence: 1})

      assert {:error, :duplicate_event} =
               ingest(context, %{
                 event_key: "event-conflict",
                 sequence: 1,
                 tokens: %{input: 10, output: 5, total: 15, source: "worker_observed"},
                 estimated_cost: unknown_cost(),
                 unknown_fields: ["estimated_cost"]
               })

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1
    end

    test "refuses an out-of-order or already superseded event as stale", context do
      assert {:ok, _second} =
               ingest(context, %{
                 event_key: "event-second",
                 sequence: 2,
                 observed_at: DateTime.add(@now, 60, :second)
               })

      assert {:error, :stale_observation} =
               ingest(context, %{
                 event_key: "event-first",
                 sequence: 1,
                 observed_at: DateTime.add(@now, 30, :second)
               })

      assert {:error, :stale_observation} =
               ingest(context, %{
                 event_key: "event-repeated-sequence",
                 sequence: 2,
                 observed_at: DateTime.add(@now, 90, :second)
               })

      assert {:error, :stale_observation} =
               ingest(context, %{
                 event_key: "event-backdated",
                 sequence: 3,
                 observed_at: DateTime.add(@now, 45, :second)
               })

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 1
    end

    test "refuses an observation that predates the pinned configuration", context do
      assert {:error, :invalid_response} =
               ingest(context, %{observed_at: DateTime.add(@now, -1, :second)})

      assert {:error, :invalid_response} =
               ingest(context, %{observed_at: DateTime.add(@ingested_at, 120, :second)})
    end
  end

  describe "facts, estimates, and unknowns" do
    test "keeps an unknown elapsed time out of the stored value", context do
      assert {:ok, observation} =
               ingest(context, %{
                 elapsed: %{seconds: nil, source: "unknown"},
                 unknown_fields: ["elapsed"]
               })

      assert observation.elapsed == %{seconds: nil, source: :unknown}
      assert "elapsed" in observation.unknown_fields

      row = Repo.get!(AgentRuntimeObservation, observation.observation_id)
      assert row.elapsed_seconds == nil
    end

    test "records token counters when available and labels them when absent", context do
      assert {:ok, present} =
               ingest(context, %{
                 event_key: "event-tokens-present",
                 sequence: 1,
                 tokens: %{input: 90, output: 10, total: 100, source: "provider_fact"},
                 estimated_cost: unknown_cost(),
                 unknown_fields: ["estimated_cost"]
               })

      assert present.tokens == %{input: 90, output: 10, total: 100, source: :provider_fact}

      assert {:ok, absent} =
               ingest(context, %{
                 event_key: "event-tokens-absent",
                 sequence: 2,
                 tokens: unknown_tokens(),
                 estimated_cost: unknown_cost(),
                 unknown_fields: ["tokens", "estimated_cost"]
               })

      assert absent.tokens == %{input: nil, output: nil, total: nil, source: :unknown}
      assert "tokens" in absent.unknown_fields

      row = Repo.get!(AgentRuntimeObservation, absent.observation_id)
      assert row.total_tokens == nil
      assert row.input_tokens == nil
      assert row.output_tokens == nil
    end

    test "records an estimated cost only with the basis it was calculated from", context do
      assert {:ok, observation} = ingest(context, %{sequence: 1})

      assert observation.estimated_cost.source == :local_estimate
      assert observation.estimated_cost.basis.input_tokens == observation.tokens.input
      assert observation.estimated_cost.basis.output_tokens == observation.tokens.output

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-basisless",
                 sequence: 2,
                 estimated_cost: %{
                   amount: "0.0054",
                   currency: "USD",
                   basis: nil,
                   source: "local_estimate"
                 }
               })

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-mismatched-basis",
                 sequence: 2,
                 estimated_cost: %{
                   amount: "0.0054",
                   currency: "USD",
                   basis: observation_estimate_basis(%{input_tokens: 7}),
                   source: "local_estimate"
                 }
               })

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-other-model",
                 sequence: 2,
                 estimated_cost: %{
                   amount: "0.0054",
                   currency: "USD",
                   basis: observation_estimate_basis(%{model: "another-model"}),
                   source: "local_estimate"
                 }
               })
    end

    test "never presents an estimate as a provider invoice", context do
      assert {:error, :invalid_response} =
               ingest(context, %{
                 estimated_cost: %{
                   amount: "0.0054",
                   currency: "USD",
                   basis: observation_estimate_basis(),
                   source: "provider_fact"
                 }
               })
    end

    test "keeps a cost that is not calculable unknown rather than zero", context do
      assert {:ok, observation} =
               ingest(context, %{
                 tokens: %{input: nil, output: nil, total: 1_500, source: "worker_observed"},
                 estimated_cost: unknown_cost(),
                 unknown_fields: ["tokens.input", "tokens.output", "estimated_cost"]
               })

      assert observation.estimated_cost == %{
               amount: nil,
               currency: nil,
               basis: nil,
               source: :unknown
             }

      refute observation.estimated_cost.amount == Decimal.new(0)
      assert "estimated_cost" in observation.unknown_fields

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-cost-without-counts",
                 tokens: unknown_tokens(),
                 unknown_fields: ["tokens"]
               })
    end

    test "records the applicable quota buckets and refuses a silent empty set", context do
      assert {:ok, applicable} =
               ingest(context, %{
                 sequence: 1,
                 quota: %{
                   buckets: [
                     observation_quota_bucket(),
                     observation_quota_bucket(%{
                       id: "model-bucket",
                       scope: "model_specific",
                       model: "codex-test-model"
                     })
                   ],
                   source: "provider_fact"
                 }
               })

      assert applicable.quota.source == :provider_fact

      assert applicable.quota.buckets == [
               %{id: "general", scope: "general", model: nil},
               %{id: "model-bucket", scope: "model_specific", model: "codex-test-model"}
             ]

      assert {:ok, unknown} =
               ingest(context, %{
                 event_key: "event-quota-unknown",
                 sequence: 2,
                 quota: %{buckets: [], source: "unknown"},
                 unknown_fields: ["quota"]
               })

      assert unknown.quota == %{buckets: [], source: :unknown}
      refute unknown.quota.source == :provider_fact
      assert "quota" in unknown.unknown_fields

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-quota-empty-fact",
                 sequence: 3,
                 quota: %{buckets: [], source: "provider_fact"}
               })
    end

    test "records each status and keeps a pause resumable", context do
      states = [
        {"available", nil, "provider_fact", :available, nil},
        {"constrained", nil, "provider_fact", :constrained, nil},
        {"paused", "quota_exhausted", "provider_fact", :paused, :quota_exhausted},
        {"unknown", nil, "unknown", :unknown, nil}
      ]

      for {{state, reason, source, expected_state, expected_reason}, index} <-
            Enum.with_index(states, 1) do
        unknown_fields = if state == "unknown", do: ["status"], else: []

        assert {:ok, observation} =
                 ingest(context, %{
                   event_key: "event-status-#{state}",
                   sequence: index,
                   observed_at: DateTime.add(@now, index * 10, :second),
                   status: %{state: state, pause_reason: reason, source: source},
                   unknown_fields: unknown_fields
                 })

        assert observation.status.state == expected_state
        assert observation.status.pause_reason == expected_reason
      end

      assert {:ok, observations} =
               RuntimeObservations.list_observations(
                 context.account,
                 context.session.session_id
               )

      paused = Enum.find(observations, &(&1.status.state == :paused))
      assert paused.status.pause_reason == :quota_exhausted
      assert paused.estimated_cost.source == :local_estimate

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-terminal-pause",
                 sequence: 5,
                 status: %{state: "paused", pause_reason: nil, source: "provider_fact"}
               })

      assert {:error, :invalid_response} =
               ingest(context, %{
                 event_key: "event-known-unknown",
                 sequence: 5,
                 status: %{state: "unknown", pause_reason: nil, source: "provider_fact"}
               })
    end

    test "labels every stored value from one constrained vocabulary", context do
      assert ObservationAdapter.source_labels() ==
               ~w(provider_fact worker_observed local_estimate unknown)

      assert {:ok, first} =
               ingest(context, %{
                 event_key: "event-labels-one",
                 sequence: 1,
                 elapsed: %{seconds: 42, source: "worker_observed"},
                 tokens: %{input: nil, output: nil, total: 900, source: "provider_fact"},
                 estimated_cost: unknown_cost(),
                 unknown_fields: ["tokens.input", "tokens.output", "estimated_cost"]
               })

      assert {:ok, second} = ingest(context, %{event_key: "event-labels-two", sequence: 2})

      labels =
        [first, second]
        |> Enum.flat_map(fn observation ->
          [
            observation.elapsed.source,
            observation.tokens.source,
            observation.estimated_cost.source,
            observation.quota.source,
            observation.status.source
          ]
        end)
        |> MapSet.new()

      assert labels ==
               MapSet.new([:provider_fact, :worker_observed, :local_estimate, :unknown])
    end

    test "never lets an unknown value read as zero, unlimited, or exhausted", context do
      assert {:ok, observation} =
               ingest(context, %{
                 elapsed: %{seconds: nil, source: "unknown"},
                 tokens: unknown_tokens(),
                 estimated_cost: unknown_cost(),
                 quota: %{buckets: [], source: "unknown"},
                 status: %{state: "unknown", pause_reason: nil, source: "unknown"},
                 unknown_fields: ["elapsed", "tokens", "estimated_cost", "quota", "status"]
               })

      assert observation.elapsed.seconds == nil
      assert observation.tokens.total == nil
      assert observation.estimated_cost.amount == nil
      assert observation.quota.buckets == []
      assert observation.status.state == :unknown
      assert observation.status.pause_reason == nil

      assert Enum.sort(observation.unknown_fields) ==
               ~w(elapsed estimated_cost quota status tokens)

      row = Repo.get!(AgentRuntimeObservation, observation.observation_id)
      assert row.elapsed_seconds == nil
      assert row.total_tokens == nil
      assert row.estimated_cost_amount == nil
      assert row.estimated_cost_currency == nil
      assert row.quota_refs == %{"items" => []}
      assert row.quota_source == "unknown"
    end
  end

  describe "shared consumer contract" do
    test "observes a support assistant and a working agent identically", context do
      support =
        runtime_observation_context_fixture(%{
          now: @now,
          consumer: :support_assistant,
          consumer_ref: "conversation-observed"
        })

      attrs = %{event_key: "event-shared", sequence: 1}

      assert {:ok, agent_observation} = ingest(context, attrs)
      assert {:ok, support_observation} = ingest(support, attrs)

      assert context.session.consumer == :working_agent
      assert support.session.consumer == :support_assistant

      assert shared(agent_observation) == shared(support_observation)
    end
  end

  describe "adapter contract" do
    test "refuses adapter output outside the exact minimized allowlist", context do
      assert {:error, :invalid_response} =
               ingest_raw(context, Map.put(observation_adapter_result(), :prompt, "secret"))

      assert {:error, :invalid_response} =
               ingest_raw(context, Map.delete(observation_adapter_result(), :status))

      assert {:error, :invalid_response} =
               ingest_raw(
                 context,
                 observation_adapter_result(%{elapsed: %{seconds: 5, source: "provider_fact"}})
               )

      assert {:error, :invalid_response} =
               ingest_raw(
                 context,
                 observation_adapter_result(%{source_version: "unverified-client"})
               )

      assert {:error, :invalid_response} =
               ingest_raw(context, observation_adapter_result(%{provider: "another_provider"}))

      assert {:error, :invalid_response} =
               ingest_raw(context, observation_adapter_result(%{sequence: 0}))
    end

    test "refuses an oversized adapter payload", context do
      buckets =
        for index <- 1..ObservationAdapter.max_buckets() do
          observation_quota_bucket(%{
            id: String.duplicate("b", 250) <> "-#{index}",
            scope: "model_specific",
            model: String.duplicate("m", 255)
          })
        end

      assert {:error, :invalid_response} =
               ingest(context, %{quota: %{buckets: buckets, source: "provider_fact"}})

      assert {:error, :invalid_response} =
               ingest(context, %{
                 quota: %{
                   buckets: [
                     observation_quota_bucket()
                     | Enum.take(buckets, ObservationAdapter.max_buckets())
                   ],
                   source: "provider_fact"
                 }
               })
    end

    test "refuses credential-shaped and identifying adapter content", context do
      assert {:error, :invalid_response} =
               ingest(context, %{event_key: "run-Bearer sk-livetokenvalue1234"})

      assert {:error, :invalid_response} =
               ingest(context, %{
                 quota: %{
                   buckets: [observation_quota_bucket(%{id: "owner@example.com"})],
                   source: "provider_fact"
                 }
               })

      assert {:error, :invalid_response} =
               ingest(context, %{
                 estimated_cost: %{
                   amount: "0.0054",
                   currency: "USD",
                   basis: observation_estimate_basis(%{price_source: "sk-abcdefgh12345678"}),
                   source: "local_estimate"
                 }
               })
    end

    test "refuses adapter output that echoes the worker-local profile", context do
      assert {:error, :invalid_response} =
               ingest(context, %{event_key: "event-" <> @profile_ref})

      assert {:error, :invalid_response} =
               ingest(context, %{
                 quota: %{
                   buckets: [observation_quota_bucket(%{id: @profile_ref})],
                   source: "provider_fact"
                 }
               })
    end

    test "stores only the minimized observation columns", _context do
      %{rows: rows} =
        Repo.query!("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'agent_runtime_observations'
        """)

      assert rows |> List.flatten() |> Enum.sort() == Enum.sort(@minimized_columns)
    end

    test "calls the adapter deterministically with the pinned consumer scope", context do
      assert {:ok, _observation} = ingest(context, %{})

      assert_receive {:observation_fetch, account, connection, scope}
      assert account.id == context.account.id
      assert connection.id == context.connection.id
      assert connection.worker_profile_ref == @profile_ref
      assert scope[:consumer] == :working_agent
      assert scope[:consumer_ref] == context.session.consumer_ref

      assert {:error, :worker_unavailable} =
               RuntimeObservations.ingest(context.account, context.session.session_id,
                 adapter: ObservationAdapterDouble,
                 adapter_result: {:error, :worker_disconnected},
                 now: @ingested_at
               )

      assert {:error, :incompatible} =
               RuntimeObservations.ingest(context.account, context.session.session_id,
                 adapter: ObservationAdapterDouble,
                 adapter_result: {:error, :unsupported_capability},
                 now: @ingested_at
               )
    end

    test "scopes one authenticated observation request to the pinned consumer", context do
      connection = %{
        worker_id: Ecto.UUID.generate(),
        worker_profile_ref: @profile_ref,
        provider: "openai_codex",
        authentication_mode: "chatgpt",
        worker: %{device_workspace_id: Ecto.UUID.generate()}
      }

      account = %{id: context.account.id}
      result = observation_adapter_result(%{event_key: "event-rpc"})

      assert {:ok, observed} =
               ObservationAdapter.RPC.observe(account, connection,
                 rpc: ObservationAdapterDouble,
                 rpc_result: {:ok, result},
                 consumer: :working_agent,
                 consumer_ref: "run-rpc",
                 notify: self()
               )

      assert observed.event_key == "event-rpc"

      assert_receive {:observation_rpc_request, account_id, workspace_id, worker_id,
                      "observation/1", params}

      assert account_id == context.account.id
      assert workspace_id == connection.worker.device_workspace_id
      assert worker_id == connection.worker_id
      assert params["operation"] == "observe"
      assert params["connection_ref"] == @profile_ref
      assert params["consumer"] == "working_agent"
      assert params["consumer_ref"] == "run-rpc"

      assert {:error, :invalid_request} =
               ObservationAdapter.RPC.observe(account, connection,
                 rpc: ObservationAdapterDouble,
                 rpc_result: {:ok, result}
               )

      assert {:error, :worker_unavailable} =
               ObservationAdapter.RPC.observe(account, connection,
                 rpc: ObservationAdapterDouble,
                 rpc_result: {:error, :worker_disconnected},
                 consumer: :support_assistant,
                 consumer_ref: "conversation-rpc"
               )
    end
  end

  describe "codex notification ingestion" do
    test "treats an admitted notification as a complete refetch trigger" do
      parent = self()

      {:ok, handler} =
        ObservationAdapter.Codex.start_link(
          account: %{},
          connection: notification_connection(),
          adapter: ObservationAdapterDouble,
          fetch_options: [adapter_result: {:ok, observation_adapter_result()}],
          deliver: fn delivery -> send(parent, {:observation_delivery, delivery}) end
        )

      server_name = {:global, {__MODULE__, make_ref()}}

      {:ok, adapter} =
        CodexAppServerFixtures.start_adapter(self(),
          notification_target: handler,
          name: server_name,
          worker_profile_ref: @profile_ref
        )

      process = CodexAppServerFixtures.receive_handshake().process
      assert :ok = ObservationAdapter.Codex.bind_app_server(handler, server_name)

      CodexAppServerProcessDouble.notify(process, "thread/tokenUsage/updated", %{
        "threadId" => "thread-local",
        "tokenUsage" => %{"totalTokens" => 1_500}
      })

      assert_receive {:observation_delivery, usage}
      assert usage.connection_ref == @profile_ref
      assert usage.trigger == :complete_observation_refetch
      assert {:ok, refetched} = usage.result
      assert refetched.tokens.total == 1_500
      refute Map.has_key?(refetched, :threadId)

      CodexAppServerProcessDouble.notify(process, "account/rateLimits/updated", %{
        "rateLimits" => %{"limitId" => "codex"}
      })

      assert_receive {:observation_delivery, limits}
      assert {:ok, _observation} = limits.result

      CodexAppServerProcessDouble.notify(process, "thread/tokenUsage/updated", %{
        "threadId" => "thread-local",
        "tokenUsage" => "not-a-payload"
      })

      assert_receive {:observation_delivery, malformed}
      assert malformed.result == {:error, :invalid_response}

      assert ObservationAdapter.Codex.handle_notification("thread/started", %{}) ==
               {:error, :invalid_response}

      on_exit(fn ->
        CodexAppServer.stop(adapter)
        if Process.alive?(handler), do: GenServer.stop(handler)
      end)
    end

    test "accepts notifications only from the App Server it is bound to" do
      parent = self()

      {:ok, handler} =
        ObservationAdapter.Codex.start_link(
          account: %{},
          connection: notification_connection(),
          adapter: ObservationAdapterDouble,
          fetch_options: [adapter_result: {:ok, observation_adapter_result()}],
          deliver: fn delivery -> send(parent, {:observation_delivery, delivery}) end
        )

      assert {:error, :invalid_request} =
               ObservationAdapter.Codex.bind_app_server(handler, nil)

      {:ok, mismatched} =
        CodexAppServerFixtures.start_adapter(self(),
          notification_target: handler,
          worker_profile_ref: "profile-other-boundary"
        )

      mismatched_process = CodexAppServerFixtures.receive_handshake().process

      assert {:error, :invalid_request} =
               ObservationAdapter.Codex.bind_app_server(handler, mismatched)

      CodexAppServerProcessDouble.notify(mismatched_process, "thread/tokenUsage/updated", %{
        "threadId" => "thread-local",
        "tokenUsage" => %{"totalTokens" => 1}
      })

      refute_receive {:observation_delivery, _delivery}, 50

      on_exit(fn ->
        CodexAppServer.stop(mismatched)
        if Process.alive?(handler), do: GenServer.stop(handler)
      end)
    end
  end

  describe "detached connection" do
    test "preserves a detached session's history and refuses further ingestion", context do
      for sequence <- 1..2 do
        assert {:ok, _observation} =
                 ingest(context, %{
                   event_key: "event-pre-detach-#{sequence}",
                   sequence: sequence,
                   observed_at: DateTime.add(@now, sequence * 30, :second)
                 })
      end

      # Reach the detached state the way deleting a personal connection does,
      # through the connection's own ON DELETE SET NULL.
      assert {1, nil} =
               Repo.delete_all(
                 from connection in PersonalAIConnection,
                   where: connection.id == ^context.connection.id
               )

      assert Repo.get!(AIRuntimeSession, context.session.session_id).connection_id == nil

      assert {:error, :not_found} =
               ingest(context, %{
                 event_key: "event-after-detach",
                 sequence: 3,
                 observed_at: DateTime.add(@now, 120, :second)
               })

      assert Repo.aggregate(AgentRuntimeObservation, :count) == 2

      assert {:ok, observations} =
               RuntimeObservations.list_observations(
                 context.account,
                 context.session.session_id
               )

      assert Enum.map(observations, & &1.sequence) == [1, 2]

      assert Enum.map(observations, & &1.event_key) == [
               "event-pre-detach-1",
               "event-pre-detach-2"
             ]

      assert {:ok, latest} =
               RuntimeObservations.latest_observation(
                 context.account,
                 context.session.session_id
               )

      assert latest.sequence == 2
      assert latest.event_key == "event-pre-detach-2"
    end
  end

  describe "session scope" do
    test "refuses a session outside the requesting account", context do
      other = runtime_observation_context_fixture(%{now: @now})

      assert {:error, :not_found} =
               RuntimeObservations.ingest(context.account, other.session.session_id,
                 adapter: ObservationAdapterDouble,
                 adapter_result: {:ok, observation_adapter_result()},
                 now: @ingested_at
               )

      assert {:error, :not_found} =
               RuntimeObservations.list_observations(
                 context.account,
                 other.session.session_id
               )

      assert {:error, :not_found} =
               RuntimeObservations.ingest(context.account, Ecto.UUID.generate(),
                 adapter: ObservationAdapterDouble,
                 adapter_result: {:ok, observation_adapter_result()},
                 now: @ingested_at
               )

      assert {:error, :invalid_request} =
               RuntimeObservations.list_observations(context.account, "not-an-id")
    end
  end

  defp ingest(context, attrs) do
    ingest_raw(context, observation_adapter_result(attrs))
  end

  defp ingest_raw(context, result) do
    RuntimeObservations.ingest(context.account, context.session.session_id,
      adapter: ObservationAdapterDouble,
      adapter_result: {:ok, result},
      now: @ingested_at,
      notify: self()
    )
  end

  defp insert_row(context, attrs) do
    {:ok, result} =
      ObservationAdapter.validate_result(observation_adapter_result(attrs), "openai_codex")

    row_attrs =
      result
      |> AgentRuntimeObservation.to_attrs()
      |> Map.merge(%{
        account_id: context.account.id,
        session_id: context.session.session_id
      })

    %AgentRuntimeObservation{}
    |> AgentRuntimeObservation.create_changeset(row_attrs)
    |> Repo.insert()
  end

  defp notification_connection do
    %{
      worker_profile_ref: @profile_ref,
      provider: "openai_codex",
      authentication_mode: "chatgpt"
    }
  end

  defp shared(observation), do: Map.drop(observation, [:observation_id, :session_id])

  defp unknown_tokens, do: %{input: nil, output: nil, total: nil, source: "unknown"}

  defp unknown_cost, do: %{amount: nil, currency: nil, basis: nil, source: "unknown"}
end
