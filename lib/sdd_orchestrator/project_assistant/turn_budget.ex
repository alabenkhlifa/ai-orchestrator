defmodule SddOrchestrator.ProjectAssistant.TurnBudget do
  @moduledoc """
  Task 6's cumulative per-turn budgets and cancellation (AC-15): tool-call
  count, elapsed time, context bytes (what goes into the model), result
  bytes (what a tool result returns), and model-usage, each enforced against
  a configured ceiling and reported through a normalized, closed limit-
  outcome vocabulary rather than a generic exception.

  This is a pure, immutable value threaded by the caller, mirroring
  `SddOrchestrator.ProjectAssistant.ProgressiveDiscoveryPlanner`'s
  budget/exploration pattern: every function here takes a `t()` and returns
  either an updated `t()` or a typed error, never mutates a process, ETS
  table, or database row, and holds no state of its own between calls.

  Every counter (`tool_calls_used`, `context_bytes_used`,
  `result_bytes_used`, `model_usage_used`) only ever grows, and elapsed time
  only ever advances with the caller-supplied `now`, so once a ceiling is
  hit it stays hit for every later check against that same accumulated
  state — there is no separate "exhausted" flag to fall out of sync.
  Cancellation is the one exception: it is an explicit, sticky flag
  (`cancelled?`) set once and checked first by every function below, so a
  cancelled turn refuses every further tool call, model call, and mutation
  regardless of how much of its budget remained.

  There is no natural existing "model usage" hook to tie into:
  `SddOrchestrator.ProjectAssistant.RuntimeAvailability` deliberately never
  reads `SddOrchestrator.AIRuntime.RuntimeProjections.owner_projection/3`
  specifically because it returns exact account-wide quota, credits, and
  spend this feature must never receive at all (see that module's own
  moduledoc). `model_usage` here is therefore a simple project-assistant-
  configured ceiling on how many model round-trips one turn may make,
  entirely independent of and never reading any AIRuntime quota field.
  """

  @default_limits %{
    tool_calls: 20,
    elapsed_ms: 60_000,
    context_bytes: 200_000,
    result_bytes: 200_000,
    model_usage: 6
  }

  @enforce_keys [
    :limits,
    :started_at,
    :tool_calls_used,
    :elapsed_ms,
    :context_bytes_used,
    :result_bytes_used,
    :model_usage_used,
    :cancelled?
  ]
  defstruct @enforce_keys

  @type limits :: %{
          tool_calls: pos_integer(),
          elapsed_ms: pos_integer(),
          context_bytes: pos_integer(),
          result_bytes: pos_integer(),
          model_usage: pos_integer()
        }

  @type t :: %__MODULE__{
          limits: limits(),
          started_at: DateTime.t(),
          tool_calls_used: non_neg_integer(),
          elapsed_ms: non_neg_integer(),
          context_bytes_used: non_neg_integer(),
          result_bytes_used: non_neg_integer(),
          model_usage_used: non_neg_integer(),
          cancelled?: boolean()
        }

  @type limit_reason ::
          :cancelled
          | :tool_call_limit
          | :elapsed_time_limit
          | :context_byte_limit
          | :result_byte_limit
          | :model_usage_limit

  @doc """
  The configured default ceilings, falling back to this module's built-in
  defaults — mirrors
  `SddOrchestrator.ProjectAssistant.RepositoryExclusions.configured/0`'s
  Application-env-with-fallback shape so a deployment may tighten budgets
  without changing this contract.
  """
  @spec default_limits() :: limits()
  def default_limits do
    Map.merge(
      @default_limits,
      Application.get_env(:sdd_orchestrator, :project_assistant_turn_budget, %{})
    )
  end

  @doc """
  Opens one turn's budget.

  `opts`:
    * `:now` — defaults to `DateTime.utc_now/0`.
    * `:limits` — ceiling overrides merged over `default_limits/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limits = opts |> Keyword.get(:limits, %{}) |> merge_limits()

    %__MODULE__{
      limits: limits,
      started_at: now,
      tool_calls_used: 0,
      elapsed_ms: 0,
      context_bytes_used: 0,
      result_bytes_used: 0,
      model_usage_used: 0,
      cancelled?: false
    }
  end

  @doc """
  `:ok` only when a next tool call is currently permitted: the turn is not
  cancelled, and the tool-call count, elapsed time, and the context bytes
  this call would add all remain within their configured ceiling.

  Never mutates `budget`. Callers run this immediately before invoking a
  read tool, then combine it with `record_tool_call/4` once the tool
  actually returns a result.
  """
  @spec authorize_tool_call(t(), non_neg_integer(), DateTime.t()) ::
          :ok | {:error, limit_reason()}
  def authorize_tool_call(%__MODULE__{cancelled?: true}, _context_bytes, _now),
    do: {:error, :cancelled}

  def authorize_tool_call(%__MODULE__{} = budget, context_bytes, %DateTime{} = now)
      when is_integer(context_bytes) and context_bytes >= 0 do
    with :ok <- check_tool_calls(budget),
         :ok <- check_elapsed(budget, now) do
      check_context_bytes(budget, context_bytes)
    end
  end

  @doc """
  Records one completed, already-authorized tool call's context and result
  bytes, and advances elapsed time to `now`.

  Re-runs `authorize_tool_call/3` first, so a caller cannot record a call
  that budget enforcement would already have refused, then separately
  checks the result-byte ceiling against what the call actually returned —
  a ceiling `authorize_tool_call/3` cannot know in advance. On any refusal
  `budget` is returned unmutated: an over-budget result is never partially
  committed.
  """
  @spec record_tool_call(t(), non_neg_integer(), non_neg_integer(), DateTime.t()) ::
          {:ok, t()} | {:error, limit_reason()}
  def record_tool_call(%__MODULE__{} = budget, context_bytes, result_bytes, %DateTime{} = now)
      when is_integer(result_bytes) and result_bytes >= 0 do
    with :ok <- authorize_tool_call(budget, context_bytes, now) do
      prospective_result_bytes = budget.result_bytes_used + result_bytes

      if prospective_result_bytes <= budget.limits.result_bytes do
        {:ok,
         %{
           budget
           | tool_calls_used: budget.tool_calls_used + 1,
             context_bytes_used: budget.context_bytes_used + context_bytes,
             result_bytes_used: prospective_result_bytes,
             elapsed_ms: DateTime.diff(now, budget.started_at, :millisecond)
         }}
      else
        {:error, :result_byte_limit}
      end
    end
  end

  @doc "`:ok` only when the turn is not cancelled and another model call remains within budget."
  @spec authorize_model_call(t()) :: :ok | {:error, limit_reason()}
  def authorize_model_call(%__MODULE__{cancelled?: true}), do: {:error, :cancelled}
  def authorize_model_call(%__MODULE__{} = budget), do: check_model_usage(budget)

  @doc "Records one completed, already-authorized model call."
  @spec record_model_call(t()) :: {:ok, t()} | {:error, limit_reason()}
  def record_model_call(%__MODULE__{} = budget) do
    with :ok <- authorize_model_call(budget) do
      {:ok, %{budget | model_usage_used: budget.model_usage_used + 1}}
    end
  end

  @doc """
  Marks the turn cancelled. Every subsequent `authorize_tool_call/3`,
  `record_tool_call/4`, `authorize_model_call/1`, or `record_model_call/1`
  against the returned budget refuses with `{:error, :cancelled}` — no
  further tool call, model call, or mutation proceeds.
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = budget), do: %{budget | cancelled?: true}

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{cancelled?: cancelled}), do: cancelled

  defp merge_limits(overrides), do: Map.merge(default_limits(), Map.new(overrides))

  defp check_tool_calls(%__MODULE__{tool_calls_used: used, limits: %{tool_calls: max}}) do
    if used < max, do: :ok, else: {:error, :tool_call_limit}
  end

  defp check_elapsed(%__MODULE__{started_at: started_at, limits: %{elapsed_ms: max}}, now) do
    if DateTime.diff(now, started_at, :millisecond) <= max,
      do: :ok,
      else: {:error, :elapsed_time_limit}
  end

  defp check_context_bytes(
         %__MODULE__{context_bytes_used: used, limits: %{context_bytes: max}},
         additional
       ) do
    if used + additional <= max, do: :ok, else: {:error, :context_byte_limit}
  end

  defp check_model_usage(%__MODULE__{model_usage_used: used, limits: %{model_usage: max}}) do
    if used < max, do: :ok, else: {:error, :model_usage_limit}
  end
end
