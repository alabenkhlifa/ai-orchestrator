defmodule SddOrchestrator.AIRuntime.QuotaAdapter.CodexTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.AIRuntime.{CodexAppServer, QuotaAdapter}
  alias SddOrchestrator.AIRuntime.QuotaAdapter.Codex
  alias SddOrchestrator.AIRuntime.QuotaAdapter.CodexNotificationHandler
  alias SddOrchestrator.CodexAppServerFixtures
  alias SddOrchestrator.CodexAppServerProcessDouble

  @now ~U[2026-08-03 12:00:00Z]

  setup do
    {:ok, adapter} = CodexAppServerFixtures.start_adapter(self())
    handshake = CodexAppServerFixtures.receive_handshake()

    on_exit(fn -> CodexAppServer.stop(adapter) end)

    %{adapter: adapter, process: handshake.process}
  end

  test "uses exact nil account requests and preserves arbitrary buckets and safe facts",
       context do
    task = fetch_chatgpt(context.adapter)

    rate_request =
      CodexAppServerFixtures.receive_write(context.process, "account/rateLimits/read")

    assert rate_request["params"] == nil
    CodexAppServerProcessDouble.respond(context.process, rate_request["id"], rate_limits())

    usage_request = CodexAppServerFixtures.receive_write(context.process, "account/usage/read")
    assert usage_request["params"] == nil
    CodexAppServerProcessDouble.respond(context.process, usage_request["id"], usage())

    assert {:ok, result} = Task.await(task)
    assert result.status == "reported"
    assert result.authentication_mode == "chatgpt"
    assert result.source_methods == ["account/rateLimits/read", "account/usage/read"]
    assert result.retrieved_at == @now

    assert [codex_meter, secondary_meter] = result.buckets
    assert codex_meter.id == "codex"
    assert codex_meter.scope == "provider_defined"
    assert codex_meter.model == nil
    assert "scope" in codex_meter.unknown_fields
    assert "model" in codex_meter.unknown_fields
    assert codex_meter.primary_window.used_percent == 35
    assert codex_meter.secondary_window.used_percent == 70
    assert codex_meter.primary_window.resets_at == ~U[2026-08-03 13:00:00Z]
    assert codex_meter.credits.balance == "12.50"
    assert codex_meter.paid_continuation == "unknown"
    assert "paid_continuation" in codex_meter.unknown_fields
    assert codex_meter.spend_control.remaining_percent == 80
    assert codex_meter.spend_control_reached == false
    assert secondary_meter.scope == "provider_defined"
    assert secondary_meter.model == nil
    assert secondary_meter.id == "gpt-5-mini"
    assert secondary_meter.primary_window.used_percent == 90
    assert Enum.count(result.buckets, &(&1.id == "codex")) == 1
    refute Enum.any?(result.buckets, &(&1.scope == "general"))

    assert result.reset_credits.available_count == 2
    assert result.token_activity.lifetime_tokens == 12_000
    assert result.token_activity.peak_daily_tokens == 2_500
    assert "provider_billing" in result.unknown_fields

    encoded = inspect(result)
    refute encoded =~ "plus"
    refute encoded =~ "reset-credit-provider-id"
    refute encoded =~ "provider account"
  end

  test "falls back to the historical general bucket for absent, null, and empty mirrors",
       context do
    for rate_result <- [
          Map.delete(rate_limits(), "rateLimitsByLimitId"),
          Map.put(rate_limits(), "rateLimitsByLimitId", nil),
          Map.put(rate_limits(), "rateLimitsByLimitId", %{})
        ] do
      assert {:ok, result} = complete_fetch(context, rate_result)
      assert [%{id: "codex", scope: "general", model: nil}] = result.buckets
    end
  end

  test "adds historical general when the authoritative mirrors omit its exact id", context do
    missing_mirror =
      update_in(rate_limits(), ["rateLimitsByLimitId"], &Map.delete(&1, "codex"))

    assert {:ok, result} = complete_fetch(context, missing_mirror)

    assert [
             %{id: "codex", scope: "general"},
             %{id: "gpt-5-mini", scope: "provider_defined"}
           ] = result.buckets
  end

  test "keeps API-key quota and billing explicitly unknown without making quota requests",
       context do
    assert {:ok, result} =
             Codex.fetch(
               %{},
               %{provider: "openai_codex", authentication_mode: "api_key"},
               server: context.adapter,
               now: @now
             )

    assert result.status == "unknown"
    assert result.authentication_mode == "api_key"
    assert result.source_methods == []
    assert result.buckets == []
    assert result.reset_credits == nil
    assert result.token_activity == nil
    assert "api_key_quota" in result.unknown_fields
    assert "api_key_billing" in result.unknown_fields

    refute_receive {CodexAppServerProcessDouble, :write, _,
                    %{"method" => "account/rateLimits/read"}}

    refute_receive {CodexAppServerProcessDouble, :write, _, %{"method" => "account/usage/read"}}
  end

  test "treats unsupported account usage as an explicit unknown without losing quota", context do
    task = fetch_chatgpt(context.adapter)

    rate_request =
      CodexAppServerFixtures.receive_write(context.process, "account/rateLimits/read")

    CodexAppServerProcessDouble.respond(context.process, rate_request["id"], rate_limits())

    usage_request = CodexAppServerFixtures.receive_write(context.process, "account/usage/read")

    CodexAppServerProcessDouble.error(context.process, usage_request["id"], %{
      "code" => -32_601,
      "message" => "method not found"
    })

    assert {:ok, result} = Task.await(task)
    assert result.status == "reported"
    assert result.source_methods == ["account/rateLimits/read"]
    assert result.token_activity == nil
    assert "token_activity" in result.unknown_fields
  end

  test "validates sparse rate-limit notifications only as refetch signals" do
    notification = %{
      "rateLimits" => %{
        "limitId" => "codex",
        "primary" => %{"usedPercent" => 48}
      }
    }

    assert Codex.handle_notification("account/rateLimits/updated", notification) ==
             {:ok, :refetch}

    assert Codex.notification_action("account/rateLimits/updated", notification) ==
             {:ok, :refetch}

    assert Codex.handle_notification("account/rateLimits/updated", %{
             "rateLimits" => %{"primary" => %{"usedPercent" => 48}},
             "cleared" => true
           }) == {:error, :invalid_response}
  end

  test "worker notification handler performs a complete bound refetch without sparse merging" do
    parent = self()

    connection = %{
      provider: "openai_codex",
      authentication_mode: "chatgpt",
      worker_profile_ref: "profile-notification-boundary"
    }

    {:ok, handler} =
      CodexNotificationHandler.start_link(
        account: %{},
        connection: connection,
        fetch_options: [now: @now],
        deliver: fn delivery -> send(parent, {:quota_delivery, delivery}) end
      )

    assert {:error, :invalid_request} = CodexNotificationHandler.bind_app_server(handler, nil)

    {:ok, mismatched_adapter} =
      CodexAppServerFixtures.start_adapter(self(),
        notification_target: handler,
        worker_profile_ref: "profile-other-boundary"
      )

    mismatched_process = CodexAppServerFixtures.receive_handshake().process

    assert {:error, :invalid_request} =
             CodexNotificationHandler.bind_app_server(handler, mismatched_adapter)

    server_name = {:global, {__MODULE__, make_ref()}}

    {:ok, adapter} =
      CodexAppServerFixtures.start_adapter(self(),
        notification_target: handler,
        name: server_name,
        worker_profile_ref: "profile-notification-boundary"
      )

    handshake = CodexAppServerFixtures.receive_handshake()
    process = handshake.process
    assert :ok = CodexNotificationHandler.bind_app_server(handler, server_name)

    assert {:error, :invalid_request} =
             CodexNotificationHandler.bind_app_server(handler, server_name)

    CodexAppServerProcessDouble.notify(
      mismatched_process,
      "account/rateLimits/updated",
      %{"rateLimits" => %{"limitId" => "codex", "primary" => %{"usedPercent" => 1}}}
    )

    refute_receive {:quota_delivery, _delivery}, 50

    refute_receive {CodexAppServerProcessDouble, :write, ^process,
                    %{"method" => "account/rateLimits/read"}}

    on_exit(fn ->
      CodexAppServer.stop(mismatched_adapter)
      CodexAppServer.stop(adapter)
      if Process.alive?(handler), do: GenServer.stop(handler)
    end)

    CodexAppServerProcessDouble.notify(
      process,
      "account/rateLimits/updated",
      %{"rateLimits" => %{"limitId" => "codex", "primary" => %{"usedPercent" => 99}}}
    )

    rate_request =
      CodexAppServerFixtures.receive_write(process, "account/rateLimits/read")

    assert rate_request["params"] == nil
    CodexAppServerProcessDouble.respond(process, rate_request["id"], rate_limits())

    usage_request =
      CodexAppServerFixtures.receive_write(process, "account/usage/read")

    assert usage_request["params"] == nil
    CodexAppServerProcessDouble.respond(process, usage_request["id"], usage())

    assert_receive {:quota_delivery,
                    %{
                      connection_ref: "profile-notification-boundary",
                      trigger: :complete_rate_limit_refetch,
                      result: {:ok, fresh}
                    }}

    assert hd(fresh.buckets).primary_window.used_percent == 35
    refute hd(fresh.buckets).primary_window.used_percent == 99

    CodexAppServerProcessDouble.notify(
      process,
      "account/rateLimits/updated",
      %{
        "rateLimits" => %{"limitId" => "codex", "primary" => %{"usedPercent" => 2}},
        "cleared" => true
      }
    )

    assert_receive {:quota_delivery,
                    %{
                      connection_ref: "profile-notification-boundary",
                      result: {:error, :invalid_response}
                    }}

    refute_receive {CodexAppServerProcessDouble, :write, ^process,
                    %{"method" => "account/rateLimits/read"}}
  end

  test "fails closed on malformed, oversized, credential-shaped, and mismatched output",
       context do
    malformed = Map.put(rate_limits(), "providerAccountId", "account-raw")
    assert_fetch_error(context, malformed, usage(), :invalid_response)

    oversized =
      put_in(rate_limits(), ["rateLimits", "limitName"], String.duplicate("x", 1_001))

    assert_fetch_error(context, oversized, usage(), :invalid_response)

    credential = put_in(rate_limits(), ["rateLimits", "limitName"], "Bearer hidden-secret")
    assert_fetch_error(context, credential, usage(), :invalid_response)

    mismatched =
      put_in(
        rate_limits(),
        ["rateLimitsByLimitId", "gpt-5-mini", "limitId"],
        "different-model"
      )

    assert_fetch_error(context, mismatched, usage(), :invalid_response)

    for raw_value <- [
          "provider-account-123",
          "provider-workspace-456",
          "profile-codex-test",
          "raw provider failure"
        ] do
      unsafe =
        put_in(rate_limits(), ["rateLimitsByLimitId", "codex", "limitName"], raw_value)

      assert_fetch_error(context, unsafe, usage(), :invalid_response)
    end
  end

  test "provider-neutral validation rejects API-key quota or billing facts" do
    result = %{
      status: "unknown",
      provider: "openai_codex",
      authentication_mode: "api_key",
      source: "official_client",
      source_methods: [],
      source_version:
        CodexAppServerFixtures.codex_version() <>
          "|schema:" <> CodexAppServerFixtures.schema_digest(),
      retrieved_at: @now,
      buckets: [],
      reset_credits: nil,
      token_activity: nil,
      unknown_fields: ["api_key_quota", "api_key_billing"]
    }

    assert {:ok, _result} =
             QuotaAdapter.validate_result(result, "openai_codex", "api_key")

    assert {:error, :invalid_response} =
             result
             |> Map.put(:buckets, [
               %{
                 id: "invented",
                 scope: "general",
                 model: nil,
                 display_name: nil,
                 primary_window: nil,
                 secondary_window: nil,
                 credits: nil,
                 paid_continuation: "unknown",
                 spend_control: nil,
                 spend_control_reached: nil,
                 limit_reached_reason: nil,
                 unknown_fields: []
               }
             ])
             |> QuotaAdapter.validate_result("openai_codex", "api_key")
  end

  test "provider-neutral validation accepts model-specific scope only with proven model metadata" do
    bucket = %{
      id: "proven-model-limit",
      scope: "model_specific",
      model: "proven-model",
      display_name: "Proven model limit",
      primary_window: %{
        used_percent: 10,
        resets_at: nil,
        duration_minutes: nil,
        unknown_fields: ["resets_at", "duration_minutes"]
      },
      secondary_window: nil,
      credits: nil,
      paid_continuation: "unknown",
      spend_control: nil,
      spend_control_reached: nil,
      limit_reached_reason: nil,
      unknown_fields: [
        "secondary_window",
        "credits",
        "paid_continuation",
        "spend_control",
        "spend_control_reached",
        "limit_reached_reason"
      ]
    }

    result = %{
      status: "reported",
      provider: "openai_codex",
      authentication_mode: "chatgpt",
      source: "official_client",
      source_methods: ["account/rateLimits/read"],
      source_version:
        CodexAppServerFixtures.codex_version() <>
          "|schema:" <> CodexAppServerFixtures.schema_digest(),
      retrieved_at: @now,
      buckets: [bucket],
      reset_credits: nil,
      token_activity: nil,
      unknown_fields: ["reset_credits", "token_activity", "provider_billing"]
    }

    assert {:ok, normalized} =
             QuotaAdapter.validate_result(result, "openai_codex", "chatgpt")

    assert hd(normalized.buckets).model == "proven-model"

    assert {:error, :invalid_response} =
             result
             |> put_in([:buckets, Access.at(0), :model], nil)
             |> QuotaAdapter.validate_result("openai_codex", "chatgpt")
  end

  defp fetch_chatgpt(adapter) do
    Task.async(fn ->
      Codex.fetch(
        %{},
        %{
          provider: "openai_codex",
          authentication_mode: "chatgpt",
          worker_profile_ref: "profile-codex-test"
        },
        server: adapter,
        now: @now
      )
    end)
  end

  defp assert_fetch_error(context, rate_result, usage_result, expected) do
    task = fetch_chatgpt(context.adapter)

    rate_request =
      CodexAppServerFixtures.receive_write(context.process, "account/rateLimits/read")

    CodexAppServerProcessDouble.respond(context.process, rate_request["id"], rate_result)

    case Task.yield(task, 100) do
      {:ok, result} ->
        assert result == {:error, expected}

      nil ->
        usage_request =
          CodexAppServerFixtures.receive_write(context.process, "account/usage/read")

        CodexAppServerProcessDouble.respond(context.process, usage_request["id"], usage_result)
        assert Task.await(task) == {:error, expected}
    end
  end

  defp complete_fetch(context, rate_result) do
    task = fetch_chatgpt(context.adapter)

    rate_request =
      CodexAppServerFixtures.receive_write(context.process, "account/rateLimits/read")

    CodexAppServerProcessDouble.respond(context.process, rate_request["id"], rate_result)

    usage_request =
      CodexAppServerFixtures.receive_write(context.process, "account/usage/read")

    CodexAppServerProcessDouble.respond(context.process, usage_request["id"], usage())
    Task.await(task)
  end

  defp rate_limits do
    general = %{
      "limitId" => "codex",
      "limitName" => "General Codex",
      "planType" => "plus",
      "primary" => %{
        "usedPercent" => 35,
        "resetsAt" => 1_785_762_000,
        "windowDurationMins" => 300
      },
      "secondary" => %{
        "usedPercent" => 70,
        "resetsAt" => 1_786_363_200,
        "windowDurationMins" => 10_080
      },
      "credits" => %{
        "hasCredits" => true,
        "unlimited" => false,
        "balance" => "12.50"
      },
      "individualLimit" => %{
        "limit" => "100.00",
        "used" => "20.00",
        "remainingPercent" => 80,
        "resetsAt" => 1_786_363_200
      },
      "spendControlReached" => false,
      "rateLimitReachedType" => nil
    }

    %{
      "rateLimits" => general,
      "rateLimitsByLimitId" => %{
        "codex" => general,
        "gpt-5-mini" => %{
          "limitId" => "gpt-5-mini",
          "limitName" => "GPT-5 mini",
          "planType" => nil,
          "primary" => %{"usedPercent" => 90},
          "secondary" => nil,
          "credits" => nil,
          "individualLimit" => nil,
          "spendControlReached" => nil,
          "rateLimitReachedType" => "rate_limit_reached"
        }
      },
      "rateLimitResetCredits" => %{
        "availableCount" => 2,
        "credits" => [
          %{
            "id" => "reset-credit-provider-id",
            "grantedAt" => 1_785_754_800,
            "expiresAt" => nil,
            "resetType" => "codexRateLimits",
            "status" => "available",
            "title" => "Reset credit",
            "description" => "Available account reset"
          }
        ]
      }
    }
  end

  defp usage do
    %{
      "summary" => %{
        "lifetimeTokens" => 12_000,
        "peakDailyTokens" => 2_500,
        "currentStreakDays" => 3,
        "longestStreakDays" => 8,
        "longestRunningTurnSec" => 90
      },
      "dailyUsageBuckets" => [%{"startDate" => "2026-08-03", "tokens" => 2_500}]
    }
  end
end
