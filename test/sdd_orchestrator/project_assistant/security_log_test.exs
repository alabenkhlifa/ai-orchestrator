defmodule SddOrchestrator.ProjectAssistant.SecurityLogTest do
  @moduledoc """
  specs/12-project-assistant Task 9 focused proof: content-free structured
  security-log outcomes (AC-19, AC-20).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SddOrchestrator.ProjectAssistant.SecurityLog

  describe "audit/3" do
    test "emits nothing for a success" do
      log =
        capture_log(fn ->
          assert :ok == SecurityLog.audit(:ok, :panel_open)
          assert {:ok, "value"} == SecurityLog.audit({:ok, "value"}, :turn)
        end)

      assert log == ""
    end

    test "returns the original result unchanged" do
      result = {:error, :unauthorized}
      assert SecurityLog.audit(result, :panel_open) == result
    end

    test "classifies a denied outcome and emits only allowlisted, content-free fields" do
      log =
        capture_log(fn ->
          SecurityLog.audit({:error, :unauthorized}, :panel_open,
            correlation_id: "11111111-1111-1111-1111-111111111111"
          )
        end)

      assert log =~ "[project_assistant_security]"
      assert log =~ ~s("event_type":"panel_open")
      assert log =~ ~s("outcome":"denied")
      assert log =~ "11111111-1111-1111-1111-111111111111"
    end

    test "classifies unavailable and rejected outcomes" do
      assert capture_log(fn -> SecurityLog.audit({:error, :worker_unavailable}, :turn) end) =~
               ~s("outcome":"unavailable")

      assert capture_log(fn -> SecurityLog.audit({:error, :stale}, :citation_resolution) end) =~
               ~s("outcome":"rejected")
    end

    test "redacts an unrecognised reason to :failed rather than encoding it" do
      log =
        capture_log(fn ->
          SecurityLog.audit(
            {:error, %{prompt: "a prompt", secret: "sk-aaaaaaaaaaaaaaaaaaaaaaaa"}},
            :turn
          )
        end)

      assert log =~ ~s("outcome":"failed")
      refute log =~ "prompt"
      refute log =~ "sk-aaaaaaaaaaaaaaaaaaaaaaaa"
    end
  end

  test "events/0 is the fixed closed vocabulary" do
    assert SecurityLog.events() == [
             :panel_open,
             :boundary_confirmation,
             :turn,
             :repository_observation,
             :citation_resolution,
             :redaction,
             :retention_sweep,
             :deletion
           ]
  end

  test "retention_days/0 reads the deployment-enforced ceiling" do
    assert SecurityLog.retention_days() == 30
  end
end
