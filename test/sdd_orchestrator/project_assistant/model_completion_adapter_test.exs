defmodule SddOrchestrator.ProjectAssistant.ModelCompletionAdapterTest do
  @moduledoc """
  specs/12-project-assistant Task 7 focused proof: no live model-completion
  loop exists anywhere in this codebase yet, so the default adapter fails
  closed with a normalized reason rather than fabricating an answer.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.ModelCompletionAdapter

  test "the default configured adapter is Unavailable" do
    assert ModelCompletionAdapter.configured() == ModelCompletionAdapter.Unavailable
  end

  test "Unavailable never fabricates an answer" do
    request = %{question_text: "anything", context_content: %{}, context_version: "v"}
    assert {:error, :model_unavailable} = ModelCompletionAdapter.Unavailable.complete(request)
  end

  test "a configured adapter override is honored" do
    Application.put_env(
      :sdd_orchestrator,
      :model_completion_adapter,
      SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter
    )

    on_exit(fn -> Application.delete_env(:sdd_orchestrator, :model_completion_adapter) end)

    assert ModelCompletionAdapter.configured() ==
             SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter
  end
end
