defmodule SddOrchestrator.ProjectAssistant.RuntimeAvailability do
  @moduledoc """
  Normalizes the acting participant's personal AI connection and shared
  runtime availability for the project assistant into the
  `:available | :setup_needed | :unavailable | :temporarily_limited` state
  space AC-04 and AC-22 need, without ever exposing a credential, exact
  account-wide quota, or provider diagnostic.

  Mirrors `SddOrchestrator.RepositoryInitialization.SupportDispatch`'s
  eligibility-then-pin flow for the identical `consumer: :support_assistant`
  kind, generalized so any project-assistant consumer reference can resolve
  its own session rather than one shared per-account reference.

  This module deliberately never calls `SddOrchestrator.AIRuntime.RuntimeProjections`:

    * `owner_projection/3` would technically work (each participant pins
      their own session under their own account and so owns it), but it
      returns the account's exact quota, credits, spend, and connection
      reference — fields the assistant panel must never receive at all, not
      merely never display.
    * `participant_projection/4` is deliberately scoped to `working_agent`
      project runs; it refuses a `support_assistant` session outright (see
      `specs/11-ai-runtime-governance` Task 5's own delivery note), which is
      exactly the consumer kind this module pins.

  Every state below is built only from typed, already-safe atoms and fields
  `SddOrchestrator.AIRuntime.PersonalConnections` and
  `SddOrchestrator.AIRuntime.RuntimeSessions` already return.
  """

  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections, RuntimeSessions}

  @consumer :support_assistant

  @type state :: :available | :setup_needed | :unavailable | :temporarily_limited

  @doc """
  Resolves runtime availability for one project-assistant consumer
  reference, pinning (or idempotently reusing) the `support_assistant`
  session when a turn may proceed.

  `account` is the acting participant's own hosted account — the same
  account personal AI connections and the project participation identity
  already share for a hosted project. `nil` (no signed-in account, the
  accountless device-authority path) resolves to `:setup_needed` without
  touching the runtime, exactly like `SupportDispatch` skips a turn rather
  than substituting a fallback.
  """
  @spec resolve(term(), String.t(), keyword()) :: {:ok, map()}
  def resolve(account, consumer_ref, opts \\ [])

  def resolve(nil, _consumer_ref, _opts) do
    {:ok, %{state: :setup_needed, reason: :no_account, provider: nil, authentication_mode: nil}}
  end

  def resolve(account, consumer_ref, opts) when is_binary(consumer_ref) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case eligible_connection(account) do
      {:error, :no_eligible_connection} ->
        {:ok,
         %{
           state: :setup_needed,
           reason: :no_eligible_connection,
           provider: nil,
           authentication_mode: nil
         }}

      {:error, reason, known} ->
        {:ok,
         %{
           state: :unavailable,
           reason: safe_reason(reason),
           provider: known.provider,
           authentication_mode: known.authentication_mode
         }}

      {:ok, connection} ->
        pin_or_normalize(account, consumer_ref, connection, now)
    end
  end

  @doc "The consumer kind every project-assistant session pins under."
  @spec consumer() :: :support_assistant
  def consumer, do: @consumer

  defp pin_or_normalize(account, consumer_ref, connection, now) do
    with {:ok, model, effort} <- current_model_selection(account, connection.connection_id, now),
         {:ok, session} <-
           RuntimeSessions.pin_session(
             account,
             pin_request(consumer_ref, connection.connection_id, model, effort),
             now: now
           ) do
      {:ok,
       %{
         state: :available,
         provider: session.provider,
         authentication_mode: session.authentication_mode,
         model: session.model,
         effort: session.effort,
         session_id: session.session_id,
         pinned_at: session.pinned_at
       }}
    else
      {:error, {:pause, reason}} ->
        {:ok,
         %{
           state: :temporarily_limited,
           reason: safe_reason(reason),
           provider: connection.provider,
           authentication_mode: connection.authentication_mode
         }}

      {:error, reason} ->
        {:ok,
         %{
           state: :unavailable,
           reason: safe_reason(reason),
           provider: connection.provider,
           authentication_mode: connection.authentication_mode
         }}
    end
  end

  # The provider and authentication mode are read straight off the listed
  # connection so an ineligible-but-known connection (incompatible, revoking,
  # revoked) can still report what it is, not just that it failed.
  # `resolve_support_connection/2` remains the sole eligibility authority;
  # this never substitutes its own eligibility judgment.
  defp eligible_connection(account) do
    case PersonalConnections.list_personal_connections(account) do
      [connection] ->
        case PersonalConnections.resolve_support_connection(account, connection.id) do
          {:ok, reference} ->
            {:ok, reference}

          {:error, reason} ->
            {:error, reason,
             %{provider: connection.provider, authentication_mode: connection.authentication_mode}}
        end

      _zero_or_many ->
        {:error, :no_eligible_connection}
    end
  end

  defp current_model_selection(account, connection_id, now) do
    case ModelCatalogs.current_catalog(account, connection_id, now: now) do
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

  defp pin_request(consumer_ref, connection_id, model, effort) do
    %{
      consumer: @consumer,
      consumer_ref: consumer_ref,
      connection_id: connection_id,
      model: model,
      effort: effort,
      scarcity: :standard,
      choices: [],
      spending_ceiling: nil
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :unknown
end
