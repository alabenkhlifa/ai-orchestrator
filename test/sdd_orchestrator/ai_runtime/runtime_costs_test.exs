defmodule SddOrchestrator.AIRuntime.RuntimeCostsTest do
  @moduledoc "Task 11 proof for strict non-exceeding API-key cost reservation."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.RuntimeCostLedger
  alias SddOrchestrator.AIRuntime.RuntimeCosts
  alias SddOrchestrator.AIRuntime.RuntimeCosts.PriceSnapshot
  alias SddOrchestrator.AIRuntime.RuntimeSessions

  @now ~U[2026-08-03 12:00:00Z]
  @model "codex-test-model"
  @turn Decimal.new("0.3000")

  @ledger_keys ~w(
    session_id currency ceiling reserved observed remaining bounded_request price
    outstanding paused pause_reason paused_at
  )a

  @reservation_keys ~w(idempotency_key amount reserved_at max_input_tokens max_output_tokens)a

  @schema_fields ~w(
    account_id ceiling currency id input_unit_price inserted_at max_input_tokens
    max_output_tokens observed_amount output_unit_price outstanding_reservations
    pause_reason paused paused_at price_expires_at price_published_at price_source
    price_version reserved_amount session_id updated_at
  )a

  setup do
    runtime_cost_context_fixture(%{now: @now, worker_profile_ref: "profile-cost-secret"})
  end

  describe "current versioned official prices" do
    test "loads a current price and fails closed on a stale, missing, or absent one" do
      assert {:ok, price} =
               PriceSnapshot.current(@model, @now, snapshots: official_price_snapshots())

      assert price.version == "2026-08-01"
      assert price.source == "official_price_list"
      assert price.currency == "USD"
      assert Decimal.equal?(price.input_unit_price, Decimal.new("2.00"))
      assert Decimal.equal?(price.output_unit_price, Decimal.new("10.00"))

      stale_at = DateTime.add(~U[2026-09-01 00:00:00Z], 1, :second)

      assert {:error, :stale_price} =
               PriceSnapshot.current(@model, stale_at, snapshots: official_price_snapshots())

      assert {:error, :missing_price} =
               PriceSnapshot.current("other-model", @now, snapshots: official_price_snapshots())

      assert {:error, :missing_price} =
               PriceSnapshot.current(@model, @now,
                 snapshots: official_price_snapshots(),
                 version: "1999-01-01"
               )

      assert {:error, :missing_price} =
               PriceSnapshot.current(@model, ~U[2026-07-01 00:00:00Z],
                 snapshots: official_price_snapshots()
               )

      assert {:error, :missing_price} = PriceSnapshot.current(@model, @now, snapshots: %{})
      assert {:error, :missing_price} = PriceSnapshot.current(@model, @now)
    end

    test "refuses a malformed, negative, unparseable, oversized, or credential-shaped entry" do
      valid = official_price_snapshot()

      invalid = [
        %{"other-version" => valid},
        %{valid.version => Map.delete(valid, :currency)},
        %{valid.version => Map.put(valid, :currency, "usd")},
        %{valid.version => Map.put(valid, :expires_at, valid.published_at)},
        %{valid.version => Map.put(valid, :source, "Bearer sk-live-abcdefgh1234")},
        %{valid.version => Map.put(valid, :version, String.duplicate("v", 101))},
        %{valid.version => Map.put(valid, :models, %{})},
        %{valid.version => priced(valid, %{input: "-1.00", output: "10.00"})},
        %{valid.version => priced(valid, %{input: "0", output: "10.00"})},
        %{valid.version => priced(valid, %{input: "not-a-number", output: "10.00"})},
        %{valid.version => priced(valid, %{input: 2.5, output: "10.00"})},
        %{valid.version => priced(valid, %{input: "200000.00", output: "10.00"})},
        %{valid.version => priced(valid, %{input: "2.000000001", output: "10.00"})},
        "not-a-registry",
        %{valid.version => "not-a-snapshot"}
      ]

      for registry <- invalid do
        assert {:error, :missing_price} =
                 PriceSnapshot.current(@model, @now, snapshots: registry)
      end
    end

    test "calculates a bounded conservative maximum that always rounds up" do
      {:ok, price} = PriceSnapshot.current(@model, @now, snapshots: official_price_snapshots())

      assert {:ok, amount} = PriceSnapshot.conservative_maximum(price, 100_000, 10_000, 4)
      assert Decimal.equal?(amount, @turn)

      assert {:ok, rounded_up} = PriceSnapshot.conservative_maximum(price, 1, 1, 4)
      assert Decimal.equal?(rounded_up, Decimal.new("0.0001"))

      assert {:error, :invalid_request} = PriceSnapshot.conservative_maximum(price, 0, 1, 4)

      assert {:error, :invalid_request} =
               PriceSnapshot.conservative_maximum(price, PriceSnapshot.max_tokens() + 1, 1, 4)

      assert {:error, :invalid_request} = PriceSnapshot.conservative_maximum(price, 1, -1, 4)
    end
  end

  describe "opening one strict ceiling" do
    test "opens one immutable bounded ceiling per API-key session", context do
      assert {:ok, ledger} = open(context)

      assert ledger.session_id == context.session.session_id
      assert ledger.currency == "USD"
      assert Decimal.equal?(ledger.ceiling, Decimal.new("1.00"))
      assert Decimal.equal?(ledger.reserved, 0)
      assert Decimal.equal?(ledger.observed, 0)
      assert Decimal.equal?(ledger.remaining, Decimal.new("1.00"))
      assert ledger.bounded_request == %{max_input_tokens: 100_000, max_output_tokens: 10_000}
      assert ledger.price.version == "2026-08-01"
      assert ledger.price.source == "official_price_list"
      assert ledger.outstanding == []
      assert ledger.paused == false
      assert ledger.pause_reason == nil
      assert ledger.paused_at == nil

      assert {:ok, ^ledger} = open(context)
      assert {:ok, ^ledger} = RuntimeCosts.get_ledger(context.account, ledger.session_id)

      assert {:error, :configuration_conflict} = open(context, %{max_output_tokens: 20_000})
      assert Repo.aggregate(RuntimeCostLedger, :count) == 1
    end

    test "applies only to API-key sessions and refuses unknown or unowned ones", context do
      chatgpt =
        runtime_session_context_fixture(%{
          account: context.account,
          worker: context.worker,
          label: "ChatGPT Codex",
          worker_profile_ref: "profile-chatgpt",
          now: @now
        })

      session = ai_runtime_session_fixture(chatgpt, %{now: @now, consumer_ref: "run-chatgpt"})

      assert {:error, :not_applicable} =
               RuntimeCosts.open_ledger(
                 context.account,
                 session.session_id,
                 runtime_cost_open_request(),
                 opts()
               )

      assert {:error, :not_applicable} =
               RuntimeCosts.reserve(
                 context.account,
                 session.session_id,
                 runtime_cost_reserve_request(),
                 opts()
               )

      assert {:error, :not_found} =
               RuntimeCosts.open_ledger(
                 context.account,
                 Ecto.UUID.generate(),
                 runtime_cost_open_request(),
                 opts()
               )

      other = runtime_cost_context_fixture(%{now: @now})

      assert {:error, :not_found} =
               RuntimeCosts.open_ledger(
                 context.account,
                 other.session.session_id,
                 runtime_cost_open_request(),
                 opts()
               )

      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end

    test "fails closed when the official price is missing, stale, or foreign", context do
      assert {:error, :missing_price} = open(context, %{snapshots: %{}})

      assert {:error, :stale_price} =
               open(context, %{now: DateTime.add(~U[2026-09-01 00:00:00Z], 1, :second)})

      assert {:error, :missing_price} =
               open(context, %{snapshots: official_price_snapshots(%{model: "other-model"})})

      assert {:error, :missing_price} =
               open(context, %{snapshots: official_price_snapshots(%{currency: "EUR"})})

      assert {:error, :invalid_request} = open(context, %{max_input_tokens: 0})
      assert {:error, :invalid_request} = open(context, %{max_output_tokens: "many"})
      assert Repo.aggregate(RuntimeCostLedger, :count) == 0
    end
  end

  describe "atomic reservation inside the approved ceiling" do
    test "reserves below capacity and reports the remaining approved capacity", context do
      assert {:ok, _ledger} = open(context)

      assert {:ok, %{reservation: reservation, ledger: ledger}} =
               reserve(context, %{idempotency_key: "turn-1"})

      assert reservation.idempotency_key == "turn-1"
      assert Decimal.equal?(reservation.amount, @turn)
      assert reservation.reserved_at == @now
      assert reservation.max_input_tokens == 100_000
      assert reservation.max_output_tokens == 10_000

      assert Decimal.equal?(ledger.reserved, @turn)
      assert Decimal.equal?(ledger.observed, 0)
      assert Decimal.equal?(ledger.remaining, Decimal.new("0.7000"))
      assert ledger.paused == false

      assert {:ok, %{amount: remaining, currency: "USD"}} =
               RuntimeCosts.remaining_capacity(context.account, ledger.session_id)

      assert Decimal.equal?(remaining, Decimal.new("0.7000"))

      record = Repo.get_by!(RuntimeCostLedger, session_id: ledger.session_id)
      assert Decimal.equal?(record.reserved_amount, @turn)
      assert Map.keys(record.outstanding_reservations) == ["turn-1"]
    end

    test "reserves exactly at capacity and pauses before exceeding it", _context do
      exact = runtime_cost_context_fixture(%{now: @now, ceiling: "0.60"})
      assert {:ok, _ledger} = open(exact)

      assert {:ok, %{ledger: first}} = reserve(exact, %{idempotency_key: "turn-1"})
      assert Decimal.equal?(first.remaining, Decimal.new("0.3000"))

      assert {:ok, %{ledger: second}} = reserve(exact, %{idempotency_key: "turn-2"})
      assert Decimal.equal?(second.reserved, Decimal.new("0.6000"))
      assert Decimal.equal?(second.remaining, 0)
      assert second.paused == false

      assert {:pause, :insufficient_capacity} = reserve(exact, %{idempotency_key: "turn-3"})

      assert {:ok, paused} = RuntimeCosts.get_ledger(exact.account, second.session_id)
      assert paused.paused == true
      assert paused.pause_reason == :insufficient_capacity
      assert paused.paused_at == @now
      assert Decimal.equal?(paused.reserved, Decimal.new("0.6000"))
      assert Decimal.equal?(paused.observed, 0)
      assert Enum.map(paused.outstanding, & &1.idempotency_key) == ["turn-1", "turn-2"]
    end

    test "a resumable pause preserves the pinned session and later resumes", _context do
      exact = runtime_cost_context_fixture(%{now: @now, ceiling: "0.30"})
      assert {:ok, _ledger} = open(exact)
      assert {:ok, %{ledger: full}} = reserve(exact, %{idempotency_key: "turn-1"})
      assert Decimal.equal?(full.remaining, 0)

      assert {:pause, :insufficient_capacity} = reserve(exact, %{idempotency_key: "turn-2"})

      assert {:ok, session} =
               RuntimeSessions.get_session(exact.account, exact.session.session_id)

      assert session.session_id == exact.session.session_id
      assert session.model == exact.session.model
      assert session.effort == exact.session.effort
      assert session.opt_ins == exact.session.opt_ins
      assert session.pinned_at == exact.session.pinned_at

      assert Decimal.equal?(
               session.spending_ceiling.amount,
               exact.session.spending_ceiling.amount
             )

      assert {:ok, paused} = RuntimeCosts.get_ledger(exact.account, exact.session.session_id)
      assert paused.paused == true
      assert paused.pause_reason == :insufficient_capacity
      assert Decimal.equal?(paused.reserved, @turn)
      assert Enum.map(paused.outstanding, & &1.idempotency_key) == ["turn-1"]

      assert {:ok, _released} =
               RuntimeCosts.release(exact.account, exact.session.session_id, "turn-1")

      assert {:ok, %{ledger: resumed}} = reserve(exact, %{idempotency_key: "turn-2"})
      assert resumed.paused == false
      assert resumed.pause_reason == nil
      assert resumed.paused_at == nil
      assert Decimal.equal?(resumed.reserved, @turn)
    end

    test "replays an outstanding key and refuses a reused key with other bounds", context do
      assert {:ok, _ledger} = open(context)

      assert {:ok, %{reservation: first, ledger: ledger}} =
               reserve(context, %{idempotency_key: "turn-1"})

      assert {:ok, %{reservation: ^first, ledger: ^ledger}} =
               reserve(context, %{idempotency_key: "turn-1", now: DateTime.add(@now, 60, :second)})

      assert Decimal.equal?(ledger.reserved, @turn)
      assert length(ledger.outstanding) == 1

      assert {:error, :duplicate_reservation} =
               reserve(context, %{idempotency_key: "turn-1", max_output_tokens: 5_000})

      assert {:error, :invalid_request} =
               reserve(context, %{idempotency_key: "turn-2", max_input_tokens: 200_000})

      assert {:error, :invalid_request} =
               reserve(context, %{idempotency_key: "sk-live-abcdefgh1234"})

      assert {:ok, unchanged} = RuntimeCosts.get_ledger(context.account, ledger.session_id)
      assert Decimal.equal?(unchanged.reserved, @turn)
    end

    test "uses the current price version after the official price list changes", context do
      assert {:ok, _ledger} = open(context)
      assert {:ok, %{reservation: first}} = reserve(context, %{idempotency_key: "turn-1"})
      assert Decimal.equal?(first.amount, @turn)

      repriced =
        Map.merge(
          official_price_snapshots(),
          official_price_snapshots(%{
            version: "2026-08-03",
            published_at: ~U[2026-08-03 00:00:00Z],
            expires_at: ~U[2026-09-15 00:00:00Z],
            input: "4.00",
            output: "20.00"
          })
        )

      assert {:ok, %{reservation: second, ledger: ledger}} =
               reserve(context, %{idempotency_key: "turn-2", snapshots: repriced})

      assert Decimal.equal?(second.amount, Decimal.new("0.6000"))
      assert ledger.price.version == "2026-08-03"
      assert Decimal.equal?(ledger.reserved, Decimal.new("0.9000"))

      assert {:pause, :insufficient_capacity} =
               reserve(context, %{idempotency_key: "turn-3", snapshots: repriced})
    end

    test "fails closed and allocates nothing on a missing or stale price", context do
      assert {:ok, _ledger} = open(context)

      assert {:error, :missing_price} = reserve(context, %{idempotency_key: "t", snapshots: %{}})

      assert {:error, :stale_price} =
               reserve(context, %{
                 idempotency_key: "t",
                 now: DateTime.add(~U[2026-09-01 00:00:00Z], 1, :second)
               })

      assert {:error, :missing_price} =
               reserve(context, %{
                 idempotency_key: "t",
                 snapshots: official_price_snapshots(%{currency: "EUR"})
               })

      assert {:ok, ledger} = RuntimeCosts.get_ledger(context.account, context.session.session_id)
      assert Decimal.equal?(ledger.reserved, 0)
      assert ledger.outstanding == []
      assert ledger.paused == false
    end
  end

  describe "reconciliation, release, and abandoned recovery" do
    test "reconciles observed usage and refuses an over-reconciliation", context do
      assert {:ok, _ledger} = open(context)
      assert {:ok, _reserved} = reserve(context, %{idempotency_key: "turn-1"})

      assert {:error, :over_reconciliation} =
               RuntimeCosts.reconcile(
                 context.account,
                 context.session.session_id,
                 "turn-1",
                 "0.3001"
               )

      assert {:error, :unknown_reservation} =
               RuntimeCosts.reconcile(
                 context.account,
                 context.session.session_id,
                 "turn-missing",
                 "0.1000"
               )

      assert {:error, :invalid_request} =
               RuntimeCosts.reconcile(
                 context.account,
                 context.session.session_id,
                 "turn-1",
                 "-0.1000"
               )

      assert {:ok, ledger} =
               RuntimeCosts.reconcile(
                 context.account,
                 context.session.session_id,
                 "turn-1",
                 Decimal.new("0.2500")
               )

      assert Decimal.equal?(ledger.reserved, 0)
      assert Decimal.equal?(ledger.observed, Decimal.new("0.2500"))
      assert Decimal.equal?(ledger.remaining, Decimal.new("0.7500"))
      assert ledger.outstanding == []

      assert {:error, :unknown_reservation} =
               RuntimeCosts.reconcile(
                 context.account,
                 context.session.session_id,
                 "turn-1",
                 "0.1000"
               )
    end

    test "releases one unused reservation back into the remaining ceiling", context do
      assert {:ok, _ledger} = open(context)
      assert {:ok, _first} = reserve(context, %{idempotency_key: "turn-1"})
      assert {:ok, _second} = reserve(context, %{idempotency_key: "turn-2"})

      assert {:ok, ledger} =
               RuntimeCosts.release(context.account, context.session.session_id, "turn-1")

      assert Decimal.equal?(ledger.reserved, @turn)
      assert Decimal.equal?(ledger.observed, 0)
      assert Enum.map(ledger.outstanding, & &1.idempotency_key) == ["turn-2"]

      assert {:error, :unknown_reservation} =
               RuntimeCosts.release(context.account, context.session.session_id, "turn-1")
    end

    test "recovers abandoned reservations without ever charging them", context do
      assert {:ok, _ledger} = open(context)
      assert {:ok, _first} = reserve(context, %{idempotency_key: "turn-old"})

      later = DateTime.add(@now, 800, :second)
      assert {:ok, _second} = reserve(context, %{idempotency_key: "turn-recent", now: later})

      assert {:ok, %{released: released, ledger: ledger}} =
               RuntimeCosts.recover_abandoned(context.account, context.session.session_id,
                 now: DateTime.add(@now, 1_000, :second),
                 abandoned_after_seconds: 900
               )

      assert released == ["turn-old"]
      assert Decimal.equal?(ledger.reserved, @turn)
      assert Decimal.equal?(ledger.observed, 0)
      assert Enum.map(ledger.outstanding, & &1.idempotency_key) == ["turn-recent"]

      assert {:error, :invalid_request} =
               RuntimeCosts.recover_abandoned(context.account, context.session.session_id,
                 abandoned_after_seconds: 0
               )
    end
  end

  describe "no concurrent over-allocation" do
    test "concurrent reservers never allocate more than the approved ceiling", context do
      assert {:ok, _ledger} = open(context)
      account = context.account
      session_id = context.session.session_id

      results =
        1..5
        |> Enum.map(fn index ->
          Task.async(fn ->
            RuntimeCosts.reserve(
              account,
              session_id,
              runtime_cost_reserve_request(%{idempotency_key: "turn-#{index}"}),
              opts()
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _reserved}, &1)) == 3
      assert Enum.count(results, &(&1 == {:pause, :insufficient_capacity})) == 2

      assert {:ok, ledger} = RuntimeCosts.get_ledger(account, session_id)
      assert Decimal.equal?(ledger.reserved, Decimal.new("0.9000"))
      assert Decimal.equal?(ledger.remaining, Decimal.new("0.1000"))
      assert length(ledger.outstanding) == 3

      record = Repo.get_by!(RuntimeCostLedger, session_id: session_id)

      assert Decimal.compare(
               Decimal.add(record.reserved_amount, record.observed_amount),
               record.ceiling
             ) != :gt
    end

    test "the database refuses a concurrent write that would exceed the ceiling", context do
      assert {:ok, ledger} = open(context)
      session_id = ledger.session_id

      results =
        1..4
        |> Enum.map(fn _index -> Task.async(fn -> unlocked_increment(session_id, @turn) end) end)
        |> Enum.map(&Task.await(&1, 5_000))

      assert Enum.count(results, &match?({:ok, _updated}, &1)) == 3
      assert Enum.count(results, &match?({:error, _rejected}, &1)) == 1

      assert [rejected] = Enum.filter(results, &match?({:error, _rejected}, &1))
      assert {:error, changeset} = rejected
      assert changeset.errors[:reserved_amount]

      record = Repo.get_by!(RuntimeCostLedger, session_id: session_id)
      assert Decimal.equal?(record.reserved_amount, Decimal.new("0.9000"))

      for {field, value} <- [
            reserved_amount: Decimal.new("-0.0001"),
            observed_amount: Decimal.new("-0.0001")
          ] do
        assert {:error, invalid} = unlocked_change(record, field, value)
        assert invalid.errors[field]
      end
    end
  end

  describe "capability contract and minimized persistence" do
    test "a downstream consumer pins a session and obtains its enforced boundary", context do
      request =
        runtime_session_request(context, %{
          consumer: :support_assistant,
          consumer_ref: "downstream-conversation",
          spending_ceiling: %{amount: Decimal.new("1.00"), currency: "USD"}
        })

      assert {:ok, session} = RuntimeSessions.pin_session(context.account, request, now: @now)
      assert session.authentication_mode == "api_key"

      assert {:ok, ledger} =
               RuntimeCosts.open_ledger(
                 context.account,
                 session.session_id,
                 runtime_cost_open_request(),
                 opts()
               )

      assert ledger.session_id == session.session_id

      assert {:ok, %{reservation: reservation, ledger: reserved}} =
               RuntimeCosts.reserve(
                 context.account,
                 session.session_id,
                 runtime_cost_reserve_request(%{idempotency_key: "downstream-turn"}),
                 opts()
               )

      assert Decimal.equal?(reservation.amount, @turn)

      assert {:ok, %{amount: remaining, currency: "USD"}} =
               RuntimeCosts.remaining_capacity(context.account, session.session_id)

      assert Decimal.equal?(remaining, Decimal.new("0.7000"))

      assert Enum.sort(Map.keys(reserved)) == Enum.sort(@ledger_keys)
      assert Enum.sort(Map.keys(reservation)) == Enum.sort(@reservation_keys)

      assert Enum.sort(Map.keys(reserved.bounded_request)) ==
               Enum.sort(~w(max_input_tokens max_output_tokens)a)

      assert Enum.sort(Map.keys(reserved.price)) ==
               Enum.sort(
                 ~w(version source published_at expires_at input_unit_price output_unit_price)a
               )
    end

    test "persists and projects only the approved minimized fields", context do
      assert {:ok, _ledger} = open(context)
      assert {:ok, %{ledger: ledger}} = reserve(context, %{idempotency_key: "turn-1"})

      assert Enum.sort(RuntimeCostLedger.__schema__(:fields)) == Enum.sort(@schema_fields)
      assert Enum.sort(Map.keys(ledger)) == Enum.sort(@ledger_keys)

      record = Repo.get_by!(RuntimeCostLedger, session_id: ledger.session_id)

      refute contains_value?(Map.from_struct(record), "profile-cost-secret")
      refute contains_value?(ledger, "profile-cost-secret")

      assert {:error, :account_unavailable} =
               RuntimeCosts.get_ledger(Ecto.UUID.generate(), ledger.session_id)

      assert {:error, :not_found} = RuntimeCosts.get_ledger(context.account, Ecto.UUID.generate())
    end
  end

  defp open(context, attrs \\ %{}) do
    RuntimeCosts.open_ledger(
      context.account,
      context.session.session_id,
      runtime_cost_open_request(attrs),
      opts(attrs)
    )
  end

  defp reserve(context, attrs) do
    RuntimeCosts.reserve(
      context.account,
      context.session.session_id,
      runtime_cost_reserve_request(attrs),
      opts(attrs)
    )
  end

  defp opts(attrs \\ %{}) do
    [
      now: Map.get(attrs, :now, @now),
      snapshots: Map.get_lazy(attrs, :snapshots, fn -> official_price_snapshots() end)
    ]
  end

  defp priced(snapshot, prices), do: Map.put(snapshot, :models, %{@model => prices})

  defp unlocked_increment(session_id, amount) do
    Repo.transaction(fn ->
      record = Repo.get_by!(RuntimeCostLedger, session_id: session_id)
      unlocked_change(record, :reserved_amount, Decimal.add(record.reserved_amount, amount))
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp unlocked_change(record, field, value) do
    record
    |> Ecto.Changeset.change([{field, value}])
    |> Ecto.Changeset.check_constraint(field, name: :runtime_cost_ledgers_capacity_check)
    |> Repo.update(mode: :savepoint)
  end

  defp contains_value?(value, forbidden) when is_binary(value),
    do: String.contains?(value, forbidden)

  defp contains_value?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, forbidden))

  defp contains_value?(value, forbidden) when is_map(value) and not is_struct(value),
    do: Enum.any?(Map.values(value), &contains_value?(&1, forbidden))

  defp contains_value?(_value, _forbidden), do: false
end
