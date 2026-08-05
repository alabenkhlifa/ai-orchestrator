defmodule SddOrchestrator.Privacy.AnalyticsAbsenceTest do
  @moduledoc """
  Data-store proof that Slice 01 retains no product analytics (AC-41).

  The transmitted side — that the browser issues no analytics request — is proven by
  the shared presentation-foundation browser test ("issues no external font, icon, or
  analytics request"). This checks the stored side: no database table retains
  analytics, and the approved processing inventory declares none.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Privacy.ProcessingInventory

  test "no public table retains product analytics" do
    {:ok, %{rows: rows}} =
      Repo.query("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'")

    tables = List.flatten(rows)

    for table <- tables do
      refute Regex.match?(
               ~r/analytic|metric|tracking|telemetry_event|pageview|impression/i,
               table
             ),
             "unexpected analytics-like table: #{table}"
    end

    # Sanity: the real product tables are present, so the scan saw the schema.
    assert "projects" in tables
    assert "accounts" in tables

    # Sanity: the AI-runtime schema is inside the same scan, so its absence of
    # analytics tables is proven rather than assumed.
    assert "personal_ai_connections" in tables
    assert "agent_runtime_observations" in tables
  end

  test "the processing inventory declares no analytics activity" do
    refute ProcessingInventory.analytics?()
  end
end
