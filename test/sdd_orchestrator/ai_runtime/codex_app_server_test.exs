defmodule SddOrchestrator.AIRuntime.CodexAppServerTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.AIRuntime.CodexAppServer
  alias SddOrchestrator.CodexAppServerFixtures
  alias SddOrchestrator.CodexAppServerProcessDouble

  setup do
    {:ok, adapter} = CodexAppServerFixtures.start_adapter(self())
    handshake = CodexAppServerFixtures.receive_handshake()

    on_exit(fn -> CodexAppServer.stop(adapter) end)

    %{adapter: adapter, process: handshake.process, handshake: handshake}
  end

  describe "compatibility and initialization" do
    test "retains the exact normalized version and schema pair verified at startup", %{
      adapter: adapter
    } do
      assert CodexAppServer.compatibility(adapter) ==
               {:ok,
                %{
                  codex_version: CodexAppServerFixtures.codex_version(),
                  schema_digest: CodexAppServerFixtures.schema_digest()
                }}

      {:ok, uppercase_digest_adapter} =
        CodexAppServerFixtures.start_adapter(self(),
          schema_digest: String.upcase(CodexAppServerFixtures.schema_digest())
        )

      _handshake = CodexAppServerFixtures.receive_handshake()

      assert CodexAppServer.compatibility(uppercase_digest_adapter) ==
               {:ok,
                %{
                  codex_version: CodexAppServerFixtures.codex_version(),
                  schema_digest: CodexAppServerFixtures.schema_digest()
                }}

      CodexAppServer.stop(uppercase_digest_adapter)
    end

    test "binds one App Server instance to one worker-local profile without exposing it", %{
      adapter: adapter
    } do
      assert CodexAppServer.binding_matches?(adapter, "profile-codex-test")
      refute CodexAppServer.binding_matches?(adapter, "profile-other")
      refute CodexAppServer.binding_matches?(adapter, nil)

      assert {:error, :invalid_request} =
               CodexAppServerFixtures.start_adapter(self(), worker_profile_ref: nil)

      assert {:error, :invalid_request} =
               CodexAppServerFixtures.start_adapter(self(), worker_profile_ref: "")
    end

    test "accepts only a registered version and generated-schema digest" do
      assert {:error, :unsupported_version} =
               CodexAppServerFixtures.start_adapter(self(), codex_version: "codex-cli unknown")

      assert {:error, :unsupported_schema_digest} =
               CodexAppServerFixtures.start_adapter(self(),
                 schema_digest: String.duplicate("7", 64)
               )

      assert {:error, :unsupported_schema_digest} =
               CodexAppServerFixtures.start_adapter(self(), schema_digest: "not-a-digest")
    end

    test "refuses WebSocket transport before starting a process" do
      assert {:error, :unsupported_transport} =
               CodexAppServerFixtures.start_adapter(self(), transport: :websocket)

      refute_receive {CodexAppServerProcessDouble, :started, _process}
    end

    test "initializes once and acknowledges without a jsonrpc header", %{handshake: handshake} do
      assert handshake.initialize == %{
               "id" => 0,
               "method" => "initialize",
               "params" => %{
                 "clientInfo" => %{
                   "name" => "sdd_orchestrator",
                   "title" => "SDD Orchestrator",
                   "version" => "1"
                 }
               }
             }

      assert handshake.initialized == %{"method" => "initialized", "params" => %{}}
      refute Map.has_key?(handshake.initialize, "jsonrpc")
      refute Map.has_key?(handshake.initialized, "jsonrpc")
    end

    test "rejects an invalid initialization result" do
      assert {:error, :initialization_failed} =
               CodexAppServerFixtures.start_adapter(self(),
                 process_options: [test_pid: self(), initialize_result: "invalid"]
               )
    end
  end

  describe "method and login allowlists" do
    test "calls an allowlisted documented method and correlates its response", %{
      adapter: adapter,
      process: process
    } do
      task = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{"limit" => 20}) end)

      request = CodexAppServerFixtures.receive_write(process, "model/list")
      assert request["params"] == %{"limit" => 20}
      refute Map.has_key?(request, "jsonrpc")

      :ok = CodexAppServerProcessDouble.respond(process, request["id"], %{"data" => []})
      assert Task.await(task) == {:ok, %{"data" => []}}
    end

    test "refuses methods outside the documented foundation", %{adapter: adapter} do
      assert CodexAppServer.request(adapter, "thread/start", %{}) ==
               {:error, :unsupported_method}

      refute_receive {CodexAppServerProcessDouble, :write, _process,
                      %{"method" => "thread/start"}}
    end

    test "supports managed browser, device-code, and API-key login locally", %{
      adapter: adapter,
      process: process
    } do
      browser = Task.async(fn -> CodexAppServer.login_chatgpt(adapter) end)
      browser_request = CodexAppServerFixtures.receive_write(process, "account/login/start")
      assert browser_request["params"]["type"] == "chatgpt"

      CodexAppServerProcessDouble.respond(process, browser_request["id"], %{
        "authUrl" => "https://local.test"
      })

      assert {:ok, %{"authUrl" => "https://local.test"}} = Task.await(browser)

      device = Task.async(fn -> CodexAppServer.login_chatgpt_device_code(adapter) end)
      device_request = CodexAppServerFixtures.receive_write(process, "account/login/start")
      assert device_request["params"] == %{"type" => "chatgptDeviceCode"}

      CodexAppServerProcessDouble.respond(process, device_request["id"], %{
        "userCode" => "LOCAL-CODE"
      })

      assert {:ok, %{"userCode" => "LOCAL-CODE"}} = Task.await(device)

      api_key =
        Task.async(fn -> CodexAppServer.login_api_key(adapter, "sk-worker-local-test") end)

      api_key_request = CodexAppServerFixtures.receive_write(process, "account/login/start")

      assert api_key_request["params"] == %{
               "type" => "apiKey",
               "apiKey" => "sk-worker-local-test"
             }

      CodexAppServerProcessDouble.respond(process, api_key_request["id"], %{"type" => "apiKey"})
      assert {:ok, %{"type" => "apiKey"}} = Task.await(api_key)
    end

    test "refuses externally supplied ChatGPT tokens and unknown auth modes", %{adapter: adapter} do
      assert CodexAppServer.request(adapter, "account/login/start", %{
               "type" => "chatgptAuthTokens",
               "accessToken" => "secret"
             }) == {:error, :unsupported_auth_mode}

      assert CodexAppServer.request(adapter, "account/login/start", %{
               "type" => "chatgpt",
               "accessToken" => "smuggled-secret"
             }) == {:error, :unsupported_auth_mode}

      assert CodexAppServer.request(adapter, "account/login/start", %{"type" => "amazonBedrock"}) ==
               {:error, :unsupported_auth_mode}

      refute_receive {CodexAppServerProcessDouble, :write, _process,
                      %{"method" => "account/login/start"}}
    end

    test "uses the documented login cancellation method", %{adapter: adapter, process: process} do
      task = Task.async(fn -> CodexAppServer.cancel_login(adapter, "login-local") end)
      request = CodexAppServerFixtures.receive_write(process, "account/login/cancel")
      assert request["params"] == %{"loginId" => "login-local"}
      CodexAppServerProcessDouble.respond(process, request["id"], %{"status" => "canceled"})
      assert {:ok, %{"status" => "canceled"}} = Task.await(task)
    end
  end

  describe "typed validation failures" do
    test "normalizes raw App Server errors without returning their text", %{
      adapter: adapter,
      process: process
    } do
      task = Task.async(fn -> CodexAppServer.request(adapter, "account/read", nil) end)
      request = CodexAppServerFixtures.receive_write(process, "account/read")

      CodexAppServerProcessDouble.error(process, request["id"], %{
        "code" => -32_000,
        "message" => "provider account raw diagnostic"
      })

      assert Task.await(task) == {:error, :app_server_error}
    end

    test "normalizes only JSON-RPC method-not-found while credential content still wins", %{
      adapter: adapter,
      process: process
    } do
      unsupported = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{}) end)
      unsupported_request = CodexAppServerFixtures.receive_write(process, "model/list")

      CodexAppServerProcessDouble.error(process, unsupported_request["id"], %{
        "code" => -32_601,
        "message" => "raw method-not-found diagnostic"
      })

      assert Task.await(unsupported) == {:error, :unsupported_method}

      credential = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{}) end)
      credential_request = CodexAppServerFixtures.receive_write(process, "model/list")

      CodexAppServerProcessDouble.error(process, credential_request["id"], %{
        "code" => -32_601,
        "message" => "Bearer worker-local-secret"
      })

      assert Task.await(credential) == {:error, :credential_content}

      non_integer = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{}) end)
      non_integer_request = CodexAppServerFixtures.receive_write(process, "model/list")

      CodexAppServerProcessDouble.error(process, non_integer_request["id"], %{
        "code" => -32_601.0,
        "message" => "not an exact JSON-RPC integer code"
      })

      assert Task.await(non_integer) == {:error, :app_server_error}
    end

    test "rejects credential-shaped response keys and values", %{
      adapter: adapter,
      process: process
    } do
      keyed = Task.async(fn -> CodexAppServer.request(adapter, "account/read", nil) end)
      keyed_request = CodexAppServerFixtures.receive_write(process, "account/read")

      CodexAppServerProcessDouble.respond(process, keyed_request["id"], %{
        "accessToken" => "not-projected"
      })

      assert Task.await(keyed) == {:error, :credential_content}

      valued = Task.async(fn -> CodexAppServer.request(adapter, "account/read", nil) end)
      valued_request = CodexAppServerFixtures.receive_write(process, "account/read")

      CodexAppServerProcessDouble.respond(process, valued_request["id"], %{
        "detail" => "Bearer worker-local-secret"
      })

      assert Task.await(valued) == {:error, :credential_content}
    end

    test "rejects malformed and oversized stdout and restarts fail closed", %{
      adapter: adapter,
      process: process
    } do
      malformed = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{}) end)
      _request = CodexAppServerFixtures.receive_write(process, "model/list")
      :ok = CodexAppServerProcessDouble.raw_stdout(process, "not-json\n")
      assert Task.await(malformed) == {:error, :malformed_response}

      restarted = CodexAppServerFixtures.receive_handshake()
      assert :ok = CodexAppServer.await_ready(adapter, 500)

      oversized =
        Task.async(fn ->
          CodexAppServer.request(adapter, "model/list", %{}, timeout_ms: 500)
        end)

      _request = CodexAppServerFixtures.receive_write(restarted.process, "model/list")

      :ok =
        CodexAppServerProcessDouble.raw_stdout(
          restarted.process,
          String.duplicate("x", 256 * 1_024 + 1)
        )

      assert Task.await(oversized) == {:error, :response_too_large}
    end

    test "suppresses stderr even when it contains credential and raw error text", %{
      adapter: adapter,
      process: process
    } do
      :ok =
        CodexAppServerProcessDouble.stderr(
          process,
          "Authorization: Bearer never-project provider raw error"
        )

      task = Task.async(fn -> CodexAppServer.request(adapter, "model/list", %{}) end)
      request = CodexAppServerFixtures.receive_write(process, "model/list")
      CodexAppServerProcessDouble.respond(process, request["id"], %{"data" => []})
      assert Task.await(task) == {:ok, %{"data" => []}}
    end
  end

  describe "timeout, cancellation, notifications, and restart" do
    test "times out with a typed error and discards the late response", %{
      adapter: adapter,
      process: process
    } do
      task =
        Task.async(fn ->
          CodexAppServer.request(adapter, "model/list", %{}, timeout_ms: 30, request_id: 81)
        end)

      _request = CodexAppServerFixtures.receive_write(process, "model/list")
      assert Task.await(task) == {:error, :timeout}

      CodexAppServerProcessDouble.respond(process, 81, %{"late" => true})
      assert :ok = CodexAppServer.await_ready(adapter, 100)
    end

    test "cancels a pending request without accepting its later response", %{
      adapter: adapter,
      process: process
    } do
      task =
        Task.async(fn ->
          CodexAppServer.request(adapter, "model/list", %{}, request_id: 82)
        end)

      _request = CodexAppServerFixtures.receive_write(process, "model/list")
      assert :ok = CodexAppServer.cancel(adapter, 82)
      assert Task.await(task) == {:error, :cancelled}

      CodexAppServerProcessDouble.respond(process, 82, %{"late" => true})
      assert :ok = CodexAppServer.await_ready(adapter, 100)
    end

    test "accepts only allowlisted safe notifications", %{adapter: adapter, process: process} do
      CodexAppServerProcessDouble.notify(process, "account/rateLimits/updated", %{
        "rateLimits" => %{
          "limitId" => "codex",
          "primary" => %{"usedPercent" => 48}
        }
      })

      assert_receive {CodexAppServer, :notification, ^adapter, "account/rateLimits/updated",
                      rate_params}

      assert rate_params["rateLimits"]["primary"] == %{"usedPercent" => 48}

      CodexAppServerProcessDouble.notify(process, "thread/tokenUsage/updated", %{
        "threadId" => "thread-local",
        "tokenUsage" => %{"totalTokens" => 12}
      })

      assert_receive {CodexAppServer, :notification, ^adapter, "thread/tokenUsage/updated",
                      params}

      assert params["tokenUsage"] == %{"totalTokens" => 12}
    end

    test "fails pending calls on crash, restarts, and reinitializes deterministically", %{
      adapter: adapter,
      process: process
    } do
      pending = Task.async(fn -> CodexAppServer.request(adapter, "account/read", nil) end)
      _request = CodexAppServerFixtures.receive_write(process, "account/read")
      CodexAppServerProcessDouble.crash(process)

      assert Task.await(pending) == {:error, :process_crashed}

      restarted = CodexAppServerFixtures.receive_handshake()
      assert restarted.process != process
      assert :ok = CodexAppServer.await_ready(adapter, 500)

      available = Task.async(fn -> CodexAppServer.request(adapter, "account/read", nil) end)
      request = CodexAppServerFixtures.receive_write(restarted.process, "account/read")
      CodexAppServerProcessDouble.respond(restarted.process, request["id"], %{"authMode" => nil})
      assert Task.await(available) == {:ok, %{"authMode" => nil}}
    end
  end
end
