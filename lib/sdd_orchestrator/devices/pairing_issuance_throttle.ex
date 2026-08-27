defmodule SddOrchestrator.Devices.PairingIssuanceThrottle do
  @moduledoc """
  In-memory token buckets bounding anonymous pairing-code issuance.

  Issuing a code requires no account, so the only thing standing between an
  unidentified caller and unbounded minting is this. It follows the same shape
  as `SddOrchestrator.HostedAccess.RateLimiter`: a per-caller bucket and a
  global one, both consumed together, so one noisy source cannot exhaust the
  service and the service cannot be exhausted by many quiet ones.

  The caller key is HMAC'd with a per-process secret before it enters state, so
  no raw network identifier is held. Buckets are refilled by elapsed time rather
  than stored windows, hold nothing but a token count and a timestamp, and live
  only in memory, so they expire with the process and describe no person or
  machine. Nothing here is a stable device identifier and nothing feeds
  analytics.
  """
  use GenServer

  @name __MODULE__

  @type bucket :: %{tokens: float(), updated_at: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Consumes one token from the caller and global buckets together.

  Returns `false` when either is empty. A refused caller learns only that it was
  refused; the answer says nothing about any code it obtained earlier.
  """
  @spec allow?(:inet.ip_address() | String.t() | nil) :: boolean()
  def allow?(caller) do
    GenServer.call(@name, {:allow?, normalize(caller)})
  end

  @doc false
  @spec reset() :: :ok
  def reset, do: GenServer.call(@name, :reset)

  @impl true
  def init(_opts), do: {:ok, new_state()}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, new_state()}

  def handle_call({:allow?, caller}, _from, state) do
    now = System.monotonic_time(:millisecond)

    keys = [
      {:caller, protected_key(state.secret, "caller", caller)},
      {:global, protected_key(state.secret, "global", "issue")}
    ]

    refreshed =
      Map.new(keys, fn {kind, key} ->
        limit = Map.fetch!(state.limits, kind)
        bucket = Map.get(state.buckets, key, full_bucket(limit, now))
        {key, {kind, refill(bucket, limit, now)}}
      end)

    allowed? = Enum.all?(refreshed, fn {_key, {_kind, bucket}} -> bucket.tokens >= 1.0 end)

    buckets =
      Enum.reduce(refreshed, state.buckets, fn {key, {_kind, bucket}}, acc ->
        Map.put(acc, key, if(allowed?, do: %{bucket | tokens: bucket.tokens - 1.0}, else: bucket))
      end)

    {:reply, allowed?, %{state | buckets: buckets}}
  end

  defp new_state do
    %{secret: :crypto.strong_rand_bytes(32), buckets: %{}, limits: limits()}
  end

  defp limits do
    configured =
      :sdd_orchestrator
      |> Application.fetch_env!(:pairing_issuance)
      |> Keyword.fetch!(:rate_limits)

    Map.new([:caller, :global], fn kind ->
      limit = Keyword.fetch!(configured, kind)

      {kind,
       %{
         capacity: Keyword.fetch!(limit, :capacity),
         window_ms: Keyword.fetch!(limit, :window_ms)
       }}
    end)
  end

  defp full_bucket(limit, now), do: %{tokens: limit.capacity * 1.0, updated_at: now}

  defp refill(bucket, limit, now) do
    elapsed = max(now - bucket.updated_at, 0)
    refill_rate = limit.capacity / limit.window_ms

    %{
      tokens: min(limit.capacity * 1.0, bucket.tokens + elapsed * refill_rate),
      updated_at: now
    }
  end

  defp protected_key(secret, category, identifier) do
    :crypto.mac(:hmac, :sha256, secret, [category, ?:, identifier])
  end

  defp normalize(caller) when is_tuple(caller), do: caller |> :inet.ntoa() |> to_string()
  defp normalize(caller) when is_binary(caller), do: caller
  defp normalize(_caller), do: "unavailable"
end
