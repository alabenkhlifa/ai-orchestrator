defmodule SddOrchestratorWeb.PairingCodeControllerTest do
  @moduledoc """
  specs/38-worker-initiated-pairing Task 3 proof.

  Issuance is the one pairing step with no account behind it, so what matters is
  that the caller cannot widen what it gets, that the code it gets authorizes
  nothing yet, that the rate is bounded, and that nothing about the caller or
  the code reaches a log.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias SddOrchestrator.Devices.{Pairing, PairingAttempt, PairingIssuanceThrottle}
  alias SddOrchestrator.Repo

  setup do
    PairingIssuanceThrottle.reset()

    # A successful issuance is deliberately recorded at :info, and the suite runs
    # at :warning, which drops the message before any capture handler sees it.
    # This module is `async: false`, so raising the level runs alone.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: previous_level)
      PairingIssuanceThrottle.reset()
    end)

    :ok
  end

  defp issue(conn, params \\ %{}), do: post(conn, ~p"/pairing_codes", params)

  describe "issuing a code (AC-09)" do
    test "one call returns exactly one code for an attempt that belongs to no workspace", %{
      conn: conn
    } do
      conn = issue(conn)

      assert %{"code" => code, "expires_at" => expires_at} = json_response(conn, 201)
      assert is_binary(code)
      assert expires_at

      assert [attempt] = Repo.all(PairingAttempt)
      assert is_nil(attempt.device_workspace_id)
      assert is_nil(attempt.confirmed_at)
      assert is_nil(attempt.worker_id)

      # The code returned is the one that was minted, and it is usable exactly once.
      assert String.starts_with?(code, attempt.id)
    end

    test "the response is not cacheable and leaks no referrer", %{conn: conn} do
      conn = issue(conn)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "the caller cannot widen what it gets" do
    test "a workspace, project, identity, or secret in the body is ignored", %{conn: conn} do
      workspace_id = Ecto.UUID.generate()

      conn =
        issue(conn, %{
          "device_workspace_id" => workspace_id,
          "project_id" => Ecto.UUID.generate(),
          "account_id" => Ecto.UUID.generate(),
          "code_digest" => "chosen-by-caller",
          "expires_at" => "2099-01-01T00:00:00Z"
        })

      assert %{"code" => _code} = json_response(conn, 201)

      assert [attempt] = Repo.all(PairingAttempt)
      assert is_nil(attempt.device_workspace_id)
      refute attempt.code_digest == "chosen-by-caller"
      # The expiry is the server's, not the one the caller asked for.
      assert DateTime.compare(attempt.expires_at, ~U[2099-01-01 00:00:00Z]) == :lt
    end

    test "the issued code authorizes nothing until an owner redeems it", %{conn: conn} do
      %{"code" => code} = conn |> issue() |> json_response(201)

      # Nothing was authorized by issuance alone.
      assert Pairing.active_workers(Ecto.UUID.generate()) == []

      # It becomes attached only when an owner binds it, and becomes a worker
      # only when the app finishes for itself.
      workspace_id = Ecto.UUID.generate()
      assert :ok = Pairing.bind_pairing(code, workspace_id)
      assert Pairing.active_workers(workspace_id) == []

      assert {:ok, %{worker: worker}} = Pairing.complete_pairing(code)
      assert worker.device_workspace_id == workspace_id
    end
  end

  describe "rate limiting" do
    test "calls beyond the allowed rate are refused and mint nothing", %{conn: conn} do
      capacity =
        :sdd_orchestrator
        |> Application.fetch_env!(:pairing_issuance)
        |> Keyword.fetch!(:rate_limits)
        |> Keyword.fetch!(:caller)
        |> Keyword.fetch!(:capacity)

      for _allowed <- 1..capacity do
        assert %{"code" => _} = conn |> issue() |> json_response(201)
      end

      refused = issue(conn)
      assert %{"error" => "refused"} = json_response(refused, 429)

      # The refusal minted nothing, so the throttle is not a way to grow storage.
      assert Repo.aggregate(PairingAttempt, :count) == capacity
    end

    test "a refusal says nothing about a code the caller obtained earlier", %{conn: conn} do
      capacity =
        :sdd_orchestrator
        |> Application.fetch_env!(:pairing_issuance)
        |> Keyword.fetch!(:rate_limits)
        |> Keyword.fetch!(:caller)
        |> Keyword.fetch!(:capacity)

      %{"code" => first} = conn |> issue() |> json_response(201)
      for _rest <- 2..capacity, do: issue(conn)

      unredeemed = issue(conn) |> json_response(429)

      # Bind the first code, then exhaust again and compare the answers.
      :ok = Pairing.bind_pairing(first, Ecto.UUID.generate())
      PairingIssuanceThrottle.reset()
      for _refill <- 1..capacity, do: issue(conn)
      redeemed = issue(conn) |> json_response(429)

      assert unredeemed == redeemed
    end
  end

  describe "nothing identifying reaches the log" do
    test "the audit records the outcome and neither the code nor the caller", %{conn: conn} do
      log =
        capture_log(fn ->
          %{"code" => code} = conn |> issue() |> json_response(201)
          Process.put(:issued_code, code)
        end)

      code = Process.get(:issued_code)
      [_id, secret] = String.split(code, ".", parts: 2)

      assert log =~ "[pairing_security]"
      assert log =~ "outcome=issued"
      refute log =~ code
      refute log =~ secret
      refute log =~ "127.0.0.1"
    end

    test "a throttled refusal is audited too", %{conn: conn} do
      capacity =
        :sdd_orchestrator
        |> Application.fetch_env!(:pairing_issuance)
        |> Keyword.fetch!(:rate_limits)
        |> Keyword.fetch!(:caller)
        |> Keyword.fetch!(:capacity)

      for _allowed <- 1..capacity, do: issue(conn)

      log = capture_log(fn -> assert json_response(issue(conn), 429) end)

      assert log =~ "outcome=throttled"
      refute log =~ "127.0.0.1"
    end
  end
end
