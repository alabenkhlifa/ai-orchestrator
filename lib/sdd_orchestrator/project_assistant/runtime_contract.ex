defmodule SddOrchestrator.ProjectAssistant.RuntimeContract do
  @moduledoc """
  The single closed runtime contract every project-assistant turn's read
  tools and skill selection must pass through (AC-14, AC-15): the pinned
  `SddOrchestrator.ProjectAssistant.ReadToolManifest`, the negotiated
  `SddOrchestrator.ProjectAssistant.TrustedSkillBundle`, and one turn's
  `SddOrchestrator.ProjectAssistant.TurnBudget`, bound together immutably at
  turn start.

  `open_turn/1` is the ONLY constructor. It builds every field from trusted
  inputs only: this module's own fixed `ReadToolManifest.current/0` and
  `TrustedSkillBundle.current/0`, and caller-supplied *configuration*
  (budget ceiling overrides) — never a tool result, project content, or
  model output. Task 2's `BoundaryGate.authorize_turn/5` (the confirmed
  disclosed-boundary check) is a precondition a later task's turn
  orchestrator runs before ever calling this function; this module does not
  re-run it and does not read project or participant data itself.

  Once built, `manifest` and `skill_bundle` never change for the contract's
  lifetime; only `budget` advances, and only through `authorize_call/4`,
  `record_call/5`, `authorize_model_call/1`, `record_model_call/1`, and
  `cancel/1` — none of which accept untrusted content as an input that could
  feed back into `manifest` or `skill_bundle`. This is the structural proof
  AC-14 needs: there is no function in this module, or in `ReadToolManifest`,
  `TrustedSkillBundle`, or `TurnBudget`, whose input is
  `SddOrchestrator.ProjectAssistant.UntrustedContent`-tagged data and whose
  output is a manifest, a skill bundle, or a widened budget ceiling. The
  test suite greps this module's own source for exactly that absence in
  addition to behavioral proof.
  """

  alias SddOrchestrator.ProjectAssistant.{ReadToolManifest, TrustedSkillBundle, TurnBudget}

  @enforce_keys [:manifest, :skill_bundle, :budget]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manifest: ReadToolManifest.t(),
          skill_bundle: TrustedSkillBundle.t(),
          budget: TurnBudget.t()
        }

  @doc """
  Opens one turn's runtime contract.

  `opts`:
    * `:now` — defaults to `DateTime.utc_now/0`.
    * `:budget_limits` — configured ceiling overrides, merged over
      `TurnBudget.default_limits/0`.
    * `:requested_skill` — the skill-bundle identity to negotiate against
      the current manifest version; defaults to the pinned
      `TrustedSkillBundle.current/0`'s own map form, so a caller that
      supplies nothing gets the same pinned bundle every time.

  Returns `{:error, reason}` (never a downgraded, widened, or best-effort
  match) when the requested skill identity does not exactly match the
  pinned bundle — see `TrustedSkillBundle.negotiate/2`.
  """
  @spec open_turn(keyword()) :: {:ok, t()} | {:error, atom()}
  def open_turn(opts \\ []) do
    manifest = ReadToolManifest.current()
    requested_skill = Keyword.get(opts, :requested_skill, pinned_skill_request())

    with {:ok, skill_bundle} <-
           TrustedSkillBundle.negotiate(requested_skill, manifest.manifest_version) do
      budget =
        TurnBudget.new(
          now: Keyword.get(opts, :now, DateTime.utc_now()),
          limits: Keyword.get(opts, :budget_limits, %{})
        )

      {:ok, %__MODULE__{manifest: manifest, skill_bundle: skill_bundle, budget: budget}}
    end
  end

  @doc """
  `:ok` only when `operation_name` is on the closed manifest AND the budget
  currently permits another tool call. Never invokes the operation itself —
  the caller runs the bound Task 3/4/5 function only after this returns
  `:ok`.
  """
  @spec authorize_call(t(), String.t(), non_neg_integer(), DateTime.t()) :: :ok | {:error, atom()}
  def authorize_call(%__MODULE__{} = contract, operation_name, context_bytes, now) do
    with :ok <- ReadToolManifest.authorize_operation(contract.manifest, operation_name) do
      TurnBudget.authorize_tool_call(contract.budget, context_bytes, now)
    end
  end

  @doc """
  Records one completed, already-authorized tool call's context and result
  bytes. Refuses without mutating `contract` if the operation name is not on
  the manifest, or if recording would breach any budget ceiling.
  """
  @spec record_call(t(), String.t(), non_neg_integer(), non_neg_integer(), DateTime.t()) ::
          {:ok, t()} | {:error, atom()}
  def record_call(%__MODULE__{} = contract, operation_name, context_bytes, result_bytes, now) do
    with :ok <- ReadToolManifest.authorize_operation(contract.manifest, operation_name),
         {:ok, budget} <-
           TurnBudget.record_tool_call(contract.budget, context_bytes, result_bytes, now) do
      {:ok, %{contract | budget: budget}}
    end
  end

  @doc "`:ok` only when the turn is not cancelled and another model call remains within budget."
  @spec authorize_model_call(t()) :: :ok | {:error, atom()}
  def authorize_model_call(%__MODULE__{budget: budget}),
    do: TurnBudget.authorize_model_call(budget)

  @doc "Records one completed, already-authorized model call."
  @spec record_model_call(t()) :: {:ok, t()} | {:error, atom()}
  def record_model_call(%__MODULE__{} = contract) do
    with {:ok, budget} <- TurnBudget.record_model_call(contract.budget) do
      {:ok, %{contract | budget: budget}}
    end
  end

  @doc """
  Cancels the turn. Every later `authorize_call/4`, `record_call/5`,
  `authorize_model_call/1`, or `record_model_call/1` against the returned
  contract refuses with `{:error, :cancelled}` — no further tool call, model
  call, or mutation proceeds.
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = contract),
    do: %{contract | budget: TurnBudget.cancel(contract.budget)}

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{budget: budget}), do: TurnBudget.cancelled?(budget)

  @doc """
  A compact, content-free inspection of the contract's current shape, for
  security audit and logging — mirrors
  `SddOrchestrator.AIRuntime.SecurityLog`'s allowlisted-outcome style:
  manifest version and operation count, skill identity and digest, and every
  budget counter and ceiling. Never a prompt, answer, citation, path,
  project identifier, or participant identifier — none of those fields
  exist anywhere in this struct to begin with.
  """
  @spec audit(t()) :: map()
  def audit(%__MODULE__{} = contract) do
    %{
      manifest_version: contract.manifest.manifest_version,
      operation_count: length(contract.manifest.operations),
      skill: %{
        name: contract.skill_bundle.name,
        version: contract.skill_bundle.version,
        digest: contract.skill_bundle.digest
      },
      budget: %{
        tool_calls_used: contract.budget.tool_calls_used,
        tool_calls_max: contract.budget.limits.tool_calls,
        elapsed_ms: contract.budget.elapsed_ms,
        elapsed_ms_max: contract.budget.limits.elapsed_ms,
        context_bytes_used: contract.budget.context_bytes_used,
        context_bytes_max: contract.budget.limits.context_bytes,
        result_bytes_used: contract.budget.result_bytes_used,
        result_bytes_max: contract.budget.limits.result_bytes,
        model_usage_used: contract.budget.model_usage_used,
        model_usage_max: contract.budget.limits.model_usage,
        cancelled?: contract.budget.cancelled?
      }
    }
  end

  defp pinned_skill_request do
    bundle = TrustedSkillBundle.current()
    %{"name" => bundle.name, "version" => bundle.version, "digest" => bundle.digest}
  end
end
