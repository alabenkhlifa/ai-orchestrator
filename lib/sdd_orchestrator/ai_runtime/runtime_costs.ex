defmodule SddOrchestrator.AIRuntime.RuntimeCosts do
  @moduledoc """
  Strict non-exceeding spending-ceiling boundary for personal API-key runs.

  A personal API-key session's ceiling is a runtime boundary, not an after the
  fact accounting total. Before every chargeable turn this boundary loads a
  current versioned official-price snapshot, calculates the conservative maximum
  cost of the pinned model under the approved bounded request configuration, and
  atomically reserves it inside the remaining ceiling. Missing or stale pricing
  refuses the turn instead of treating the model as free, and a turn whose
  conservative maximum cannot fit pauses the run before launch.

  Every mutation re-authorizes the owning active account and the pinned session,
  re-reads the ceiling row under `FOR UPDATE`, and is refused by a database check
  constraint if it would ever push the reservation plus the reconciled cost past
  the ceiling. Because the ceiling is enforced against the bounded worst case,
  work can pause before the nominal ceiling is reached.

  ChatGPT-authenticated sessions carry no ceiling and are refused as
  `:not_applicable`. The ledger holds no provider invoice, payment credential,
  provider account identity, or raw provider error.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.AIRuntime.RuntimeCostLedger
  alias SddOrchestrator.AIRuntime.RuntimeCosts.PriceSnapshot
  alias SddOrchestrator.Repo

  @open_keys ~w(max_input_tokens max_output_tokens)a
  @reserve_keys ~w(idempotency_key max_input_tokens max_output_tokens)a

  @default_abandoned_after_seconds 900
  @max_abandoned_after_seconds 86_400
  @unit_price_scale 8

  @typedoc "Safe cost-boundary failures."
  @type error ::
          :account_unavailable
          | :invalid_request
          | :not_found
          | :not_applicable
          | :configuration_conflict
          | :missing_price
          | :stale_price
          | :duplicate_reservation
          | :unknown_reservation
          | :over_reconciliation
          | :capacity_conflict

  @typedoc "The resumable pause a run reports instead of exceeding its ceiling."
  @type pause :: {:pause, :insufficient_capacity}

  @doc """
  Opens the strict ceiling state for one pinned API-key session.

  The bounded request configuration is the approved worst case every later
  reservation is calculated from, so re-opening with a different configuration
  fails closed instead of widening an active boundary.
  """
  @spec open_ledger(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def open_ledger(account_or_id, session_id, request, opts \\ []) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, request} <- normalize_open_request(request) do
      transaction(fn ->
        with {:ok, session} <- authorize(account_id, session_id),
             {:ok, ceiling} <- session_ceiling(session) do
          open(account_id, session, ceiling, request, now, opts)
        end
      end)
      |> project()
    end
  end

  @doc """
  Atomically reserves the conservative maximum cost of the next bounded turn.

  Returns `{:pause, :insufficient_capacity}` without allocating anything when
  the remaining ceiling cannot cover the reservation, replays an outstanding
  idempotency key instead of allocating twice, and fails closed on a missing or
  stale price, a reused key with a different bounded configuration, and any
  concurrent over-allocation the database refuses.
  """
  @spec reserve(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, map()} | pause() | {:error, error()}
  def reserve(account_or_id, session_id, request, opts \\ []) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, request} <- normalize_reserve_request(request) do
      transaction(fn ->
        with {:ok, session} <- authorize(account_id, session_id),
             {:ok, ledger} <- locked_ledger(session_id),
             :ok <- within_bounds(ledger, request) do
          reserve_turn(ledger, session, request, now, opts)
        end
      end)
      |> project_reservation(request.idempotency_key)
    end
  end

  @doc """
  Reconciles one outstanding reservation against the observed cost of its turn.

  The reservation is released and the observed cost is recorded in one atomic
  step. An observed cost above its own reservation is refused, because the
  reservation is the only amount the ceiling ever authorized.
  """
  @spec reconcile(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), String.t(), term()) ::
          {:ok, map()} | {:error, error()}
  def reconcile(account_or_id, session_id, idempotency_key, observed) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, idempotency_key} <- RuntimeCostLedger.validate_idempotency_key(idempotency_key),
         {:ok, observed} <- normalize_amount(observed) do
      transaction(fn ->
        with {:ok, _session} <- authorize(account_id, session_id),
             {:ok, ledger} <- locked_ledger(session_id) do
          settle(ledger, idempotency_key, observed)
        end
      end)
      |> project()
    end
  end

  @doc "Releases one unused reservation back into the remaining ceiling."
  @spec release(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, map()} | {:error, error()}
  def release(account_or_id, session_id, idempotency_key) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, idempotency_key} <- RuntimeCostLedger.validate_idempotency_key(idempotency_key) do
      transaction(fn ->
        with {:ok, _session} <- authorize(account_id, session_id),
             {:ok, ledger} <- locked_ledger(session_id) do
          settle(ledger, idempotency_key, nil)
        end
      end)
      |> project()
    end
  end

  @doc """
  Releases reservations whose turn never reported a result.

  An abandoned reservation is returned to the remaining ceiling and is never
  charged, because no observed usage was ever proven for it.
  """
  @spec recover_abandoned(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{released: [String.t()], ledger: map()}} | {:error, error()}
  def recover_abandoned(account_or_id, session_id, opts \\ []) do
    with {:ok, account_id} <- account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, seconds} <- abandoned_after_seconds(opts) do
      transaction(fn ->
        with {:ok, _session} <- authorize(account_id, session_id),
             {:ok, ledger} <- locked_ledger(session_id) do
          recover(ledger, DateTime.add(now, -seconds, :second))
        end
      end)
      |> case do
        {:ok, {released, ledger}} -> {:ok, %{released: released, ledger: projection(ledger)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Returns one session's minimized ceiling state inside its owning account."
  @spec get_ledger(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :account_unavailable | :not_found}
  def get_ledger(account_or_id, session_id) do
    with {:ok, account_id} <- scoped_account_id(account_or_id),
         {:ok, session_id} <- cast_id(session_id),
         %RuntimeCostLedger{} = ledger <- scoped_ledger(account_id, session_id) do
      {:ok, projection(ledger)}
    else
      {:error, :invalid_request} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  @doc "Reports the remaining approved capacity of one session's ceiling."
  @spec remaining_capacity(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{amount: Decimal.t(), currency: String.t()}}
          | {:error, :account_unavailable | :not_found}
  def remaining_capacity(account_or_id, session_id) do
    case get_ledger(account_or_id, session_id) do
      {:ok, ledger} -> {:ok, %{amount: ledger.remaining, currency: ledger.currency}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open(account_id, session, ceiling, request, now, opts) do
    case locked_ledger(session.id) do
      {:ok, ledger} -> reuse(ledger, request)
      {:error, :not_found} -> insert(account_id, session, ceiling, request, now, opts)
    end
  end

  defp reuse(ledger, request) do
    if ledger.max_input_tokens == request.max_input_tokens and
         ledger.max_output_tokens == request.max_output_tokens,
       do: {:ok, ledger},
       else: {:error, :configuration_conflict}
  end

  defp insert(account_id, session, ceiling, request, now, opts) do
    with {:ok, price} <- resolve_price(session, ceiling.currency, now, opts) do
      attrs =
        price
        |> price_attrs()
        |> Map.merge(%{
          account_id: account_id,
          session_id: session.id,
          currency: ceiling.currency,
          ceiling: Decimal.round(ceiling.amount, scale()),
          max_input_tokens: request.max_input_tokens,
          max_output_tokens: request.max_output_tokens,
          reserved_amount: zero(),
          observed_amount: zero(),
          outstanding_reservations: %{},
          paused: false,
          pause_reason: nil,
          paused_at: nil
        })

      %RuntimeCostLedger{}
      |> RuntimeCostLedger.create_changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, ledger} -> {:ok, ledger}
        {:error, _changeset} -> {:error, :invalid_request}
      end
    end
  end

  defp reserve_turn(ledger, session, request, now, opts) do
    reservations = RuntimeCostLedger.decode_reservations(ledger.outstanding_reservations)

    case Enum.find(reservations, &(&1.idempotency_key == request.idempotency_key)) do
      nil -> allocate(ledger, session, reservations, request, now, opts)
      existing -> replay(ledger, existing, request)
    end
  end

  defp replay(ledger, existing, request) do
    if existing.max_input_tokens == request.max_input_tokens and
         existing.max_output_tokens == request.max_output_tokens,
       do: {:ok, ledger},
       else: {:error, :duplicate_reservation}
  end

  defp allocate(ledger, session, reservations, request, now, opts) do
    with true <- length(reservations) < RuntimeCostLedger.max_outstanding(),
         {:ok, price} <- resolve_price(session, ledger.currency, now, opts),
         {:ok, amount} <- conservative_maximum(price, request) do
      if fits?(ledger, amount),
        do: commit(ledger, reservations, request, amount, price, now),
        else: pause(ledger, now)
    else
      false -> {:error, :capacity_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp conservative_maximum(price, request) do
    PriceSnapshot.conservative_maximum(
      price,
      request.max_input_tokens,
      request.max_output_tokens,
      scale()
    )
  end

  defp fits?(ledger, amount), do: Decimal.compare(amount, remaining(ledger)) != :gt

  defp commit(ledger, reservations, request, amount, price, now) do
    entry = %{
      idempotency_key: request.idempotency_key,
      amount: amount,
      reserved_at: now,
      max_input_tokens: request.max_input_tokens,
      max_output_tokens: request.max_output_tokens
    }

    price
    |> price_attrs()
    |> Map.merge(reservation_attrs([entry | reservations]))
    |> Map.merge(%{paused: false, pause_reason: nil, paused_at: nil})
    |> then(&store(ledger, &1))
  end

  defp pause(ledger, now) do
    case store(ledger, %{
           paused: true,
           pause_reason: "insufficient_capacity",
           paused_at: now
         }) do
      {:ok, _paused} -> {:pause, :insufficient_capacity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle(ledger, idempotency_key, observed) do
    reservations = RuntimeCostLedger.decode_reservations(ledger.outstanding_reservations)

    case Enum.split_with(reservations, &(&1.idempotency_key == idempotency_key)) do
      {[], _remaining} -> {:error, :unknown_reservation}
      {[entry], remaining} -> apply_settlement(ledger, entry, remaining, observed)
    end
  end

  defp apply_settlement(ledger, _entry, remaining, nil) do
    store(ledger, reservation_attrs(remaining))
  end

  defp apply_settlement(ledger, entry, remaining, observed) do
    if Decimal.compare(observed, entry.amount) == :gt do
      {:error, :over_reconciliation}
    else
      remaining
      |> reservation_attrs()
      |> Map.put(:observed_amount, observed_total(ledger, observed))
      |> then(&store(ledger, &1))
    end
  end

  defp observed_total(ledger, observed),
    do: ledger.observed_amount |> Decimal.add(observed) |> Decimal.round(scale())

  defp recover(ledger, cutoff) do
    {abandoned, kept} =
      ledger.outstanding_reservations
      |> RuntimeCostLedger.decode_reservations()
      |> Enum.split_with(&(DateTime.compare(&1.reserved_at, cutoff) != :gt))

    released = abandoned |> Enum.map(& &1.idempotency_key) |> Enum.sort()

    case store(ledger, reservation_attrs(kept)) do
      {:ok, updated} -> {:ok, {released, updated}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reservation_attrs(reservations) do
    %{
      reserved_amount: RuntimeCostLedger.reservation_sum(reservations),
      outstanding_reservations: RuntimeCostLedger.encode_reservations(reservations)
    }
  end

  defp price_attrs(price) do
    %{
      price_version: price.version,
      price_source: price.source,
      price_published_at: price.published_at,
      price_expires_at: price.expires_at,
      input_unit_price: Decimal.round(price.input_unit_price, @unit_price_scale),
      output_unit_price: Decimal.round(price.output_unit_price, @unit_price_scale)
    }
  end

  defp store(ledger, attrs) do
    ledger
    |> RuntimeCostLedger.update_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, _changeset} -> {:error, :capacity_conflict}
    end
  end

  defp resolve_price(session, currency, now, opts) do
    case PriceSnapshot.current(session.model, now, price_opts(opts)) do
      {:ok, %{currency: ^currency} = price} -> {:ok, price}
      {:ok, _mismatched} -> {:error, :missing_price}
      {:error, reason} -> {:error, reason}
    end
  end

  defp price_opts(opts), do: Keyword.take(opts, [:snapshots, :version])

  defp authorize(account_id, session_id) do
    case active_account(account_id, lock: true) do
      %Account{} -> authorize_session(account_id, session_id)
      nil -> {:error, :account_unavailable}
    end
  end

  defp authorize_session(account_id, session_id) do
    case locked_session(account_id, session_id) do
      %AIRuntimeSession{authentication_mode: "api_key"} = session -> {:ok, session}
      %AIRuntimeSession{} -> {:error, :not_applicable}
      nil -> {:error, :not_found}
    end
  end

  defp session_ceiling(%AIRuntimeSession{
         spending_ceiling_amount: %Decimal{} = amount,
         spending_ceiling_currency: currency
       })
       when is_binary(currency),
       do: {:ok, %{amount: amount, currency: currency}}

  defp session_ceiling(_session), do: {:error, :not_applicable}

  defp within_bounds(ledger, request) do
    if request.max_input_tokens <= ledger.max_input_tokens and
         request.max_output_tokens <= ledger.max_output_tokens,
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp remaining(ledger) do
    ledger.ceiling
    |> Decimal.sub(ledger.reserved_amount)
    |> Decimal.sub(ledger.observed_amount)
    |> Decimal.round(scale())
  end

  defp zero, do: Decimal.round(Decimal.new(0), scale())

  defp projection(%RuntimeCostLedger{} = ledger) do
    %{
      session_id: ledger.session_id,
      currency: ledger.currency,
      ceiling: Decimal.round(ledger.ceiling, scale()),
      reserved: Decimal.round(ledger.reserved_amount, scale()),
      observed: Decimal.round(ledger.observed_amount, scale()),
      remaining: remaining(ledger),
      bounded_request: %{
        max_input_tokens: ledger.max_input_tokens,
        max_output_tokens: ledger.max_output_tokens
      },
      price: %{
        version: ledger.price_version,
        source: ledger.price_source,
        published_at: ledger.price_published_at,
        expires_at: ledger.price_expires_at,
        input_unit_price: ledger.input_unit_price,
        output_unit_price: ledger.output_unit_price
      },
      outstanding: RuntimeCostLedger.decode_reservations(ledger.outstanding_reservations),
      paused: ledger.paused,
      pause_reason: pause_reason(ledger.pause_reason),
      paused_at: ledger.paused_at
    }
  end

  defp pause_reason(nil), do: nil
  defp pause_reason("insufficient_capacity"), do: :insufficient_capacity

  defp project({:ok, %RuntimeCostLedger{} = ledger}), do: {:ok, projection(ledger)}
  defp project(other), do: other

  defp project_reservation({:ok, %RuntimeCostLedger{} = ledger}, idempotency_key) do
    ledger = projection(ledger)

    case Enum.find(ledger.outstanding, &(&1.idempotency_key == idempotency_key)) do
      nil -> {:error, :capacity_conflict}
      reservation -> {:ok, %{reservation: reservation, ledger: ledger}}
    end
  end

  defp project_reservation(other, _idempotency_key), do: other

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:pause, reason} -> {:paused, reason}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:paused, reason}} -> {:pause, reason}
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_open_request(request) when is_map(request) do
    with {:ok, request} <- exact_map(request, @open_keys),
         {:ok, max_input_tokens} <- bounded_tokens(request.max_input_tokens),
         {:ok, max_output_tokens} <- bounded_tokens(request.max_output_tokens) do
      {:ok, %{max_input_tokens: max_input_tokens, max_output_tokens: max_output_tokens}}
    end
  end

  defp normalize_open_request(_request), do: {:error, :invalid_request}

  defp normalize_reserve_request(request) when is_map(request) do
    with {:ok, request} <- exact_map(request, @reserve_keys),
         {:ok, key} <- RuntimeCostLedger.validate_idempotency_key(request.idempotency_key),
         {:ok, max_input_tokens} <- bounded_tokens(request.max_input_tokens),
         {:ok, max_output_tokens} <- bounded_tokens(request.max_output_tokens) do
      {:ok,
       %{
         idempotency_key: key,
         max_input_tokens: max_input_tokens,
         max_output_tokens: max_output_tokens
       }}
    end
  end

  defp normalize_reserve_request(_request), do: {:error, :invalid_request}

  defp bounded_tokens(tokens) when is_integer(tokens) do
    if tokens in 1..PriceSnapshot.max_tokens(),
      do: {:ok, tokens},
      else: {:error, :invalid_request}
  end

  defp bounded_tokens(_tokens), do: {:error, :invalid_request}

  defp normalize_amount(%Decimal{} = amount), do: bounded_amount(amount)
  defp normalize_amount(amount) when is_integer(amount), do: bounded_amount(Decimal.new(amount))

  defp normalize_amount(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {%Decimal{} = parsed, ""} -> bounded_amount(parsed)
      _other -> {:error, :invalid_request}
    end
  end

  defp normalize_amount(_amount), do: {:error, :invalid_request}

  defp bounded_amount(%Decimal{coef: coef}) when coef in [:inf, :qNaN, :sNaN],
    do: {:error, :invalid_request}

  defp bounded_amount(%Decimal{} = amount) do
    with true <- Regex.match?(~r/\A\d+(\.\d{1,4})?\z/, Decimal.to_string(amount, :normal)),
         true <- Decimal.compare(amount, 0) != :lt,
         true <- Decimal.compare(amount, RuntimeCostLedger.max_amount()) != :gt do
      {:ok, amount}
    else
      _other -> {:error, :invalid_request}
    end
  end

  defp abandoned_after_seconds(opts) do
    seconds =
      Keyword.get_lazy(opts, :abandoned_after_seconds, fn ->
        Application.get_env(
          :sdd_orchestrator,
          :runtime_cost_reservation_timeout_seconds,
          @default_abandoned_after_seconds
        )
      end)

    if is_integer(seconds) and seconds in 1..@max_abandoned_after_seconds,
      do: {:ok, seconds},
      else: {:error, :invalid_request}
  end

  defp scale, do: RuntimeCostLedger.amount_scale()

  defp locked_ledger(session_id) do
    query =
      from ledger in RuntimeCostLedger,
        where: ledger.session_id == ^session_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      %RuntimeCostLedger{} = ledger -> {:ok, ledger}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_ledger(account_id, session_id) do
    Repo.one(
      from ledger in RuntimeCostLedger,
        where: ledger.account_id == ^account_id and ledger.session_id == ^session_id
    )
  end

  defp locked_session(account_id, session_id) do
    Repo.one(
      from session in AIRuntimeSession,
        where: session.account_id == ^account_id and session.id == ^session_id,
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
end
