defmodule SddOrchestrator.AIRuntime.PersonalWorkerRPCTest do
  @moduledoc """
  Proof for the control-plane RPC boundary of the personal AI transport
  (Task 7), end to end through the real socket and channel with the paired
  worker double.

  The properties under test are correlation, idempotency, bounded waiting,
  replay refusal after timeout, deterministic reconnect replacement, typed
  unavailability and size refusals, and account and workspace isolation.
  """
  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest, except: [join: 2, join: 3, join: 4]

  alias SddOrchestrator.AIRuntime.PersonalWorkerRPC
  alias SddOrchestrator.PersonalAIProtocolFixtures
  alias SddOrchestrator.PersonalAIWorkerDouble

  setup do
    paired = PersonalAIWorkerDouble.pair_worker()
    {:ok, _contract, channel} = PersonalAIWorkerDouble.attach(paired)

    %{paired: paired, channel: channel, account_id: Ecto.UUID.generate()}
  end

  describe "correlation" do
    test "a request reaches the worker and its response returns to the caller",
         %{paired: paired, channel: channel, account_id: account_id} do
      task = request_async(paired, account_id, "catalog/1", %{"kind" => "models"})

      assert_push "ai_request", pushed
      assert pushed["capability"] == "catalog/1"
      assert pushed["account_id"] == account_id
      assert pushed["device_workspace_id"] == paired.device_workspace_id
      assert pushed["params"] == %{"kind" => "models"}

      ref = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"models" => ["m1"]})
      assert_reply ref, :ok, %{status: "completed"}

      assert Task.await(task) == {:ok, %{"models" => ["m1"]}}
    end

    test "every request carries a fresh identifier and the caller's idempotency key",
         %{paired: paired, channel: channel, account_id: account_id} do
      task_one =
        request_async(paired, account_id, "catalog/1", %{"n" => 1}, idempotency_key: "key-a")

      assert_push "ai_request", first

      task_two =
        request_async(paired, account_id, "catalog/1", %{"n" => 2}, idempotency_key: "key-b")

      assert_push "ai_request", second

      assert {:ok, _uuid} = Ecto.UUID.cast(first["request_id"])
      assert {:ok, _uuid} = Ecto.UUID.cast(second["request_id"])
      assert first["request_id"] != second["request_id"]
      assert first["idempotency_key"] == "key-a"
      assert second["idempotency_key"] == "key-b"

      PersonalAIWorkerDouble.respond_to(channel, first, %{"n" => 1})
      PersonalAIWorkerDouble.respond_to(channel, second, %{"n" => 2})
      assert Task.await(task_one) == {:ok, %{"n" => 1}}
      assert Task.await(task_two) == {:ok, %{"n" => 2}}
    end
  end

  describe "idempotency" do
    test "repeating a completed request returns the cached response without a second push",
         %{paired: paired, channel: channel, account_id: account_id} do
      task =
        request_async(paired, account_id, "quota/1", %{"scope" => "all"},
          idempotency_key: "key-cache"
        )

      assert_push "ai_request", pushed

      ref = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"buckets" => ["general"]})
      assert_reply ref, :ok, %{status: "completed"}
      assert Task.await(task) == {:ok, %{"buckets" => ["general"]}}

      repeat =
        request_async(paired, account_id, "quota/1", %{"scope" => "all"},
          idempotency_key: "key-cache"
        )

      assert Task.await(repeat) == {:ok, %{"buckets" => ["general"]}}
      refute_push "ai_request", %{}
    end

    test "reusing a key with different content is refused",
         %{paired: paired, channel: channel, account_id: account_id} do
      task =
        request_async(paired, account_id, "quota/1", %{"scope" => "all"},
          idempotency_key: "key-conflict"
        )

      assert_push "ai_request", pushed
      PersonalAIWorkerDouble.respond_to(channel, pushed, %{"buckets" => []})
      assert {:ok, _result} = Task.await(task)

      conflict =
        request_async(paired, account_id, "quota/1", %{"scope" => "today"},
          idempotency_key: "key-conflict"
        )

      assert Task.await(conflict) == {:error, :duplicate_request}
      refute_push "ai_request", %{}
    end

    test "a key already in flight is refused until its request completes",
         %{paired: paired, channel: channel, account_id: account_id} do
      first =
        request_async(paired, account_id, "catalog/1", %{"n" => 1}, idempotency_key: "key-flight")

      assert_push "ai_request", pushed

      duplicate =
        request_async(paired, account_id, "catalog/1", %{"n" => 1}, idempotency_key: "key-flight")

      assert Task.await(duplicate) == {:error, :duplicate_request}

      ref = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"done" => true})
      assert_reply ref, :ok, %{status: "completed"}
      assert Task.await(first) == {:ok, %{"done" => true}}
    end
  end

  describe "timeout" do
    test "the caller gets a typed timeout and a late response is refused as a replay",
         %{paired: paired, channel: channel, account_id: account_id} do
      task = request_async(paired, account_id, "catalog/1", %{"slow" => true}, timeout_ms: 100)
      assert_push "ai_request", pushed

      assert Task.await(task) == {:error, :timeout}

      late = PersonalAIWorkerDouble.respond_to(channel, pushed, %{"too" => "late"})
      assert_reply late, :error, %{reason: "replayed_response"}
    end
  end

  describe "reconnect" do
    test "a reconnect replaces the stale connection, fails its pending request, and serves new ones",
         %{paired: paired, channel: channel, account_id: account_id} do
      task = request_async(paired, account_id, "catalog/1", %{"phase" => "before"})
      assert_push "ai_request", _pushed

      # A real reconnect drops the old transport without warning it.
      Process.unlink(channel.channel_pid)
      {:ok, _contract, replacement} = PersonalAIWorkerDouble.attach(paired)

      assert Task.await(task) == {:error, :worker_disconnected}
      refute Process.alive?(channel.channel_pid)

      fresh = request_async(paired, account_id, "catalog/1", %{"phase" => "after"})
      assert_push "ai_request", %{"params" => %{"phase" => "after"}} = pushed

      ref =
        PersonalAIWorkerDouble.respond_to(replacement, pushed, %{"served_by" => "replacement"})

      assert_reply ref, :ok, %{status: "completed"}
      assert Task.await(fresh) == {:ok, %{"served_by" => "replacement"}}
    end
  end

  describe "typed refusals" do
    test "no live connection is a typed unavailability", %{account_id: account_id} do
      assert PersonalWorkerRPC.request(
               account_id,
               Ecto.UUID.generate(),
               Ecto.UUID.generate(),
               "catalog/1",
               %{}
             ) == {:error, :worker_unavailable}
    end

    test "an oversized payload is refused before anything is sent",
         %{paired: paired, account_id: account_id} do
      assert PersonalWorkerRPC.request(
               account_id,
               paired.device_workspace_id,
               paired.worker.id,
               "catalog/1",
               PersonalAIProtocolFixtures.oversized_params()
             ) == {:error, :payload_too_large}

      refute_push "ai_request", %{}
    end

    test "a capability outside the negotiated contract is refused",
         %{paired: paired, account_id: account_id} do
      assert PersonalWorkerRPC.request(
               account_id,
               paired.device_workspace_id,
               paired.worker.id,
               "run.start",
               %{}
             ) == {:error, :unsupported_capability}

      refute_push "ai_request", %{}
    end

    test "a connection that negotiated fewer capabilities refuses the missing ones",
         %{account_id: account_id} do
      narrow = PersonalAIWorkerDouble.pair_worker()

      {:ok, _contract, _channel} =
        PersonalAIWorkerDouble.attach(narrow, announcement: %{"capabilities" => ["catalog/1"]})

      assert PersonalWorkerRPC.request(
               account_id,
               narrow.device_workspace_id,
               narrow.worker.id,
               "quota/1",
               %{}
             ) == {:error, :unsupported_capability}
    end

    test "a structurally invalid request is a typed refusal", %{paired: paired} do
      assert PersonalWorkerRPC.request(
               "not-an-account",
               paired.device_workspace_id,
               paired.worker.id,
               "catalog/1",
               %{}
             ) == {:error, :invalid_request}
    end
  end

  describe "isolation" do
    test "two accounts on one worker never receive each other's responses",
         %{paired: paired, channel: channel, account_id: account_a} do
      account_b = Ecto.UUID.generate()

      task_a = request_async(paired, account_a, "quota/1", %{"who" => "a"})
      task_b = request_async(paired, account_b, "quota/1", %{"who" => "b"})

      assert_push "ai_request", first
      assert_push "ai_request", second

      {for_a, for_b} =
        if first["account_id"] == account_a, do: {first, second}, else: {second, first}

      # A response claiming the wrong account scope never crosses.
      crossed =
        PersonalAIWorkerDouble.respond(channel, %{
          "request_id" => for_b["request_id"],
          "account_id" => account_a,
          "result" => %{"crossed" => true}
        })

      assert_reply crossed, :error, %{reason: "cross_account"}

      ref_b = PersonalAIWorkerDouble.respond_to(channel, for_b, %{"quota" => "b"})
      assert_reply ref_b, :ok, %{status: "completed"}
      ref_a = PersonalAIWorkerDouble.respond_to(channel, for_a, %{"quota" => "a"})
      assert_reply ref_a, :ok, %{status: "completed"}

      assert Task.await(task_a) == {:ok, %{"quota" => "a"}}
      assert Task.await(task_b) == {:ok, %{"quota" => "b"}}
    end

    test "a request addressed to another workspace cannot reach this worker",
         %{paired: paired, account_id: account_id} do
      assert PersonalWorkerRPC.request(
               account_id,
               Ecto.UUID.generate(),
               paired.worker.id,
               "catalog/1",
               %{}
             ) == {:error, :worker_unavailable}

      refute_push "ai_request", %{}
    end
  end

  defp request_async(paired, account_id, capability, params, opts \\ []) do
    Task.async(fn ->
      PersonalWorkerRPC.request(
        account_id,
        paired.device_workspace_id,
        paired.worker.id,
        capability,
        params,
        opts
      )
    end)
  end
end
