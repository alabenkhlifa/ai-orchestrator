defmodule SddOrchestrator.ProjectAssistant.BoundaryGate do
  @moduledoc """
  The single processing-boundary confirmation gate every later task's read
  tool or model call must pass through (AC-04, AC-05, AC-06).

  Ties together the acting participant's normalized runtime availability
  (`RuntimeAvailability`), the disclosed processing summary and its stable
  digest (`ProcessingSummary`), and the stored confirmation
  (`ProjectAssistantBoundaryStore`) into three operations:

    * `status/5` — what the panel shows: current availability, the current
      disclosed summary, the stored confirmation (if any), and whether a
      fresh confirmation is required.
    * `confirm/5` — records the acting participant's confirmation of the
      *current* disclosed boundary.
    * `authorize_turn/5` — the pre-tool gate a later task calls immediately
      before running any read tool or model call. It never runs one itself.

  A material boundary change is never a separately stored flag: the stored
  confirmation's digest simply stops matching the freshly computed one, so
  there is no invalidation state that can drift out of sync with reality. An
  unchanged digest lets a later question proceed without asking again
  (AC-06).
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices

  alias SddOrchestrator.ProjectAssistant.{
    Guard,
    ProcessingSummary,
    RepositoryWorkerAvailability,
    RuntimeAvailability
  }

  alias SddOrchestrator.ProjectAssistantBoundaryStore

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: Guard.actor()

  @doc """
  Resolves the acting participant's current runtime availability, the
  current disclosed processing summary, the stored confirmation (if any),
  and whether a fresh confirmation is required.

  `account` is the acting participant's hosted account for AI-runtime
  purposes (see `RuntimeAvailability.resolve/3`); `nil` is safe and resolves
  to a `:setup_needed` availability.
  """
  @spec status(authority(), String.t(), actor(), term(), keyword()) ::
          {:ok, map()} | {:error, :unauthorized}
  def status(authority, project_id, actor, account, opts \\ []) do
    with {:ok, confirmation} <-
           ProjectAssistantBoundaryStore.get_confirmation(authority, project_id, actor) do
      {runtime, summary, digest} = resolve_boundary(authority, project_id, account, opts)

      {:ok,
       %{
         availability: runtime,
         processing_summary: summary,
         processing_digest: digest,
         confirmation: confirmation,
         confirmation_required: confirmation_required?(confirmation, digest)
       }}
    end
  end

  @doc """
  Records the acting participant's confirmation of the current disclosed
  processing boundary, replacing any prior confirmation.

  Refuses `:setup_needed` (`{:error, :setup_needed}`): with no eligible
  personal connection there is no concrete provider or worker boundary to
  confirm yet, and the panel should route to setup instead.
  """
  @spec confirm(authority(), String.t(), actor(), term(), keyword()) ::
          {:ok, term()} | {:error, :unauthorized | :setup_needed | term()}
  def confirm(authority, project_id, actor, account, opts \\ []) do
    with :ok <- authorize_participation(authority, project_id, actor, :confirm_boundary) do
      {runtime, _summary, digest} = resolve_boundary(authority, project_id, account, opts)

      case runtime.state do
        :setup_needed ->
          {:error, :setup_needed}

        _known_provider ->
          now =
            opts
            |> Keyword.get(:now, DateTime.utc_now())
            |> DateTime.truncate(:second)

          ProjectAssistantBoundaryStore.confirm(
            authority,
            project_id,
            actor,
            digest,
            ProcessingSummary.version(),
            now
          )
      end
    end
  end

  @doc """
  The pre-tool gate. `:ok` only when the acting participant is currently
  authorized to ask, the runtime is available right now, and a stored
  confirmation matches the current processing boundary exactly. Every other
  outcome refuses without running a read tool or model call — never a
  fallback provider, never a stale confirmation silently accepted.
  """
  @spec authorize_turn(authority(), String.t(), actor(), term(), keyword()) ::
          :ok
          | {:error,
             :unauthorized
             | :setup_needed
             | :unavailable
             | :temporarily_limited
             | :confirmation_required}
  def authorize_turn(authority, project_id, actor, account, opts \\ []) do
    with :ok <- authorize_participation(authority, project_id, actor, :ask) do
      {runtime, _summary, digest} = resolve_boundary(authority, project_id, account, opts)

      with :ok <- require_available(runtime),
           {:ok, confirmation} <-
             ProjectAssistantBoundaryStore.get_confirmation(authority, project_id, actor) do
        require_matching_confirmation(confirmation, digest)
      end
    end
  end

  defp resolve_boundary(authority, project_id, account, opts) do
    {:ok, runtime} = RuntimeAvailability.resolve(account, consumer_ref(project_id), opts)
    worker_available? = RepositoryWorkerAvailability.available?(authority, project_id)
    summary = ProcessingSummary.build(runtime, worker_available?, storage_mode(authority))
    digest = ProcessingSummary.digest(summary)
    {runtime, summary, digest}
  end

  defp consumer_ref(project_id), do: "project_assistant:" <> project_id

  defp storage_mode(%PersonalWorkspace{}), do: :hosted
  defp storage_mode(%DeviceWorkspace{}), do: :device

  defp confirmation_required?(nil, _digest), do: true
  defp confirmation_required?(confirmation, digest), do: confirmation.boundary_digest != digest

  defp require_available(%{state: :available}), do: :ok
  defp require_available(%{state: state}), do: {:error, state}

  defp require_matching_confirmation(nil, _digest), do: {:error, :confirmation_required}
  defp require_matching_confirmation(%{boundary_digest: digest}, digest), do: :ok
  defp require_matching_confirmation(_confirmation, _digest), do: {:error, :confirmation_required}

  defp authorize_participation(%PersonalWorkspace{}, project_id, actor, action) do
    case Guard.authorize_action(project_id, actor, action) do
      {:ok, _member} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_participation(%DeviceWorkspace{id: authority_id}, project_id, _actor, action) do
    with true <- action in Guard.protected_actions(),
         {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device"}} <- Devices.get_project(project_id) do
      :ok
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp authorize_participation(_authority, _project_id, _actor, _action),
    do: {:error, :unauthorized}
end
