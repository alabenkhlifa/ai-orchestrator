defmodule SddOrchestrator.AIRuntime.RuntimeSessionsTest do
  @moduledoc "Task 4 proof for immutable provider-neutral runtime-session pinning."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    PersonalAIConnection,
    PersonalConnections,
    Quotas,
    RuntimeSessions
  }

  alias SddOrchestrator.QuotaAdapterDouble
  alias SddOrchestrator.QuotaPolicyAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]
  @catalog_expiry DateTime.add(~U[2026-08-03 12:00:00Z], 300, :second)

  setup do
    runtime_session_context_fixture(%{now: @now, worker_profile_ref: "profile-secret"})
  end

  describe "immutable pinned configuration" do
    test "pins one support conversation to a proven configuration and provenance", context do
      assert {:ok, session} =
               pin(context, %{consumer: :support_assistant, consumer_ref: "conversation-1"})

      assert session.consumer == :support_assistant
      assert session.consumer_ref == "conversation-1"
      assert session.connection_id == context.connection.id
      assert session.provider == "openai_codex"
      assert session.authentication_mode == "chatgpt"
      assert session.model == "codex-test-model"
      assert session.effort == "medium"
      assert session.configuration_version == 1
      assert session.opt_ins == []
      assert session.spending_ceiling == nil
      assert session.pinned_at == @now

      assert session.provenance == %{
               snapshot_id: context.catalog.snapshot_id,
               source: "official_client",
               method: "model/list",
               version: context.catalog.provenance.version,
               retrieved_at: @now,
               expires_at: @catalog_expiry
             }

      assert {:ok, ^session} =
               RuntimeSessions.fetch_for_consumer(
                 context.account,
                 :support_assistant,
                 "conversation-1"
               )
    end

    test "pins a working-agent run through the identical contract", context do
      assert {:ok, session} =
               pin(context, %{consumer: :working_agent, consumer_ref: "run-1"})

      assert session.consumer == :working_agent
      assert session.connection_id == context.connection.id
      assert session.model == "codex-test-model"
      assert session.effort == "medium"
      assert session.configuration_version == 1
      assert session.provenance.snapshot_id == context.catalog.snapshot_id
      assert {:ok, ^session} = RuntimeSessions.get_session(context.account, session.session_id)
    end

    test "a later catalog refresh never changes an active pin", context do
      assert {:ok, session} = pin(context, %{consumer_ref: "run-pinned"})

      later = DateTime.add(@now, 120, :second)

      refreshed =
        model_catalog_snapshot_fixture(%{
          connection_fixture: context,
          now: later,
          models: [model_catalog_model(%{display_name: "Renamed Model"})]
        })

      refute refreshed.catalog.snapshot_id == session.provenance.snapshot_id

      assert {:ok, reloaded} = RuntimeSessions.get_session(context.account, session.session_id)
      assert reloaded == session
      assert reloaded.provenance.snapshot_id == context.catalog.snapshot_id
      assert reloaded.provenance.retrieved_at == @now
    end

    test "the database refuses every reconfiguration of a pinned session", context do
      assert {:ok, session} = pin(context, %{consumer_ref: "run-frozen"})

      record = Repo.get!(AIRuntimeSession, session.session_id)

      frozen = [
        connection_id: Ecto.UUID.generate(),
        consumer_kind: "support_assistant",
        consumer_ref: "another-run",
        provider: "another_provider",
        authentication_mode: "api_key",
        model: "another-model",
        reasoning_effort: "high",
        configuration_version: 2,
        catalog_snapshot_ref: Ecto.UUID.generate(),
        catalog_source: "another_source",
        catalog_source_method: "another/method",
        catalog_source_version: "another-version",
        catalog_retrieved_at: DateTime.add(@now, 60, :second),
        catalog_expires_at: DateTime.add(@now, 900, :second),
        opt_ins: %{"items" => [%{"id" => "forced"}]},
        spending_ceiling_amount: Decimal.new("5.00"),
        spending_ceiling_currency: "EUR",
        pinned_at: DateTime.add(@now, 60, :second)
      ]

      for {field, value} <- frozen do
        changeset =
          record
          |> Ecto.Changeset.change([{field, value}])
          |> Ecto.Changeset.check_constraint(field,
            name: :ai_runtime_sessions_immutable_configuration
          )

        assert {:error, rejected} = Repo.update(changeset)
        assert rejected.errors[field]
      end

      assert Repo.get!(AIRuntimeSession, session.session_id) == record
    end
  end

  describe "connection, model, and effort eligibility" do
    test "requires one explicitly selected eligible connection", context do
      assert {:error, :connection_required} = pin(context, %{connection_id: nil})
      assert {:error, :not_found} = pin(context, %{connection_id: Ecto.UUID.generate()})
      assert {:error, :invalid_request} = pin(context, %{connection_id: "not-a-uuid"})

      other = runtime_session_context_fixture(%{now: @now})

      assert {:error, :not_found} =
               RuntimeSessions.pin_session(
                 context.account,
                 runtime_session_request(other),
                 now: @now
               )

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "refuses unavailable, incompatible, revoking, and revoked connections", context do
      for {availability, expected} <- [
            {"unavailable", :unavailable},
            {"incompatible", :incompatible}
          ] do
        ineligible = ineligible_connection(context, availability)

        assert {:error, ^expected} = pin(context, %{connection_id: ineligible.id})
      end

      assert {:ok, _connection} =
               PersonalConnections.request_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoking} = pin(context)

      assert {:ok, _connection} =
               PersonalConnections.acknowledge_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoked} = pin(context)
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "refuses an unproven model, an unsupported effort, and unknown compatibility",
         context do
      assert {:error, :unknown_compatibility} = pin(context, %{model: "unproven-model"})
      assert {:error, :unknown_compatibility} = pin(context, %{effort: "extreme"})
      assert {:error, :invalid_selection} = pin(context, %{model: ""})
      assert {:error, :invalid_selection} = pin(context, %{effort: " medium "})
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "refuses a missing catalog and an expired catalog provenance", context do
      unknown =
        personal_ai_connection_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "No Catalog",
          worker_profile_ref: "profile-no-catalog"
        })

      assert {:error, :unknown} = pin(context, %{connection_id: unknown.connection.id})

      stale_at = DateTime.add(@catalog_expiry, 1, :second)

      assert {:error, :stale} =
               RuntimeSessions.pin_session(
                 context.account,
                 runtime_session_request(context),
                 now: stale_at
               )

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  describe "explicit opt-ins and spending ceilings" do
    test "pins the scarce-model opt-in that was in force and refuses a missing one", context do
      assert {:error, {:pause, :scarce_model_opt_in_required}} =
               pin(context, %{scarcity: :scarce, consumer_ref: "run-scarce"})

      choice = quota_policy_choice(context, :scarce_model, %{now: @now})

      assert {:ok, session} =
               pin(context, %{
                 scarcity: :scarce,
                 choices: [choice],
                 consumer_ref: "run-scarce"
               })

      assert session.opt_ins == [
               %{
                 id: choice.id,
                 kind: :scarce_model,
                 bucket_id: nil,
                 cost_boundary: :scarce_model,
                 valid_from: @now,
                 expires_at: DateTime.add(@now, 900, :second)
               }
             ]
    end

    test "pins the model-specific and paid-continuation opt-ins the policy required",
         context do
      replace_quota(context, [model_bucket("codex-test-model", "model-bucket")])

      assert {:error, {:pause, :model_specific_quota_opt_in_required}} =
               pin(context, %{consumer_ref: "run-model-bucket"})

      model_choice = quota_policy_choice(context, :model_specific_quota, %{now: @now})

      assert {:ok, model_session} =
               pin(context, %{choices: [model_choice], consumer_ref: "run-model-bucket"})

      assert Enum.map(model_session.opt_ins, & &1.id) == [model_choice.id]
      assert Enum.map(model_session.opt_ins, & &1.cost_boundary) == [:quota]

      replace_quota(context, [exhausted_bucket("available")])

      assert {:error, {:pause, :paid_continuation_approval_required}} =
               pin(context, %{consumer_ref: "run-paid"})

      paid_choice = quota_policy_choice(context, :provider_paid_continuation, %{now: @now})

      assert {:ok, paid_session} =
               pin(context, %{choices: [paid_choice], consumer_ref: "run-paid"})

      assert Enum.map(paid_session.opt_ins, & &1.id) == [paid_choice.id]
      assert Enum.map(paid_session.opt_ins, & &1.kind) == [:provider_paid_continuation]
      assert Enum.map(paid_session.opt_ins, & &1.bucket_id) == ["general"]
    end

    test "records an API-key ceiling and refuses a missing or inapplicable one", context do
      api_key = api_key_context(context)

      assert {:error, :spending_ceiling_required} =
               pin(api_key, %{spending_ceiling: nil})

      assert {:error, :spending_ceiling_not_applicable} =
               pin(context, %{spending_ceiling: %{amount: Decimal.new("25.00"), currency: "USD"}})

      assert {:ok, session} = pin(api_key, %{consumer_ref: "run-api-key"})

      assert session.authentication_mode == "api_key"
      assert session.spending_ceiling.currency == "USD"
      assert Decimal.compare(session.spending_ceiling.amount, Decimal.new("25")) == :eq
      assert Repo.get!(AIRuntimeSession, session.session_id).spending_ceiling_currency == "USD"
    end

    test "refuses an unbounded, negative, imprecise, or unlabelled ceiling", context do
      api_key = api_key_context(context)

      invalid = [
        %{amount: Decimal.new("0"), currency: "USD"},
        %{amount: Decimal.new("-5.00"), currency: "USD"},
        %{amount: Decimal.new("1.00005"), currency: "USD"},
        %{amount: Decimal.new("2000000.00"), currency: "USD"},
        %{amount: 25.5, currency: "USD"},
        %{amount: "not-a-number", currency: "USD"},
        %{amount: Decimal.new("25.00"), currency: "usd"},
        %{amount: Decimal.new("25.00"), currency: "dollars"}
      ]

      for ceiling <- invalid do
        assert {:error, :invalid_request} = pin(api_key, %{spending_ceiling: ceiling})
      end

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  describe "concurrent reuse and idempotent creation" do
    test "concurrent consumers reuse one connection without inheriting each other's state",
         context do
      api_key = api_key_context(context)
      choice = quota_policy_choice(context, :scarce_model, %{now: @now})

      assert {:ok, support} =
               pin(context, %{consumer: :support_assistant, consumer_ref: "conversation-a"})

      assert {:ok, agent} =
               pin(context, %{
                 consumer: :working_agent,
                 consumer_ref: "run-b",
                 scarcity: :scarce,
                 choices: [choice]
               })

      assert {:ok, funded} = pin(api_key, %{consumer_ref: "run-c"})

      assert support.connection_id == agent.connection_id
      refute support.session_id == agent.session_id
      assert support.opt_ins == []
      assert Enum.map(agent.opt_ins, & &1.id) == [choice.id]
      assert support.spending_ceiling == nil
      assert agent.spending_ceiling == nil
      assert funded.spending_ceiling.currency == "USD"
      refute funded.connection_id == support.connection_id

      assert {:ok, ^support} = RuntimeSessions.get_session(context.account, support.session_id)

      assert context.account
             |> RuntimeSessions.list_for_connection(context.connection.id)
             |> Enum.map(& &1.session_id)
             |> Enum.sort() == Enum.sort([support.session_id, agent.session_id])
    end

    test "re-pinning the same consumer is idempotent and never mutates the pin", context do
      request = runtime_session_request(context, %{consumer_ref: "run-idempotent"})

      assert {:ok, first} = RuntimeSessions.pin_session(context.account, request, now: @now)

      assert {:ok, second} =
               RuntimeSessions.pin_session(context.account, request,
                 now: DateTime.add(@now, 30, :second)
               )

      assert first == second
      assert Repo.aggregate(AIRuntimeSession, :count) == 1

      conflicts = [
        %{consumer_ref: "run-idempotent", effort: "high"},
        %{consumer_ref: "run-idempotent", scarcity: :scarce, choices: [scarce_choice(context)]}
      ]

      for attrs <- conflicts do
        assert {:error, :configuration_conflict} = pin(context, attrs)
      end

      assert {:ok, ^first} = RuntimeSessions.get_session(context.account, first.session_id)
      assert Repo.aggregate(AIRuntimeSession, :count) == 1

      assert {:ok, other_kind} =
               pin(context, %{consumer: :support_assistant, consumer_ref: "run-idempotent"})

      refute other_kind.session_id == first.session_id
    end
  end

  describe "shared consumer contract and minimized persistence" do
    test "both consumer kinds follow one connection, model, effort, and quota rule set",
         context do
      outcomes =
        for consumer <- [:support_assistant, :working_agent] do
          revoked = ineligible_connection(context, "unavailable")

          [
            pin(context, %{consumer: consumer, connection_id: nil}),
            pin(context, %{consumer: consumer, connection_id: Ecto.UUID.generate()}),
            pin(context, %{consumer: consumer, connection_id: revoked.id}),
            pin(context, %{consumer: consumer, model: "unproven-model"}),
            pin(context, %{consumer: consumer, effort: "extreme"}),
            pin(context, %{consumer: consumer, scarcity: :scarce}),
            pin(context, %{
              consumer: consumer,
              spending_ceiling: %{amount: Decimal.new("5.00"), currency: "USD"}
            })
          ]
        end

      assert [support_outcomes, agent_outcomes] = outcomes
      assert support_outcomes == agent_outcomes

      assert support_outcomes == [
               {:error, :connection_required},
               {:error, :not_found},
               {:error, :unavailable},
               {:error, :unknown_compatibility},
               {:error, :unknown_compatibility},
               {:error, {:pause, :scarce_model_opt_in_required}},
               {:error, :spending_ceiling_not_applicable}
             ]

      assert {:ok, support} = pin(context, %{consumer: :support_assistant})
      assert {:ok, agent} = pin(context, %{consumer: :working_agent})

      assert Map.drop(support, [:session_id, :consumer, :consumer_ref]) ==
               Map.drop(agent, [:session_id, :consumer, :consumer_ref])

      assert {:error, :invalid_consumer} = pin(context, %{consumer: :project_owner})

      assert {:error, :invalid_consumer} =
               RuntimeSessions.fetch_for_consumer(context.account, "auditor", "run-1")
    end

    test "persists only the approved minimized configuration fields", context do
      assert {:ok, session} = pin(context, %{consumer_ref: "run-minimized"})

      assert AIRuntimeSession.__schema__(:fields) |> Enum.sort() ==
               [
                 :account_id,
                 :authentication_mode,
                 :catalog_expires_at,
                 :catalog_retrieved_at,
                 :catalog_snapshot_ref,
                 :catalog_source,
                 :catalog_source_method,
                 :catalog_source_version,
                 :configuration_version,
                 :connection_id,
                 :consumer_kind,
                 :consumer_ref,
                 :id,
                 :inserted_at,
                 :model,
                 :opt_ins,
                 :pinned_at,
                 :provider,
                 :reasoning_effort,
                 :spending_ceiling_amount,
                 :spending_ceiling_currency,
                 :updated_at
               ]

      record = Repo.get!(AIRuntimeSession, session.session_id)

      refute contains_value?(Map.from_struct(record), "profile-secret")
      refute contains_value?(session, "profile-secret")
      refute inspect(record) =~ "profile-secret"

      assert {:error, :invalid_request} =
               pin(context, %{consumer_ref: "sk-live-abcdefgh1234"})

      assert {:error, :invalid_request} = pin(context, %{consumer_ref: "owner@example.com"})

      assert {:error, :invalid_request} =
               pin(context, %{consumer_ref: String.duplicate("r", 256)})
    end

    test "a policy adapter cannot smuggle a different selection or a skipped opt-in", context do
      request = runtime_session_request(context, %{consumer_ref: "run-rogue"})

      swapped =
        rogue_decision(context, %{model: "codex-alt-model"})

      assert {:error, :invalid_response} =
               RuntimeSessions.pin_session(context.account, request,
                 now: @now,
                 policy_adapter: QuotaPolicyAdapterDouble,
                 adapter_result: {:ok, swapped}
               )

      scarce_request =
        runtime_session_request(context, %{consumer_ref: "run-rogue", scarcity: :scarce})

      assert {:error, :invalid_response} =
               RuntimeSessions.pin_session(context.account, scarce_request,
                 now: @now,
                 policy_adapter: QuotaPolicyAdapterDouble,
                 adapter_result: {:ok, rogue_decision(context, %{})}
               )

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  defp pin(context, attrs \\ %{}) do
    RuntimeSessions.pin_session(
      context.account,
      runtime_session_request(context, attrs),
      now: @now
    )
  end

  defp api_key_context(context) do
    runtime_session_context_fixture(%{
      account: context.account,
      worker: context.worker,
      authentication_mode: "api_key",
      label: "API Key Codex",
      worker_profile_ref: "profile-api-key",
      now: @now
    })
  end

  defp ineligible_connection(context, availability) do
    fixture =
      personal_ai_connection_fixture(%{
        account: context.account,
        worker: context.worker,
        label: "Ineligible #{availability} #{System.unique_integer([:positive])}",
        worker_profile_ref: "profile-#{availability}-#{System.unique_integer([:positive])}"
      })

    fixture.connection
    |> PersonalAIConnection.update_changeset(%{availability: availability})
    |> Repo.update!()
  end

  defp scarce_choice(context), do: quota_policy_choice(context, :scarce_model, %{now: @now})

  defp rogue_decision(context, overrides) do
    Map.merge(
      %{
        decision: :proceed,
        reason: nil,
        connection_id: context.connection.id,
        model: "codex-test-model",
        effort: "medium",
        quota_snapshot_id: context.quota.snapshot_id,
        applicable_bucket_ids: ["general"],
        choice_ids: [],
        paid_continuation: false
      },
      overrides
    )
  end

  defp replace_quota(context, buckets) do
    result = quota_adapter_result(%{retrieved_at: @now, buckets: buckets})

    assert {:ok, quota} =
             Quotas.refresh(context.account, context.connection.id,
               adapter: QuotaAdapterDouble,
               adapter_result: {:ok, result},
               now: @now,
               ttl_seconds: 300
             )

    quota
  end

  defp model_bucket(model, id) do
    quota_bucket(%{
      id: id,
      scope: "model_specific",
      model: model,
      display_name: "Model-specific capacity"
    })
  end

  defp exhausted_bucket(paid_continuation) do
    quota_bucket(%{
      primary_window: %{
        used_percent: 100,
        resets_at: ~U[2026-08-03 13:00:00Z],
        duration_minutes: 300,
        unknown_fields: []
      },
      paid_continuation: paid_continuation,
      unknown_fields: [
        "secondary_window",
        "spend_control",
        "spend_control_reached",
        "limit_reached_reason"
      ]
    })
  end

  defp contains_value?(value, forbidden) when is_binary(value),
    do: String.contains?(value, forbidden)

  defp contains_value?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, forbidden))

  defp contains_value?(value, forbidden) when is_map(value),
    do: Enum.any?(Map.values(value), &contains_value?(&1, forbidden))

  defp contains_value?(_value, _forbidden), do: false
end
