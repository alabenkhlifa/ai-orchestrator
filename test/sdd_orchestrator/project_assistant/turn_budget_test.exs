defmodule SddOrchestrator.ProjectAssistant.TurnBudgetTest do
  @moduledoc """
  specs/12-project-assistant Task 6 focused proof (AC-15): tool-call,
  elapsed-time, context-byte, result-byte, and model-usage budgets are
  tracked cumulatively across one turn, refuse further tool calls once any
  ceiling is hit, report a normalized limit-outcome vocabulary rather than a
  generic exception, and cancellation ends the turn without mutation.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.TurnBudget

  @start ~U[2026-01-01 12:00:00Z]

  defp small_budget(overrides \\ %{}) do
    limits =
      Map.merge(
        %{
          tool_calls: 2,
          elapsed_ms: 1_000,
          context_bytes: 100,
          result_bytes: 100,
          model_usage: 2
        },
        overrides
      )

    TurnBudget.new(now: @start, limits: limits)
  end

  describe "tool-call count" do
    test "authorizes while under the ceiling and refuses once it is reached" do
      budget = small_budget()

      assert :ok = TurnBudget.authorize_tool_call(budget, 1, @start)
      assert {:ok, budget} = TurnBudget.record_tool_call(budget, 1, 1, @start)

      assert :ok = TurnBudget.authorize_tool_call(budget, 1, @start)
      assert {:ok, budget} = TurnBudget.record_tool_call(budget, 1, 1, @start)

      assert TurnBudget.authorize_tool_call(budget, 1, @start) == {:error, :tool_call_limit}
      assert TurnBudget.record_tool_call(budget, 1, 1, @start) == {:error, :tool_call_limit}
    end
  end

  describe "elapsed time" do
    test "refuses once the configured window has passed" do
      budget = small_budget()
      later = DateTime.add(@start, 2, :second)

      assert TurnBudget.authorize_tool_call(budget, 1, later) == {:error, :elapsed_time_limit}
      assert TurnBudget.record_tool_call(budget, 1, 1, later) == {:error, :elapsed_time_limit}
    end

    test "does not mutate the budget when refused" do
      budget = small_budget()
      later = DateTime.add(@start, 2, :second)

      assert TurnBudget.record_tool_call(budget, 1, 1, later) == {:error, :elapsed_time_limit}
      assert budget.tool_calls_used == 0
      assert budget.elapsed_ms == 0
    end
  end

  describe "context bytes" do
    test "refuses a call whose context bytes would exceed the ceiling" do
      budget = small_budget()

      assert TurnBudget.authorize_tool_call(budget, 101, @start) == {:error, :context_byte_limit}
    end

    test "accumulates across calls until the ceiling is reached" do
      budget = small_budget()

      assert {:ok, budget} = TurnBudget.record_tool_call(budget, 60, 1, @start)
      assert TurnBudget.authorize_tool_call(budget, 60, @start) == {:error, :context_byte_limit}
      assert {:ok, _budget} = TurnBudget.record_tool_call(budget, 40, 1, @start)
    end
  end

  describe "result bytes" do
    test "refuses recording a result that would exceed the ceiling, without recording it" do
      budget = small_budget()

      assert TurnBudget.record_tool_call(budget, 1, 101, @start) == {:error, :result_byte_limit}
      assert budget.result_bytes_used == 0
      assert budget.tool_calls_used == 0
    end

    test "an over-budget result does not silently truncate and succeed" do
      budget = small_budget(%{result_bytes: 50})

      assert {:ok, budget} = TurnBudget.record_tool_call(budget, 1, 30, @start)
      assert TurnBudget.record_tool_call(budget, 1, 30, @start) == {:error, :result_byte_limit}
      assert budget.result_bytes_used == 30
    end
  end

  describe "model usage" do
    test "authorizes while under the ceiling and refuses once it is reached" do
      budget = small_budget()

      assert :ok = TurnBudget.authorize_model_call(budget)
      assert {:ok, budget} = TurnBudget.record_model_call(budget)

      assert :ok = TurnBudget.authorize_model_call(budget)
      assert {:ok, budget} = TurnBudget.record_model_call(budget)

      assert TurnBudget.authorize_model_call(budget) == {:error, :model_usage_limit}
      assert TurnBudget.record_model_call(budget) == {:error, :model_usage_limit}
    end
  end

  describe "cancellation ends the turn without mutation" do
    test "a cancelled budget refuses every further tool call, regardless of remaining budget" do
      budget = small_budget() |> TurnBudget.cancel()

      assert TurnBudget.cancelled?(budget)
      assert TurnBudget.authorize_tool_call(budget, 1, @start) == {:error, :cancelled}
      assert TurnBudget.record_tool_call(budget, 1, 1, @start) == {:error, :cancelled}
      assert TurnBudget.authorize_model_call(budget) == {:error, :cancelled}
      assert TurnBudget.record_model_call(budget) == {:error, :cancelled}
    end

    test "cancelling does not change any usage counter" do
      budget = small_budget()
      {:ok, used} = TurnBudget.record_tool_call(budget, 5, 5, @start)

      cancelled = TurnBudget.cancel(used)

      assert cancelled.tool_calls_used == used.tool_calls_used
      assert cancelled.context_bytes_used == used.context_bytes_used
      assert cancelled.result_bytes_used == used.result_bytes_used
      assert cancelled.limits == used.limits
    end

    test "cancellation is sticky: authorizing again after cancel never re-opens the turn" do
      budget = small_budget() |> TurnBudget.cancel()

      for _ <- 1..3 do
        assert TurnBudget.authorize_tool_call(budget, 1, @start) == {:error, :cancelled}
      end
    end
  end

  describe "default_limits/0" do
    test "falls back to built-in defaults with no application config" do
      Application.delete_env(:sdd_orchestrator, :project_assistant_turn_budget)
      limits = TurnBudget.default_limits()

      assert limits.tool_calls > 0
      assert limits.elapsed_ms > 0
      assert limits.context_bytes > 0
      assert limits.result_bytes > 0
      assert limits.model_usage > 0
    end
  end
end
