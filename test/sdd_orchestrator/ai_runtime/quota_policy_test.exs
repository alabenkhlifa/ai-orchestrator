defmodule SddOrchestrator.AIRuntime.QuotaPolicyTest do
  @moduledoc "Task 10 proof for explicit quota and provider-paid-use choices."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{PersonalAIConnection, PersonalConnections, QuotaPolicy, Quotas}
  alias SddOrchestrator.QuotaAdapterDouble
  alias SddOrchestrator.QuotaPolicyAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]

  setup do
    quota_snapshot_fixture(%{now: @now})
  end

  describe "applicable quota and explicit choices" do
    test "proceeds on known general capacity without changing the selected boundary", context do
      request = quota_policy_request(context)

      assert {:ok, decision} = QuotaPolicy.evaluate(context.account, request, now: @now)

      assert decision == %{
               decision: :proceed,
               reason: nil,
               connection_id: context.connection.id,
               model: "codex-test-model",
               effort: "medium",
               quota_snapshot_id: context.quota.snapshot_id,
               applicable_bucket_ids: ["general"],
               choice_ids: [],
               paid_continuation: false
             }

      refute Map.has_key?(decision, :fallback)
      refute Map.has_key?(decision, :alternate_connection_id)
      refute Map.has_key?(decision, :alternate_model)
      refute Map.has_key?(decision, :alternate_effort)
    end

    test "ignores another model's bucket and requires opt-in for the exact model bucket",
         context do
      other = model_bucket("other-model", "other-bucket")
      matching = model_bucket("codex-test-model", "model-bucket")
      general = quota_bucket()

      quota = replace_quota(context, [general, other, matching])
      request = quota_policy_request(context)

      assert {:ok,
              %{
                decision: :pause,
                reason: :model_specific_quota_opt_in_required,
                applicable_bucket_ids: ["general", "model-bucket"]
              }} = QuotaPolicy.evaluate(context.account, request, now: @now)

      choice = quota_policy_choice(context, :model_specific_quota)
      request = quota_policy_request(context, %{choices: [choice]})

      assert {:ok, decision} = QuotaPolicy.evaluate(context.account, request, now: @now)
      assert decision.decision == :proceed
      assert decision.quota_snapshot_id == quota.snapshot_id
      assert decision.applicable_bucket_ids == ["general", "model-bucket"]
      assert decision.choice_ids == [choice.id]
      refute "other-bucket" in decision.applicable_bucket_ids
    end

    test "pauses when only nonmatching model capacity exists", context do
      replace_quota(context, [model_bucket("other-model", "other-bucket")])

      assert {:ok, %{decision: :pause, reason: :quota_unknown}} =
               QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)
    end

    test "requires an exact scarce-model opt-in and refuses unknown scarcity", context do
      unknown = quota_policy_request(context, %{scarcity: :unknown})

      assert {:ok, %{decision: :pause, reason: :scarcity_unknown}} =
               QuotaPolicy.evaluate(context.account, unknown, now: @now)

      scarce = quota_policy_request(context, %{scarcity: :scarce})

      assert {:ok, %{decision: :pause, reason: :scarce_model_opt_in_required}} =
               QuotaPolicy.evaluate(context.account, scarce, now: @now)

      choice = quota_policy_choice(context, :scarce_model)
      approved = quota_policy_request(context, %{scarcity: :scarce, choices: [choice]})

      assert {:ok, decision} = QuotaPolicy.evaluate(context.account, approved, now: @now)
      assert decision.decision == :proceed
      assert decision.choice_ids == [choice.id]
    end

    test "binds choices to the owner, connection, model, bucket, and current time", context do
      other_account = account_fixture()

      invalid_choices = [
        quota_policy_choice(context, :scarce_model, %{owner_account_id: other_account.id}),
        quota_policy_choice(context, :scarce_model, %{connection_id: Ecto.UUID.generate()}),
        quota_policy_choice(context, :scarce_model, %{model: "other-model"}),
        quota_policy_choice(context, :model_specific_quota, %{bucket_id: nil}),
        quota_policy_choice(context, :scarce_model, %{
          valid_from: DateTime.add(@now, -1_000, :second),
          expires_at: @now
        }),
        quota_policy_choice(context, :scarce_model, %{
          valid_from: DateTime.add(@now, 1, :second)
        })
      ]

      for choice <- invalid_choices do
        request = quota_policy_request(context, %{scarcity: :scarce, choices: [choice]})

        assert {:error, :invalid_request} =
                 QuotaPolicy.evaluate(context.account, request, now: @now)
      end
    end

    test "requires explicit paid continuation only after known capacity is exhausted", context do
      exhausted = exhausted_bucket("available")
      quota = replace_quota(context, [exhausted])

      assert {:ok,
              %{
                decision: :pause,
                reason: :paid_continuation_approval_required,
                paid_continuation: false
              }} =
               QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)

      choice = quota_policy_choice(context, :provider_paid_continuation)
      request = quota_policy_request(context, %{choices: [choice]})

      assert {:ok, decision} = QuotaPolicy.evaluate(context.account, request, now: @now)
      assert decision.decision == :proceed
      assert decision.quota_snapshot_id == quota.snapshot_id
      assert decision.paid_continuation
      assert decision.choice_ids == [choice.id]
    end

    test "never treats credits as paid consent and pauses on unavailable or unknown continuation",
         context do
      for {paid_state, reason} <- [
            {"available", :paid_continuation_approval_required},
            {"unavailable", :paid_continuation_unavailable},
            {"unknown", :paid_continuation_unknown}
          ] do
        replace_quota(context, [exhausted_bucket(paid_state)])

        assert {:ok, %{decision: :pause, reason: ^reason, paid_continuation: false}} =
                 QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)
      end
    end

    test "pauses instead of guessing unknown or provider-defined capacity", context do
      unknown =
        quota_bucket(%{
          primary_window: nil,
          unknown_fields: [
            "primary_window",
            "secondary_window",
            "paid_continuation",
            "spend_control",
            "spend_control_reached",
            "limit_reached_reason"
          ]
        })

      replace_quota(context, [unknown])

      assert {:ok, %{decision: :pause, reason: :quota_capacity_unknown}} =
               QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)

      provider_defined =
        quota_bucket(%{
          id: "provider-scope",
          scope: "provider_defined",
          model: nil,
          unknown_fields: [
            "scope",
            "model",
            "secondary_window",
            "paid_continuation",
            "spend_control",
            "spend_control_reached",
            "limit_reached_reason"
          ]
        })

      replace_quota(context, [provider_defined])

      assert {:ok, %{decision: :pause, reason: :provider_defined_quota_applicability_unknown}} =
               QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)
    end
  end

  describe "owner, lifecycle, and fail-closed boundaries" do
    test "normalizes missing and expired ChatGPT quota as resumable pauses", context do
      missing =
        personal_ai_connection_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "No quota",
          worker_profile_ref: "profile-no-quota"
        })

      assert {:ok, %{decision: :pause, reason: :quota_unknown, quota_snapshot_id: nil}} =
               QuotaPolicy.evaluate(
                 missing.account,
                 quota_policy_request(missing),
                 now: @now
               )

      assert {:ok, %{decision: :pause, reason: :quota_stale}} =
               QuotaPolicy.evaluate(
                 context.account,
                 quota_policy_request(context),
                 now: DateTime.add(@now, 301, :second)
               )
    end

    test "refuses revoked, revoking, unavailable, and cross-owner connections", context do
      assert {:ok, _connection} =
               PersonalConnections.request_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoking} =
               QuotaPolicy.evaluate(context.account, quota_policy_request(context), now: @now)

      unavailable =
        personal_ai_connection_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "Unavailable",
          worker_profile_ref: "profile-unavailable"
        })

      unavailable.connection
      |> PersonalAIConnection.update_changeset(%{availability: "unavailable"})
      |> Repo.update!()

      assert {:error, :unavailable} =
               QuotaPolicy.evaluate(
                 unavailable.account,
                 quota_policy_request(unavailable),
                 now: @now
               )

      assert {:error, :not_found} =
               QuotaPolicy.evaluate(account_fixture(), quota_policy_request(unavailable),
                 now: @now
               )
    end

    test "rechecks revocation after policy evaluation before returning a decision", context do
      request = quota_policy_request(context)
      assert {:ok, expected} = QuotaPolicy.evaluate(context.account, request, now: @now)

      assert {:error, :revoking} =
               QuotaPolicy.evaluate(context.account, request,
                 now: @now,
                 adapter: SddOrchestrator.RevokingQuotaPolicyAdapter,
                 adapter_result: {:ok, expected}
               )
    end

    test "rejects fallback fields, malformed values, credentials, and duplicate choices",
         context do
      choice = quota_policy_choice(context, :scarce_model, %{id: "same-choice"})

      invalid_requests = [
        Map.put(quota_policy_request(context), :fallback_model, "other-model"),
        quota_policy_request(context, %{model: "sk-secret12345678"}),
        quota_policy_request(context, %{effort: "Bearer worker-secret"}),
        quota_policy_request(context, %{choices: [choice, choice]}),
        quota_policy_request(context, %{connection_id: "not-a-uuid"}),
        quota_policy_request(context, %{choices: [%{unexpected: true}]})
      ]

      for request <- invalid_requests do
        assert {:error, :invalid_request} =
                 QuotaPolicy.evaluate(context.account, request, now: @now)
      end
    end

    test "API-key quota stays outside ChatGPT policy and enters strict cost reservation",
         context do
      api_context =
        personal_ai_connection_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "API key",
          authentication_mode: "api_key",
          worker_profile_ref: "profile-api-policy"
        })

      request = quota_policy_request(api_context, %{effort: "high"})

      assert {:ok, decision} = QuotaPolicy.evaluate(api_context.account, request, now: @now)

      assert decision == %{
               decision: :proceed_to_cost_reservation,
               reason: :cost_reservation_required,
               connection_id: api_context.connection.id,
               model: "codex-test-model",
               effort: "high",
               quota_snapshot_id: nil,
               applicable_bucket_ids: [],
               choice_ids: [],
               paid_continuation: false
             }

      chatgpt_paid_choice = quota_policy_choice(api_context, :provider_paid_continuation)
      request = quota_policy_request(api_context, %{choices: [chatgpt_paid_choice]})

      assert {:error, :invalid_request} =
               QuotaPolicy.evaluate(api_context.account, request, now: @now)
    end
  end

  describe "deterministic adapter contract" do
    test "passes a minimized exact context to the double and validates its decision", context do
      request = quota_policy_request(context)
      assert {:ok, expected} = QuotaPolicy.evaluate(context.account, request, now: @now)

      assert {:ok, ^expected} =
               QuotaPolicy.evaluate(context.account, request,
                 now: @now,
                 adapter: QuotaPolicyAdapterDouble,
                 adapter_result: {:ok, expected},
                 notify: self()
               )

      assert_received {:quota_policy_evaluate, adapter_context}
      assert adapter_context.account_id == context.account.id
      assert adapter_context.selection.effort == "medium"
      assert adapter_context.quota.snapshot_id == context.quota.snapshot_id
      refute inspect(adapter_context) =~ context.connection.worker_profile_ref

      changed_results = [
        Map.put(expected, :effort, "high"),
        Map.put(expected, :model, "other-model"),
        Map.put(expected, :connection_id, Ecto.UUID.generate()),
        Map.put(expected, :paid_continuation, true),
        Map.put(expected, :applicable_bucket_ids, [])
      ]

      for changed <- changed_results do
        assert {:error, :invalid_response} =
                 QuotaPolicy.evaluate(context.account, request,
                   now: @now,
                   adapter: QuotaPolicyAdapterDouble,
                   adapter_result: {:ok, changed}
                 )
      end

      assert {:error, :invalid_response} =
               QuotaPolicy.evaluate(context.account, request,
                 now: @now,
                 adapter: QuotaPolicyAdapterDouble,
                 adapter_result: {:ok, Map.put(expected, :provider_email, "owner@example.test")}
               )
    end

    test "does not let an adapter omit a required explicit choice", context do
      choice = quota_policy_choice(context, :scarce_model)
      request = quota_policy_request(context, %{scarcity: :scarce, choices: [choice]})
      assert {:ok, expected} = QuotaPolicy.evaluate(context.account, request, now: @now)

      assert {:error, :invalid_response} =
               QuotaPolicy.evaluate(context.account, request,
                 now: @now,
                 adapter: QuotaPolicyAdapterDouble,
                 adapter_result: {:ok, Map.put(expected, :choice_ids, [])}
               )
    end
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
    unknown_fields =
      ["secondary_window", "spend_control", "spend_control_reached", "limit_reached_reason"] ++
        if(paid_continuation == "unknown", do: ["paid_continuation"], else: [])

    quota_bucket(%{
      primary_window: %{
        used_percent: 100,
        resets_at: ~U[2026-08-03 13:00:00Z],
        duration_minutes: 300,
        unknown_fields: []
      },
      paid_continuation: paid_continuation,
      unknown_fields: unknown_fields
    })
  end
end

defmodule SddOrchestrator.RevokingQuotaPolicyAdapter do
  @moduledoc false

  @behaviour SddOrchestrator.AIRuntime.QuotaPolicyAdapter

  @impl true
  def evaluate(context, opts) do
    {:ok, _connection} =
      SddOrchestrator.AIRuntime.PersonalConnections.request_revocation(
        context.account_id,
        context.selection.connection_id,
        at: context.now
      )

    Keyword.fetch!(opts, :adapter_result)
  end
end
