defmodule SddOrchestrator.Delivery.InitializationDispatch.Result do
  @moduledoc """
  One typed response to a dispatched `InitializationManifest`.
  """

  alias SddOrchestrator.Delivery.InitializationManifest

  @enforce_keys [:manifest, :agent_version, :handle, :thread_start]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          manifest: InitializationManifest.t(),
          agent_version: String.t(),
          handle: term(),
          thread_start: :new | :resumed
        }
end

defmodule SddOrchestrator.Delivery.InitializationDispatch do
  @moduledoc """
  The pre-project foundation that routes one capability-scoped dispatch to a
  configured `AgentAdapter`, entirely independent of `capability:local-worker-run-execution`
  (specs/33), which cannot exist before this slice creates its own project.

  A connection negotiates the capability grants it supports once; each
  dispatch then names the one grant its manifest requires, and is refused
  unless that grant was actually negotiated. This is the sole place a
  read-only, plan-discovery-only connection is kept from ever reaching a
  staging-write operation, and vice versa.

  Only `SddOrchestrator.Delivery.AgentAdapter`'s generic helpers are reused
  here (`adapter/0`, `version/1`, `environment/0`) — never `project/2` or
  `launch/3`, which are hard-coupled to `ExecutionManifest` and the
  project-scoped `Delivery.Worker.Workspace`. Filesystem staging is not this
  foundation's concern; it belongs to whichever later task actually builds a
  staging root and folds it into a manifest's `agent_ref`/`instructions`.
  """

  alias SddOrchestrator.Delivery.AgentAdapter
  alias SddOrchestrator.Delivery.InitializationDispatch.Result
  alias SddOrchestrator.Delivery.InitializationManifest

  @spec capability_grants() :: [String.t()]
  def capability_grants, do: InitializationManifest.capability_grants()

  @doc """
  Resolves the capability-grant contract for one worker announcement.

  The granted set is the intersection of what the worker announced and what
  this foundation supports, so a worker can never widen its own contract. An
  empty intersection fails closed before any dispatch is possible.
  """
  @spec negotiate(map()) :: {:ok, %{capability_grants: [String.t()]}} | {:error, atom()}
  def negotiate(%{"capability_grants" => announced}) when is_list(announced) do
    granted =
      announced
      |> Enum.filter(&(&1 in capability_grants()))
      |> Enum.uniq()
      |> Enum.sort()

    case granted do
      [] -> {:error, :no_shared_capability_grant}
      granted -> {:ok, %{capability_grants: granted}}
    end
  end

  def negotiate(_announcement), do: {:error, :invalid_announcement}

  @doc """
  Confirms one required capability grant was actually negotiated.

  This is the command-routing enforcement point: a connection that only
  negotiated `plan_discovery` is denied a manifest requiring `staging_write`,
  and the reverse.
  """
  @spec authorize_grant([String.t()], String.t()) :: :ok | {:error, :capability_grant_denied}
  def authorize_grant(negotiated_grants, required_grant) when is_list(negotiated_grants) do
    if required_grant in negotiated_grants,
      do: :ok,
      else: {:error, :capability_grant_denied}
  end

  def authorize_grant(_negotiated_grants, _required_grant), do: {:error, :capability_grant_denied}

  @doc """
  Validates one manifest, enforces its capability grant against what this
  connection negotiated, and dispatches it to the configured `AgentAdapter`.
  """
  @spec dispatch(map(), [String.t()]) :: {:ok, Result.t()} | {:error, atom()}
  def dispatch(manifest_attrs, negotiated_grants) do
    with {:ok, manifest} <- InitializationManifest.new(manifest_attrs),
         :ok <- authorize_grant(negotiated_grants, manifest.capability_grant),
         {:ok, agent_version} <- AgentAdapter.version(),
         {:ok, handle, thread_start} <- start_agent(manifest) do
      {:ok,
       %Result{
         manifest: manifest,
         agent_version: agent_version,
         handle: handle,
         thread_start: thread_start
       }}
    end
  end

  defp start_agent(%InitializationManifest{} = manifest) do
    module = AgentAdapter.adapter()

    projected = %{
      "device_workspace_id" => manifest.device_workspace_id,
      "dispatch_id" => manifest.dispatch_id,
      "capability_grant" => manifest.capability_grant,
      "agent_ref" => manifest.agent_ref,
      "instructions" => manifest.instructions
    }

    case module.start(%{
           agent_input: projected,
           environment: AgentAdapter.environment(),
           thread_ref: nil
         }) do
      {:ok, %{reference: _reference, thread_ref: thread_ref, resumed?: resumed?} = handle}
      when (is_binary(thread_ref) or is_nil(thread_ref)) and is_boolean(resumed?) ->
        {:ok, handle, if(resumed?, do: :resumed, else: :new)}

      {:ok, _malformed_handle} ->
        {:error, :agent_launch_failed}

      {:error, :agent_unavailable} ->
        {:error, :agent_unavailable}

      {:error, _reason} ->
        {:error, :agent_launch_failed}
    end
  end
end
