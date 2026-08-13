defmodule SddOrchestrator.ProjectAssistant.RuntimeAvailabilityTest do
  @moduledoc """
  specs/12-project-assistant Task 2 focused proof for
  `SddOrchestrator.ProjectAssistant.RuntimeAvailability`: AC-04 (no
  available connection or unavailable runtime surfaces safely, no fallback
  provider) and AC-22 (only the minimum normalized state, never exact quota,
  credentials, or provider diagnostics).
  """
  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{AIRuntimeSession, Quotas}
  alias SddOrchestrator.ProjectAssistant.RuntimeAvailability
  alias SddOrchestrator.QuotaAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]

  describe "no eligible connection" do
    test "a nil account (accountless device path) resolves to setup_needed without touching the runtime" do
      assert {:ok,
              %{
                state: :setup_needed,
                reason: :no_account,
                provider: nil,
                authentication_mode: nil
              }} =
               RuntimeAvailability.resolve(nil, "project_assistant:none", now: @now)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "an account with no personal connection resolves to setup_needed" do
      account = SddOrchestrator.AccountsFixtures.account_fixture()

      assert {:ok, %{state: :setup_needed, reason: :no_eligible_connection, provider: nil}} =
               RuntimeAvailability.resolve(account, "project_assistant:p1", now: @now)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "more than one active connection resolves to setup_needed rather than picking one" do
      %{account: account, worker: worker} = personal_ai_connection_fixture(%{label: "First"})
      personal_ai_connection_fixture(%{account: account, worker: worker, label: "Second"})

      assert {:ok, %{state: :setup_needed, reason: :no_eligible_connection, provider: nil}} =
               RuntimeAvailability.resolve(account, "project_assistant:p1", now: @now)

      # No fallback: neither connection was ever pinned to a session.
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  describe "available" do
    test "an eligible connection with a current catalog pins and reports available" do
      context = runtime_session_context_fixture(%{now: @now})

      assert {:ok, result} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p1", now: @now)

      assert result.state == :available
      assert result.provider == "openai_codex"
      assert result.authentication_mode == "chatgpt"
      assert result.model == "codex-test-model"
      assert result.effort == "medium"
      assert is_binary(result.session_id)
      assert Repo.aggregate(AIRuntimeSession, :count) == 1
    end

    test "resolving again for the same consumer reference reuses the same session idempotently" do
      context = runtime_session_context_fixture(%{now: @now})
      ref = "project_assistant:p1"

      assert {:ok, %{session_id: id1}} =
               RuntimeAvailability.resolve(context.account, ref, now: @now)

      assert {:ok, %{session_id: id2}} =
               RuntimeAvailability.resolve(context.account, ref, now: @now)

      assert id1 == id2
      assert Repo.aggregate(AIRuntimeSession, :count) == 1
    end

    test "different projects for the same participant pin independent sessions" do
      context = runtime_session_context_fixture(%{now: @now})

      assert {:ok, %{session_id: id1}} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p1", now: @now)

      assert {:ok, %{session_id: id2}} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p2", now: @now)

      refute id1 == id2
      assert Repo.aggregate(AIRuntimeSession, :count) == 2
    end
  end

  describe "unavailable" do
    test "an incompatible connection resolves to unavailable with a safe typed reason" do
      %{account: account} =
        personal_ai_connection_fixture(%{availability: "incompatible"})

      assert {:ok, %{state: :unavailable, reason: :incompatible, provider: "openai_codex"}} =
               RuntimeAvailability.resolve(account, "project_assistant:p1", now: @now)

      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  describe "temporarily limited" do
    test "exhausted quota without paid-continuation approval reports temporarily_limited, never a fallback pin" do
      context = runtime_session_context_fixture(%{now: @now})
      replace_quota(context, exhausted_bucket())

      assert {:ok, %{state: :temporarily_limited, reason: reason, provider: "openai_codex"}} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p1", now: @now)

      assert is_atom(reason)
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  describe "no quota, credential, or provider-diagnostic field ever crosses this boundary" do
    test "the available result carries only safe fields" do
      context = runtime_session_context_fixture(%{now: @now})

      assert {:ok, result} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p1", now: @now)

      assert Enum.sort(Map.keys(result)) ==
               Enum.sort([
                 :state,
                 :provider,
                 :authentication_mode,
                 :model,
                 :effort,
                 :session_id,
                 :pinned_at
               ])
    end

    test "the temporarily-limited result carries no quota, credit, spend, or credential field" do
      context = runtime_session_context_fixture(%{now: @now})
      replace_quota(context, exhausted_bucket())

      assert {:ok, result} =
               RuntimeAvailability.resolve(context.account, "project_assistant:p1", now: @now)

      forbidden = [:quota, :credits, :spend, :connection_id, :worker_profile_ref, :consumer_ref]
      assert Enum.all?(forbidden, &(not Map.has_key?(result, &1)))
    end
  end

  defp replace_quota(context, bucket) do
    result = quota_adapter_result(%{retrieved_at: @now, buckets: [bucket]})

    assert {:ok, _quota} =
             Quotas.refresh(context.account, context.connection.id,
               adapter: QuotaAdapterDouble,
               adapter_result: {:ok, result},
               now: @now,
               ttl_seconds: 300
             )
  end

  defp exhausted_bucket do
    quota_bucket(%{
      primary_window: %{
        used_percent: 100,
        resets_at: ~U[2026-08-03 13:00:00Z],
        duration_minutes: 300,
        unknown_fields: []
      },
      paid_continuation: "available",
      unknown_fields: [
        "secondary_window",
        "spend_control",
        "spend_control_reached",
        "limit_reached_reason"
      ]
    })
  end
end
