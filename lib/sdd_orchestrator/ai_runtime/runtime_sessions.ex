defmodule SddOrchestrator.AIRuntime.RuntimeSessions do
  @moduledoc """
  Account-scoped pinning boundary for provider-neutral runtime sessions.

  Support-assistant and working-agent consumers pass through one identical rule
  set: an explicitly selected eligible connection, a live-proven model and
  reasoning effort with its catalog provenance, the explicit owner opt-ins the
  quota policy required, and an API-key spending ceiling. Pinning is idempotent
  per consumer reference and immutable afterwards; a different configuration
  for the same consumer fails closed instead of changing active work.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    ModelCatalogs,
    PersonalAIConnection,
    PersonalConnections,
    QuotaPolicy
  }

  alias SddOrchestrator.Repo

  @request_keys ~w(consumer consumer_ref connection_id model effort scarcity choices
                   spending_ceiling)a
  @ceiling_keys ~w(amount currency)a
  @consumer_kinds [:support_assistant, :working_agent]
  @proceed_decisions [:proceed, :proceed_to_cost_reservation]

  @max_consumer_ref_bytes 255
  @ceiling_amount_format ~r/\A\d+(\.\d{1,4})?\z/

  @typedoc "Safe runtime-session boundary failures."
  @type error ::
          :account_unavailable
          | :invalid_request
          | :invalid_consumer
          | :connection_required
          | :not_found
          | :unavailable
          | :incompatible
          | :revoking
          | :revoked
          | :invalid_selection
          | :unknown
          | :stale
          | :unknown_compatibility
          | :spending_ceiling_required
          | :spending_ceiling_not_applicable
          | :configuration_conflict
          | :invalid_response
          | {:pause, atom()}

  @doc """
  Pins one immutable configuration for a support conversation or agent run.

  Re-pinning the same consumer reference with an identical configuration
  returns the existing session; any other configuration fails closed.
  """
  @spec pin_session(Account.t() | Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def pin_session(account_or_id, request, opts \\ []) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, request} <- normalize_request(request),
         {:ok, connection} <-
           PersonalConnections.resolve_for_consumer(
             account_id,
             request.connection_id,
             request.consumer
           ),
         :ok <- validate_ceiling_boundary(connection, request.spending_ceiling),
         {:ok, selection} <-
           ModelCatalogs.validate_selection(
             account_id,
             request.connection_id,
             request.model,
             request.effort,
             now: now
           ),
         {:ok, decision} <- evaluate_policy(account_id, request, now, opts),
         {:ok, opt_ins} <- pinned_opt_ins(request.choices, decision.choice_ids),
         {:ok, session} <- persist(account_id, request, connection, selection, opt_ins, now) do
      {:ok, projection(session)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns one pinned configuration inside its owning active-account scope."
  @spec get_session(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :account_unavailable | :not_found}
  def get_session(account_or_id, session_id) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         %AIRuntimeSession{} = session <- scoped_session(account_id, session_id) do
      {:ok, projection(session)}
    else
      {:error, :invalid_request} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  @doc "Returns the configuration pinned for one consumer reference."
  @spec fetch_for_consumer(
          Account.t() | Ecto.UUID.t(),
          :support_assistant | :working_agent | String.t(),
          String.t()
        ) ::
          {:ok, map()} | {:error, :account_unavailable | :invalid_consumer | :not_found}
  def fetch_for_consumer(account_or_id, consumer, consumer_ref) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, consumer} <- normalize_consumer(consumer),
         {:ok, consumer_ref} <- normalize_consumer_ref(consumer_ref),
         %AIRuntimeSession{} = session <- consumer_session(account_id, consumer, consumer_ref) do
      {:ok, projection(session)}
    else
      {:error, :invalid_consumer} -> {:error, :invalid_consumer}
      {:error, :account_unavailable} -> {:error, :account_unavailable}
      _other -> {:error, :not_found}
    end
  end

  @doc "Lists the independently pinned sessions currently reusing one connection."
  @spec list_for_connection(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def list_for_connection(account_or_id, connection_id) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, connection_id} <- cast_id(connection_id) do
      AIRuntimeSession
      |> where(
        [session],
        session.account_id == ^account_id and session.connection_id == ^connection_id
      )
      |> order_by([session], asc: session.pinned_at, asc: session.id)
      |> Repo.all()
      |> Enum.map(&projection/1)
    else
      _other -> []
    end
  end

  defp evaluate_policy(account_id, request, now, opts) do
    policy_request = Map.take(request, [:connection_id, :model, :effort, :scarcity, :choices])
    policy_opts = policy_opts(opts, now)

    case QuotaPolicy.evaluate(account_id, policy_request, policy_opts) do
      {:ok, %{decision: decision} = result} when decision in @proceed_decisions ->
        {:ok, result}

      {:ok, %{decision: :pause, reason: reason}} ->
        {:error, {:pause, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp policy_opts(opts, now) do
    case Keyword.fetch(opts, :policy_adapter) do
      {:ok, adapter} -> [now: now, adapter: adapter]
      :error -> [now: now]
    end
    |> Keyword.merge(Keyword.take(opts, [:adapter_result, :notify]))
  end

  defp pinned_opt_ins(choices, choice_ids) do
    references =
      Enum.map(choice_ids, fn id ->
        Enum.find(choices, fn choice -> is_map(choice) and value(choice, :id) == id end)
      end)

    if Enum.any?(references, &is_nil/1) do
      {:error, :invalid_response}
    else
      references
      |> Enum.map(&opt_in_reference/1)
      |> AIRuntimeSession.validate_opt_ins()
      |> case do
        {:ok, opt_ins} -> {:ok, opt_ins}
        {:error, _reason} -> {:error, :invalid_request}
      end
    end
  end

  defp opt_in_reference(choice) do
    %{
      id: value(choice, :id),
      kind: value(choice, :kind),
      bucket_id: value(choice, :bucket_id),
      cost_boundary: value(choice, :cost_boundary),
      valid_from: value(choice, :valid_from),
      expires_at: value(choice, :expires_at)
    }
  end

  defp persist(account_id, request, connection, selection, opt_ins, now) do
    requested = requested_configuration(request, connection, opt_ins)
    attrs = attrs(account_id, request, connection, selection, opt_ins, now)

    Repo.transaction(fn ->
      active_account(account_id, lock: true) || Repo.rollback(:account_unavailable)
      locked_connection(account_id, request.connection_id) || Repo.rollback(:not_found)

      case PersonalConnections.resolve_for_consumer(
             account_id,
             request.connection_id,
             request.consumer
           ) do
        {:ok, _reference} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      case consumer_session(account_id, request.consumer, request.consumer_ref, lock: true) do
        nil -> insert_session(attrs, account_id, request, requested)
        existing -> reuse_session(existing, requested)
      end
    end)
    |> unwrap_transaction()
  end

  defp insert_session(attrs, account_id, request, requested) do
    case %AIRuntimeSession{}
         |> AIRuntimeSession.create_changeset(attrs)
         |> Repo.insert() do
      {:ok, session} ->
        session

      {:error, changeset} ->
        resolve_insert_conflict(changeset, account_id, request, requested)
    end
  end

  defp resolve_insert_conflict(changeset, account_id, request, requested) do
    if Keyword.has_key?(changeset.errors, :consumer_ref) do
      case consumer_session(account_id, request.consumer, request.consumer_ref) do
        nil -> Repo.rollback(:invalid_request)
        existing -> reuse_session(existing, requested)
      end
    else
      Repo.rollback(:invalid_request)
    end
  end

  defp reuse_session(existing, requested) do
    if same_configuration?(pinned_configuration(existing), requested),
      do: existing,
      else: Repo.rollback(:configuration_conflict)
  end

  defp attrs(account_id, request, connection, selection, opt_ins, now) do
    %{
      account_id: account_id,
      connection_id: request.connection_id,
      consumer_kind: Atom.to_string(request.consumer),
      consumer_ref: request.consumer_ref,
      provider: connection.provider,
      authentication_mode: connection.authentication_mode,
      model: selection.model,
      reasoning_effort: selection.effort,
      configuration_version: AIRuntimeSession.configuration_version(),
      catalog_snapshot_ref: selection.snapshot_id,
      catalog_source: selection.provenance.source,
      catalog_source_method: selection.provenance.method,
      catalog_source_version: selection.provenance.version,
      catalog_retrieved_at: selection.provenance.retrieved_at,
      catalog_expires_at: selection.expires_at,
      opt_ins: %{"items" => opt_ins},
      spending_ceiling_amount: ceiling_field(request.spending_ceiling, :amount),
      spending_ceiling_currency: ceiling_field(request.spending_ceiling, :currency),
      pinned_at: now
    }
  end

  defp requested_configuration(request, connection, opt_ins) do
    %{
      connection_id: request.connection_id,
      consumer_kind: Atom.to_string(request.consumer),
      consumer_ref: request.consumer_ref,
      provider: connection.provider,
      authentication_mode: connection.authentication_mode,
      model: request.model,
      reasoning_effort: request.effort,
      configuration_version: AIRuntimeSession.configuration_version(),
      opt_ins: opt_ins,
      spending_ceiling: request.spending_ceiling
    }
  end

  defp pinned_configuration(%AIRuntimeSession{} = session) do
    %{
      connection_id: session.connection_id,
      consumer_kind: session.consumer_kind,
      consumer_ref: session.consumer_ref,
      provider: session.provider,
      authentication_mode: session.authentication_mode,
      model: session.model,
      reasoning_effort: session.reasoning_effort,
      configuration_version: session.configuration_version,
      opt_ins: AIRuntimeSession.decode_opt_ins(session.opt_ins),
      spending_ceiling: ceiling(session)
    }
  end

  defp same_configuration?(pinned, requested) do
    Map.delete(pinned, :spending_ceiling) == Map.delete(requested, :spending_ceiling) and
      same_ceiling?(pinned.spending_ceiling, requested.spending_ceiling)
  end

  defp same_ceiling?(nil, nil), do: true

  defp same_ceiling?(%{amount: pinned, currency: currency}, %{
         amount: requested,
         currency: currency
       }),
       do: Decimal.compare(pinned, requested) == :eq

  defp same_ceiling?(_pinned, _requested), do: false

  defp projection(%AIRuntimeSession{} = session) do
    %{
      session_id: session.id,
      connection_id: session.connection_id,
      consumer: consumer_kind(session.consumer_kind),
      consumer_ref: session.consumer_ref,
      provider: session.provider,
      authentication_mode: session.authentication_mode,
      model: session.model,
      effort: session.reasoning_effort,
      configuration_version: session.configuration_version,
      provenance: %{
        snapshot_id: session.catalog_snapshot_ref,
        source: session.catalog_source,
        method: session.catalog_source_method,
        version: session.catalog_source_version,
        retrieved_at: session.catalog_retrieved_at,
        expires_at: session.catalog_expires_at
      },
      opt_ins: AIRuntimeSession.decode_opt_ins(session.opt_ins),
      spending_ceiling: ceiling(session),
      pinned_at: session.pinned_at
    }
  end

  defp ceiling(%AIRuntimeSession{spending_ceiling_amount: nil}), do: nil

  defp ceiling(%AIRuntimeSession{} = session),
    do: %{amount: session.spending_ceiling_amount, currency: session.spending_ceiling_currency}

  defp ceiling_field(nil, _key), do: nil
  defp ceiling_field(ceiling, key), do: Map.fetch!(ceiling, key)

  defp normalize_request(request) when is_map(request) do
    with {:ok, request} <- exact_map(request, @request_keys),
         {:ok, consumer} <- normalize_consumer(request.consumer),
         {:ok, consumer_ref} <- normalize_consumer_ref(request.consumer_ref),
         {:ok, connection_id} <- normalize_connection_id(request.connection_id),
         {:ok, spending_ceiling} <- normalize_ceiling(request.spending_ceiling),
         true <- is_list(request.choices) do
      {:ok,
       %{
         consumer: consumer,
         consumer_ref: consumer_ref,
         connection_id: connection_id,
         model: request.model,
         effort: request.effort,
         scarcity: request.scarcity,
         choices: request.choices,
         spending_ceiling: spending_ceiling
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_request(_request), do: {:error, :invalid_request}

  defp normalize_consumer(consumer) when consumer in @consumer_kinds, do: {:ok, consumer}
  defp normalize_consumer("support_assistant"), do: {:ok, :support_assistant}
  defp normalize_consumer("working_agent"), do: {:ok, :working_agent}
  defp normalize_consumer(_consumer), do: {:error, :invalid_consumer}

  defp normalize_consumer_ref(consumer_ref) when is_binary(consumer_ref) do
    if consumer_ref == String.trim(consumer_ref) and
         byte_size(consumer_ref) in 1..@max_consumer_ref_bytes and
         not forbidden_content?(consumer_ref),
       do: {:ok, consumer_ref},
       else: {:error, :invalid_request}
  end

  defp normalize_consumer_ref(_consumer_ref), do: {:error, :invalid_request}

  defp normalize_connection_id(nil), do: {:error, :connection_required}
  defp normalize_connection_id(connection_id), do: cast_id(connection_id)

  defp normalize_ceiling(nil), do: {:ok, nil}

  defp normalize_ceiling(ceiling) when is_map(ceiling) do
    with {:ok, ceiling} <- exact_map(ceiling, @ceiling_keys),
         {:ok, amount} <- normalize_amount(ceiling.amount),
         {:ok, currency} <- normalize_currency(ceiling.currency) do
      {:ok, %{amount: amount, currency: currency}}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_ceiling(_ceiling), do: {:error, :invalid_request}

  defp normalize_amount(%Decimal{} = amount), do: bounded_amount(amount)

  defp normalize_amount(amount) when is_integer(amount), do: bounded_amount(Decimal.new(amount))

  defp normalize_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {%Decimal{} = parsed, ""} -> bounded_amount(parsed)
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_amount(_amount), do: {:error, :invalid_request}

  defp bounded_amount(%Decimal{} = amount) do
    with true <- Regex.match?(@ceiling_amount_format, Decimal.to_string(amount)),
         :gt <- Decimal.compare(amount, 0),
         true <- Decimal.compare(amount, AIRuntimeSession.max_ceiling_amount()) != :gt do
      {:ok, amount}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_currency(currency) when is_binary(currency) do
    if Regex.match?(~r/\A[A-Z]{3}\z/, currency),
      do: {:ok, currency},
      else: {:error, :invalid_request}
  end

  defp normalize_currency(_currency), do: {:error, :invalid_request}

  defp validate_ceiling_boundary(%{authentication_mode: "api_key"}, nil),
    do: {:error, :spending_ceiling_required}

  defp validate_ceiling_boundary(%{authentication_mode: "api_key"}, _ceiling), do: :ok
  defp validate_ceiling_boundary(_connection, nil), do: :ok

  defp validate_ceiling_boundary(_connection, _ceiling),
    do: {:error, :spending_ceiling_not_applicable}

  defp forbidden_content?(value) do
    downcased = String.downcase(value)

    Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, value) or
      Regex.match?(~r/\bsk-[a-z0-9_-]{8,}\b/i, value) or
      String.contains?(downcased, "bearer ") or
      String.contains?(downcased, "api_key=") or
      String.contains?(downcased, "access_token=")
  end

  defp consumer_kind("support_assistant"), do: :support_assistant
  defp consumer_kind("working_agent"), do: :working_agent

  defp consumer_session(account_id, consumer, consumer_ref, opts \\ []) do
    consumer_kind = Atom.to_string(consumer)

    query =
      from session in AIRuntimeSession,
        where:
          session.account_id == ^account_id and session.consumer_kind == ^consumer_kind and
            session.consumer_ref == ^consumer_ref

    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp scoped_session(account_id, session_id) do
    Repo.one(
      from session in AIRuntimeSession,
        where: session.account_id == ^account_id and session.id == ^session_id
    )
  end

  defp locked_connection(account_id, connection_id) do
    Repo.one(
      from connection in PersonalAIConnection,
        where: connection.account_id == ^account_id and connection.id == ^connection_id,
        lock: "FOR UPDATE"
    )
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

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, item} -> item
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp exact_map(map, keys) do
    string_keys = Enum.map(keys, &Atom.to_string/1)

    cond do
      Enum.sort(Map.keys(map)) == Enum.sort(keys) ->
        {:ok, Map.take(map, keys)}

      Enum.sort(Map.keys(map)) == Enum.sort(string_keys) ->
        {:ok, Map.new(keys, fn key -> {key, Map.fetch!(map, Atom.to_string(key))} end)}

      true ->
        {:error, :invalid_request}
    end
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
