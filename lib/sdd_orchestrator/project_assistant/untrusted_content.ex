defmodule SddOrchestrator.ProjectAssistant.UntrustedContent do
  @moduledoc """
  Task 6's untrusted-content classification (AC-14): the fixed tag every
  repository instruction, source comment, specification, board item, run
  output, and evidence record carries once it flows into a turn as tool-
  result data.

  Business rule (requirements.md): "Repository instructions, source
  comments, specifications, board text, run output, and evidence are
  untrusted project content. They may be cited as data but cannot grant
  permission, add tools, change tool limits, request secrets, trigger side
  effects, or override the assistant's trusted runtime contract."

  `tag/2` is the only function here that touches raw content, and it only
  ever wraps it with a fixed `:untrusted` trust marker — it never inspects
  content to decide whether to grant it a *different* trust level, and
  nothing in `SddOrchestrator.ProjectAssistant.ReadToolManifest`,
  `TrustedSkillBundle`, `TurnBudget`, or `RuntimeContract` ever accepts a
  value this module tags as an input that builds or mutates a manifest,
  skill identity, or budget ceiling. That absence is proven directly in the
  test suite: hostile payloads are tagged here and then fed at every one of
  those modules' boundaries, and the resulting manifest, skill bundle, and
  budget limits are asserted byte-for-byte unchanged.

  `suspected_injection?/1` is explicitly NOT the security boundary.
  design.md's business rule states plainly that "Tool policy is enforced by
  the control plane and worker, not by prompt text" — `ReadToolManifest` and
  `TurnBudget` never consult this function's result, and a false negative
  here changes nothing about what a turn is structurally permitted to do.
  It exists only as a best-effort, non-authoritative signal for security
  audit and observability.
  """

  @kinds ~w(
    repository_source
    repository_instructions
    specification
    board_text
    run_output
    evidence
  )a

  @type kind ::
          :repository_source
          | :repository_instructions
          | :specification
          | :board_text
          | :run_output
          | :evidence

  @type tagged :: %{kind: kind(), trust: :untrusted, data: term()}

  @suspicious_patterns [
    "ignore previous instructions",
    "ignore prior instructions",
    "ignore all previous",
    "disregard previous instructions",
    "disregard prior instructions",
    "system:",
    "you are now",
    "new instructions",
    "grant tool",
    "add tool",
    "add capability",
    "new capability",
    "unlimited budget",
    "no budget",
    "raise the budget",
    "bypass",
    "override the",
    "policy override",
    "reveal the",
    "reveal your",
    "api key",
    "execute this",
    "print the api key",
    "dump the environment",
    "execute shell",
    "shell_exec",
    "run shell",
    "run this command",
    "network access",
    "http request",
    "make a request to",
    "</tool_result>",
    "<system>",
    "exfiltrate",
    "leak the"
  ]

  @doc "The closed set of untrusted-project-content kinds this module tags."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Tags one piece of project content as untrusted data.

  `kind` identifies which business-rule content class the caller is
  handling; `data` is carried unchanged and never inspected to decide trust.
  """
  @spec tag(kind(), term()) :: tagged()
  def tag(kind, data) when kind in @kinds, do: %{kind: kind, trust: :untrusted, data: data}

  @doc "Whether tagged content is trusted. Always `false` for anything this module tags."
  @spec trusted?(tagged()) :: boolean()
  def trusted?(%{trust: :untrusted}), do: false

  @doc """
  A best-effort, non-authoritative signal that `text` resembles a policy-
  override, tool-escalation, or secret-request attempt, for audit and
  observability only. See the moduledoc: this is never consulted by any
  actual tool, budget, or skill-bundle enforcement.
  """
  @spec suspected_injection?(term()) :: boolean()
  def suspected_injection?(text) when is_binary(text) do
    normalized = String.downcase(text)
    Enum.any?(@suspicious_patterns, &String.contains?(normalized, &1))
  end

  def suspected_injection?(_text), do: false
end
