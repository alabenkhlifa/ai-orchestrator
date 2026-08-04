defmodule SddOrchestrator.AIRuntime.RuntimeObservations do
  @moduledoc """
  Ordered append boundary for one runtime session's minimized observations.

  Support-assistant and working-agent sessions pass through one identical rule
  set. An observation belongs to exactly one pinned configuration, carries the
  monotonic sequence and observation time its source assigned, and is appended
  under the session row lock so history is written in order.

  Ingestion is idempotent by event key and never silently reorders history. A
  repeated event replays the stored row instead of appending a second one, the
  same key carrying different facts is refused as a conflicting reuse, and an
  event that is already superseded by a later sequence or observation time is
  refused as stale. The database enforces both invariants independently of this
  module through the unique `(session_id, sequence)` and `(session_id,
  event_key)` indexes.

  Only minimized values are persisted: elapsed time, token counters when
  available, an estimated cost and its calculation basis when calculable, the
  applicable quota bucket references, the status, the source label each of
  those carries, and the observation time. Provenance is validated and dropped,
  because the session already owns the provider it was pinned to.

  This module publishes ordered observations to their owning active account. It
  does not decide where or how an operator sees them, and it does not implement
  the owner-exact and participant-safe boundary; the consuming interface and
  the participation boundary own that.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    ObservationAdapter,
    PersonalAIConnection
  }

  alias SddOrchestrator.AIRuntime.ObservationAdapter.RPC
  alias SddOrchestrator.Repo

  @default_limit 100
  @max_limit 500
  @max_clock_skew_seconds 60

  @typedoc "Safe observation-boundary failures."
  @type error ::
          :account_unavailable
          | :invalid_request
          | :not_found
          | :stale_observation
          | :duplicate_event
          | ObservationAdapter.error()

  @doc """
  Ingests one observation for a pinned session and appends it in order.

  The adapter is contacted outside the transaction; the account, the session,
  and the ordering state are then re-authorized and re-read under lock before
  anything is written.
  """
  @spec ingest(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def ingest(account_or_id, session_id, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, RPC)

    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, context} <- prepare(account_id, session_id),
         {:ok, raw} <- call_adapter(adapter, context, opts),
         {:ok, result} <- ObservationAdapter.validate_result(raw, context.session.provider),
         false <- contains_value?(result, context.connection.worker_profile_ref),
         :ok <- validate_observed_at(result.observed_at, context.session, now),
         :ok <- validate_estimate_binding(result, context.session),
         {:ok, observation} <- append(account_id, session_id, result) do
      {:ok, projection(observation)}
    else
      true -> {:error, :invalid_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns one session's observations in append order, oldest first.

  The list is the stored ordered history of the owning active account. Which
  values a particular audience may see is not decided here.
  """
  @spec list_observations(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, [map()]} | {:error, :account_unavailable | :invalid_request | :not_found}
  def list_observations(account_or_id, session_id, opts \\ []) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, page_size} <- page_size(opts),
         %AIRuntimeSession{} <- scoped_session(account_id, session_id) do
      observations =
        AgentRuntimeObservation
        |> where(
          [observation],
          observation.account_id == ^account_id and observation.session_id == ^session_id
        )
        |> order_by([observation], asc: observation.sequence)
        |> limit(^page_size)
        |> Repo.all()
        |> Enum.map(&projection/1)

      {:ok, observations}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  @doc "Returns the most recently appended observation of one session."
  @spec latest_observation(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :account_unavailable | :invalid_request | :not_found}
  def latest_observation(account_or_id, session_id) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         %AIRuntimeSession{} <- scoped_session(account_id, session_id),
         %AgentRuntimeObservation{} = observation <- latest(session_id) do
      {:ok, projection(observation)}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  # A session whose connection reference is already detached keeps its stored
  # history and can still be read, but there is no worker binding left to
  # observe through.
  defp prepare(account_id, session_id) do
    with %Account{} = account <- active_account(account_id),
         %AIRuntimeSession{connection_id: connection_id} = session
         when is_binary(connection_id) <- scoped_session(account_id, session_id),
         %PersonalAIConnection{} = connection <- connection(account_id, connection_id) do
      {:ok, %{account: account, session: session, connection: connection}}
    else
      _other -> {:error, :not_found}
    end
  end

  defp call_adapter(adapter, context, opts) do
    adapter_opts =
      opts
      |> Keyword.drop([:adapter, :now])
      |> Keyword.put(:consumer, consumer(context.session.consumer_kind))
      |> Keyword.put(:consumer_ref, context.session.consumer_ref)

    case adapter.observe(context.account, context.connection, adapter_opts) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, reason} -> {:error, ObservationAdapter.normalize_error(reason)}
      _other -> {:error, :invalid_response}
    end
  rescue
    _exception -> {:error, :invalid_response}
  end

  defp append(account_id, session_id, result) do
    attrs =
      result
      |> AgentRuntimeObservation.to_attrs()
      |> Map.merge(%{account_id: account_id, session_id: session_id})

    Repo.transaction(fn ->
      active_account(account_id, lock: true) || Repo.rollback(:account_unavailable)
      locked_session(account_id, session_id) || Repo.rollback(:not_found)

      case recorded_event(session_id, result.event_key) do
        %AgentRuntimeObservation{} = existing -> replay(existing, result)
        nil -> insert(attrs, session_id, result)
      end
    end)
    |> unwrap_transaction()
  end

  # A repeated event is the same event only when it carries the same facts.
  defp replay(existing, result) do
    stored = comparable(AgentRuntimeObservation.payload(existing))

    if stored == comparable(result),
      do: existing,
      else: Repo.rollback(:duplicate_event)
  end

  defp comparable(result) do
    result
    |> Map.take([
      :event_key,
      :sequence,
      :observed_at,
      :elapsed,
      :tokens,
      :estimated_cost,
      :quota,
      :status,
      :unknown_fields
    ])
    |> Map.update!(:estimated_cost, &comparable_cost/1)
  end

  # The stored amount comes back at the column's scale, so an equality check
  # has to compare the numbers rather than their representation.
  defp comparable_cost(%{amount: %Decimal{} = amount} = cost),
    do: %{cost | amount: Decimal.normalize(amount)}

  defp comparable_cost(cost), do: cost

  defp insert(attrs, session_id, result) do
    case ordering(session_id, result) do
      :ok ->
        %AgentRuntimeObservation{}
        |> AgentRuntimeObservation.create_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, observation} -> observation
          {:error, changeset} -> Repo.rollback(insert_error(changeset))
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp ordering(session_id, result) do
    case latest(session_id, lock: true) do
      nil ->
        :ok

      %AgentRuntimeObservation{} = latest ->
        if result.sequence > latest.sequence and
             DateTime.compare(result.observed_at, latest.observed_at) != :lt,
           do: :ok,
           else: {:error, :stale_observation}
    end
  end

  defp insert_error(changeset) do
    cond do
      Keyword.has_key?(changeset.errors, :sequence) -> :stale_observation
      Keyword.has_key?(changeset.errors, :event_key) -> :duplicate_event
      true -> :invalid_response
    end
  end

  # An observation cannot predate the configuration it observes, and a source
  # clock ahead of this one is refused instead of being written as the future.
  defp validate_observed_at(observed_at, session, now) do
    horizon = DateTime.add(now, @max_clock_skew_seconds, :second)

    if DateTime.compare(observed_at, session.pinned_at) != :lt and
         DateTime.compare(observed_at, horizon) != :gt,
       do: :ok,
       else: {:error, :invalid_response}
  end

  # An estimate calculated for a different model is not this session's estimate.
  defp validate_estimate_binding(%{estimated_cost: %{basis: nil}}, _session), do: :ok

  defp validate_estimate_binding(%{estimated_cost: %{basis: basis}}, session) do
    if basis.model == session.model, do: :ok, else: {:error, :invalid_response}
  end

  defp projection(%AgentRuntimeObservation{} = observation) do
    payload = AgentRuntimeObservation.payload(observation)

    %{
      observation_id: observation.id,
      session_id: observation.session_id,
      sequence: payload.sequence,
      event_key: payload.event_key,
      observed_at: payload.observed_at,
      elapsed: %{seconds: payload.elapsed.seconds, source: label(payload.elapsed.source)},
      tokens: %{
        input: payload.tokens.input,
        output: payload.tokens.output,
        total: payload.tokens.total,
        source: label(payload.tokens.source)
      },
      estimated_cost: %{
        amount: payload.estimated_cost.amount,
        currency: payload.estimated_cost.currency,
        basis: payload.estimated_cost.basis,
        source: label(payload.estimated_cost.source)
      },
      quota: %{buckets: payload.quota.buckets, source: label(payload.quota.source)},
      status: %{
        state: state(payload.status.state),
        pause_reason: pause_reason(payload.status.pause_reason),
        source: label(payload.status.source)
      },
      unknown_fields: payload.unknown_fields
    }
  end

  defp label("provider_fact"), do: :provider_fact
  defp label("worker_observed"), do: :worker_observed
  defp label("local_estimate"), do: :local_estimate
  defp label("unknown"), do: :unknown

  defp state("available"), do: :available
  defp state("constrained"), do: :constrained
  defp state("paused"), do: :paused
  defp state("unknown"), do: :unknown

  defp pause_reason(nil), do: nil
  defp pause_reason("quota_exhausted"), do: :quota_exhausted
  defp pause_reason("spending_ceiling_reached"), do: :spending_ceiling_reached

  defp consumer("support_assistant"), do: :support_assistant
  defp consumer("working_agent"), do: :working_agent

  defp recorded_event(session_id, event_key) do
    Repo.one(
      from observation in AgentRuntimeObservation,
        where: observation.session_id == ^session_id and observation.event_key == ^event_key
    )
  end

  defp latest(session_id, opts \\ []) do
    query =
      from observation in AgentRuntimeObservation,
        where: observation.session_id == ^session_id,
        order_by: [desc: observation.sequence],
        limit: 1

    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp scoped_session(account_id, session_id) do
    Repo.one(
      from session in AIRuntimeSession,
        where: session.account_id == ^account_id and session.id == ^session_id
    )
  end

  defp locked_session(account_id, session_id) do
    Repo.one(
      from session in AIRuntimeSession,
        where: session.account_id == ^account_id and session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  defp connection(account_id, connection_id) do
    PersonalAIConnection
    |> where(
      [connection],
      connection.account_id == ^account_id and connection.id == ^connection_id
    )
    |> Repo.one()
    |> case do
      %PersonalAIConnection{} = connection -> Repo.preload(connection, :worker)
      nil -> nil
    end
  end

  defp active_account(account_id, opts \\ []) do
    query = from account in Account, where: account.id == ^account_id and account.state == :active
    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp scoped_account_id(account_or_id) do
    with {:ok, account_id} <- account_id(account_or_id),
         %Account{} <- active_account(account_id) do
      {:ok, account_id}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :account_unavailable}
    end
  end

  defp account_id(%Account{id: id}), do: cast_id(id)
  defp account_id(id), do: cast_id(id)

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_request}
    end
  end

  defp cast_id(_id), do: {:error, :invalid_request}

  defp normalized_now(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp page_size(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      size when is_integer(size) and size in 1..@max_limit -> {:ok, size}
      _other -> {:error, :invalid_request}
    end
  end

  defp contains_value?(_value, nil), do: false

  defp contains_value?(value, needle) when is_binary(value), do: String.contains?(value, needle)

  defp contains_value?(value, needle) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, needle))

  defp contains_value?(%Decimal{}, _needle), do: false
  defp contains_value?(%DateTime{}, _needle), do: false

  defp contains_value?(value, needle) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_value?(to_string(key), needle) or contains_value?(item, needle)
    end)
  end

  defp contains_value?(_value, _needle), do: false

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
