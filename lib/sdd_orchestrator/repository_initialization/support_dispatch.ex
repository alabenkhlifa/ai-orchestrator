defmodule SddOrchestrator.RepositoryInitialization.SupportDispatch do
  @moduledoc """
  Dispatches one read-only initialization-support turn (AC-02) through Task
  1's `InitializationDispatch` foundation.

  A turn always negotiates and requires the `plan_discovery` capability grant
  — never `staging_write` — so it structurally cannot reach the working-agent
  path `InitializationDispatch.authorize_grant/2` guards. Nothing here writes
  to the plan; the plan is only ever changed by the user's own answer through
  `SddOrchestrator.RepositoryInitialization.answer_field/3`.

  Pinning a runtime session (`capability:ai-runtime-session`) is account-scoped
  in this codebase: `AIRuntime.RuntimeSessions.pin_session/3` requires an
  active account and an already-linked personal AI connection for that
  account (`AIRuntime.PersonalConnections` has no implicit or funded fallback
  connection). Empty-repository initialization's entry, eligibility, and plan
  stay accountless, mirroring `SddOrchestratorWeb.LocalOnboardingLive` — so a
  turn is dispatched only when the caller supplies a signed-in account that
  has exactly one active personal AI connection; every other case returns
  `{:skip, reason}` and the caller falls back to its own static per-field
  question text. AC-03 does not require every turn to reach a model — it
  requires every question to stay visible, sequential, and explicitly
  answered, which the plan's own `current_field` cursor enforces regardless
  of whether a turn ran.
  """

  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections, RuntimeSessions}

  alias SddOrchestrator.Delivery.{
    AgentAdapter,
    InitializationDispatch,
    InitializationManifest,
    WorkerProtocol
  }

  alias SddOrchestrator.RepositoryInitialization.Plan

  @capability_grant "plan_discovery"
  @negotiated_grants [@capability_grant]

  @doc "The capability grant every support turn negotiates — never `staging_write`."
  @spec negotiated_grants() :: [String.t()]
  def negotiated_grants, do: @negotiated_grants

  @doc """
  Dispatches one turn for the plan's current field.

  Returns `{:ok, %{text: text_or_nil, dispatch_id: dispatch_id}}` on a
  successful dispatch (`text` is the assistant's normalized progress
  commentary when the configured adapter produced one, `nil` otherwise), or
  `{:skip, reason}` whenever a turn cannot be dispatched (no signed-in
  account, no eligible connection, or any pinning/dispatch refusal) — never
  an exception, and never a write to the plan.
  """
  @spec dispatch_turn(Plan.t(), term(), map()) ::
          {:ok, %{text: String.t() | nil, dispatch_id: String.t()}} | {:skip, atom()}
  def dispatch_turn(plan, account, latest_answer \\ %{})

  def dispatch_turn(%Plan{}, nil, _latest_answer), do: {:skip, :no_account}

  def dispatch_turn(%Plan{} = plan, account, latest_answer) do
    with {:ok, connection_id} <- eligible_connection(account),
         {:ok, model, effort} <- current_model_selection(account, connection_id),
         {:ok, session} <-
           RuntimeSessions.pin_session(account, pin_request(plan, connection_id, model, effort)),
         {:ok, result} <-
           InitializationDispatch.dispatch(
             manifest_attrs(plan, session, latest_answer),
             @negotiated_grants
           ) do
      {:ok, %{text: assistant_text(result.handle), dispatch_id: result.manifest.dispatch_id}}
    else
      {:error, reason} -> {:skip, reason}
    end
  end

  defp eligible_connection(account) do
    case account
         |> PersonalConnections.list_personal_connections()
         |> Enum.filter(&(&1.revocation_state == "active")) do
      [%{id: id}] -> {:ok, id}
      _zero_or_many -> {:error, :no_eligible_connection}
    end
  end

  defp current_model_selection(account, connection_id) do
    case ModelCatalogs.current_catalog(account, connection_id, now: DateTime.utc_now()) do
      {:ok, %{models: models}} -> select_current_model(models)
      {:error, reason} -> {:error, reason}
    end
  end

  defp select_current_model(models) do
    case Enum.find(models, & &1.current) || Enum.find(models, & &1.default) do
      %{model: model, default_reasoning_effort: effort} when is_binary(effort) ->
        {:ok, model, effort}

      _no_selectable_model ->
        {:error, :unknown}
    end
  end

  defp pin_request(plan, connection_id, model, effort) do
    %{
      consumer: :support_assistant,
      consumer_ref: "initialization_plan:" <> plan.id,
      connection_id: connection_id,
      model: model,
      effort: effort,
      scarcity: :standard,
      choices: [],
      spending_ceiling: nil
    }
  end

  defp manifest_attrs(plan, session, latest_answer) do
    %{
      "manifest_version" => InitializationManifest.manifest_version(),
      "device_workspace_id" => plan.device_workspace_id,
      "dispatch_id" => WorkerProtocol.generate_id(),
      "capability_grant" => @capability_grant,
      "agent_ref" => %{
        "provider_ref" => to_string(session.provider),
        "model_ref" => to_string(session.model)
      },
      "instructions" => %{
        "kind" => "plan_discovery_turn",
        "current_field" => plan.current_field,
        "answers" => answered_fields(plan),
        "latest_answer" => stringify(latest_answer)
      }
    }
  end

  defp answered_fields(plan) do
    %{}
    |> maybe_put("purpose", plan.purpose)
    |> maybe_put("users", plan.users)
    |> maybe_put("first_outcome", plan.first_outcome)
    |> maybe_put("constraints", plan.constraints)
    |> maybe_put("technical_foundation", plan.technical_foundation)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when value == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_map(value), do: value
  defp stringify(_value), do: ""

  defp assistant_text(handle) do
    module = AgentAdapter.adapter()

    case module.observe(handle) do
      {:ok, events} -> events |> Enum.find(&(&1["type"] == "progress")) |> extract_text()
      {:error, _reason} -> nil
    end
  rescue
    _error -> nil
  end

  defp extract_text(%{"payload" => %{"summary" => summary}}) when is_binary(summary), do: summary
  defp extract_text(_event), do: nil
end
