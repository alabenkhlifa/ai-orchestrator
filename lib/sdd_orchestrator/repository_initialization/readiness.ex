defmodule SddOrchestrator.RepositoryInitialization.Readiness do
  @moduledoc """
  Independent assistant, specification, agent-execution, and release
  readiness for one just-initialized repository (specs/16 Task 6, AC-14).

  Distinct from `SddOrchestrator.RepositoryReadiness`: that module requires
  an approved repository execution profile and a selected pilot (Slice
  14/specs/30), a pipeline a repository fresh out of empty-repository
  initialization has never gone through. Evaluating this module's own four
  axes never calls `RepositoryReadiness` or its dependencies.

  Only `evaluate/2` reads anything, and it writes nothing: a blocked axis is
  a value, not an effect.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.RepositoryInitialization.Result

  @type stage :: :assistant | :specification | :agent_execution | :release

  @type reason ::
          :no_worker_paired
          | :specification_not_created
          | :no_approved_execution_profile
          | :release_gate_pending

  @type axis_status :: :ready | {:blocked, reason()}

  @type t :: %__MODULE__{
          assistant: axis_status(),
          specification: axis_status(),
          agent_execution: axis_status(),
          release: axis_status(),
          earliest_blocked_stage: stage() | nil
        }

  @axes [:assistant, :specification, :agent_execution, :release]

  @enforce_keys @axes ++ [:earliest_blocked_stage]
  defstruct @enforce_keys

  @doc """
  Evaluates the four independent readiness axes for one completed handoff
  (`Handoff.complete/4`'s `{:ok, result}`).

  `:assistant` is ready once a worker is paired for `workspace`.
  `:specification` is ready once `result.specification_id` is set (which
  `evaluate/2` should only ever be called with — a caller with a `result`
  whose handoff has not completed has a bug upstream, not a reason to guess).
  `:agent_execution` and `:release` are always blocked: a freshly initialized
  project has not gone through the Slice 14/specs/30 assessment-and-profile
  pipeline, and this slice's own release gates (live worker/working-agent
  smoke proof, deployment-specific privacy/legal evidence) remain outstanding
  for every project this task hands off, with no exception.
  """
  @spec evaluate(DeviceWorkspace.t(), Result.t()) :: t()
  def evaluate(%DeviceWorkspace{} = workspace, %Result{} = result) do
    axes = %{
      assistant: assistant_status(workspace),
      specification: specification_status(result),
      agent_execution: {:blocked, :no_approved_execution_profile},
      release: {:blocked, :release_gate_pending}
    }

    axes
    |> Map.put(:earliest_blocked_stage, earliest_blocked_stage(axes))
    |> then(&struct!(__MODULE__, &1))
  end

  defp assistant_status(%DeviceWorkspace{id: id}) do
    case Pairing.active_workers(id) do
      [] -> {:blocked, :no_worker_paired}
      _workers -> :ready
    end
  end

  defp specification_status(%Result{specification_id: nil}),
    do: {:blocked, :specification_not_created}

  defp specification_status(%Result{}), do: :ready

  defp earliest_blocked_stage(axes) do
    Enum.find(@axes, fn axis -> match?({:blocked, _reason}, Map.fetch!(axes, axis)) end)
  end
end
