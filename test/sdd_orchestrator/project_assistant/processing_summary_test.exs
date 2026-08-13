defmodule SddOrchestrator.ProjectAssistant.ProcessingSummaryTest do
  @moduledoc """
  specs/12-project-assistant Task 2 focused proof for
  `SddOrchestrator.ProjectAssistant.ProcessingSummary`: the versioned,
  disclosed boundary and its stable digest business rule 69 requires.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.ProcessingSummary

  @runtime %{provider: "openai_codex", authentication_mode: "chatgpt"}

  test "builds the disclosed fields at the current version" do
    summary = ProcessingSummary.build(@runtime, true, :hosted)

    assert summary.version == ProcessingSummary.version()

    assert summary.execution == %{
             location: :participant_personal_worker,
             provider: "openai_codex",
             authentication_mode: "chatgpt"
           }

    assert summary.repository_worker_available == true
    assert summary.transfer_boundary == :project_context_and_on_demand_repository_source
    assert summary.storage == %{conversation: :hosted, index: :hosted}
    assert summary.retention == %{max_days: ProcessingSummary.max_retention_days()}
  end

  test "no repository worker narrows the transfer boundary to project context only" do
    summary = ProcessingSummary.build(@runtime, false, :device)

    assert summary.transfer_boundary == :project_context_only
    assert summary.storage == %{conversation: :device, index: :device}
  end

  test "the digest is stable for an identical summary and changes with any disclosed field" do
    summary = ProcessingSummary.build(@runtime, true, :hosted)
    digest = ProcessingSummary.digest(summary)

    assert ProcessingSummary.digest(ProcessingSummary.build(@runtime, true, :hosted)) == digest

    refute ProcessingSummary.digest(ProcessingSummary.build(@runtime, false, :hosted)) == digest
    refute ProcessingSummary.digest(ProcessingSummary.build(@runtime, true, :device)) == digest

    refute ProcessingSummary.digest(
             ProcessingSummary.build(
               %{provider: "openai_codex", authentication_mode: "api_key"},
               true,
               :hosted
             )
           ) == digest
  end

  test "an unknown provider (no eligible connection) still produces a stable digest" do
    unknown = %{provider: nil, authentication_mode: nil}
    summary = ProcessingSummary.build(unknown, false, :hosted)

    assert is_binary(ProcessingSummary.digest(summary))
    assert summary.execution.provider == nil
  end
end
