defmodule SddOrchestratorWeb.WorkerPairingControllerTest do
  @moduledoc """
  Proof for the network-facing pairing-completion endpoint (specs/36 Task 3).

  A native worker has no local database and, before this exchange, no
  credential of any kind — only the single-use pairing code. This is the one
  network-facing endpoint that completes
  `SddOrchestrator.Devices.Pairing.complete_pairing/2` for such a caller.
  AC-17 covers the success path; AC-18 covers every refusal answering
  identically without disclosing which specific reason applied.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  alias SddOrchestrator.Devices.Pairing

  @path "/worker_pairings"

  defp workspace_id, do: Ecto.UUID.generate()

  defp request(conn, params) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@path, params)
  end

  defp refused(conn), do: json_response(conn, 403) == %{"error" => "refused"}

  describe "completing pairing over the network" do
    test "AC-17: a valid, unexpired, unused code issues the worker credential and identity",
         context do
      ws = workspace_id()
      {:ok, %{code: code}} = Pairing.start_pairing(ws)

      conn =
        request(context.conn, %{
          "code" => code,
          "os_family" => "macos",
          "os_major" => "26",
          "protocol_version" => "1",
          "app_version" => "1.2.3"
        })

      assert conn.status == 201
      body = json_response(conn, 201)

      assert %{"credential" => credential, "worker" => worker} = body
      assert is_binary(credential)
      assert worker["device_workspace_id"] == ws
      assert worker["os_family"] == "macos"
      assert worker["os_major"] == "26"
      assert worker["protocol_version"] == "1"
      assert worker["app_version"] == "1.2.3"
      assert worker["state"] == "active"
      assert is_binary(worker["id"])

      assert {:ok, authed} = Pairing.authenticate_worker(credential)
      assert authed.id == worker["id"]
    end

    test "AC-17: succeeds with no optional worker attributes supplied", context do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())

      conn = request(context.conn, %{"code" => code})

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["worker"]["os_family"] == nil
    end

    test "answers with private-response hygiene and no cookie", context do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())

      conn = request(context.conn, %{"code" => code})

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "AC-18: refuses an already-used code without issuing a second credential", context do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())
      assert %Plug.Conn{status: 201} = request(context.conn, %{"code" => code})

      conn = request(build_conn(), %{"code" => code})

      assert refused(conn)
    end

    test "AC-18: refuses an expired code", context do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id(), ttl_seconds: -1)

      conn = request(context.conn, %{"code" => code})

      assert refused(conn)
    end

    test "AC-18: refuses an unknown code", context do
      conn = request(context.conn, %{"code" => "#{Ecto.UUID.generate()}.wrong"})

      assert refused(conn)
    end

    test "AC-18: refuses a malformed code", context do
      conn = request(context.conn, %{"code" => "not-a-code"})

      assert refused(conn)
    end

    test "AC-18: refuses a request missing the code entirely", context do
      conn = request(context.conn, %{"os_family" => "macos"})

      assert refused(conn)
    end

    test "AC-18: refuses a request whose code is not a string", context do
      conn = request(context.conn, %{"code" => 12_345})

      assert refused(conn)
    end

    test "AC-18: refuses a request with a badly typed optional attribute", context do
      {:ok, %{code: code}} = Pairing.start_pairing(workspace_id())

      conn = request(context.conn, %{"code" => code, "os_major" => 15})

      assert refused(conn)

      # The code is still unused: a well-formed retry with the same code succeeds.
      assert %Plug.Conn{status: 201} = request(build_conn(), %{"code" => code})
    end

    test "AC-18: an expired code, an already-used code, and an unknown code answer identically",
         context do
      {:ok, %{code: expired_code}} = Pairing.start_pairing(workspace_id(), ttl_seconds: -1)

      {:ok, %{code: used_code}} = Pairing.start_pairing(workspace_id())
      assert %Plug.Conn{status: 201} = request(context.conn, %{"code" => used_code})

      unknown_code = "#{Ecto.UUID.generate()}.wrong"

      expired = request(build_conn(), %{"code" => expired_code})
      used = request(build_conn(), %{"code" => used_code})
      unknown = request(build_conn(), %{"code" => unknown_code})

      assert expired.status == used.status
      assert used.status == unknown.status
      assert json_response(expired, 403) == json_response(used, 403)
      assert json_response(used, 403) == json_response(unknown, 403)
    end
  end
end
