defmodule SddOrchestrator.HostedAccess.RateLimiter do
  @moduledoc """
  In-memory account-neutral token buckets for passwordless delivery.

  Email and network identifiers are converted to process-secret HMAC keys
  before entering state. The limiter keeps no raw personal identifiers and
  returns only an allow-or-throttle decision.
  """
  use GenServer

  @name __MODULE__

  @type bucket :: %{tokens: float(), updated_at: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Consumes one token from the email, IP, and global buckets atomically."
  @spec allow?(String.t(), :inet.ip_address() | String.t() | nil) :: boolean()
  def allow?(email_key, ip_address) do
    GenServer.call(@name, {:allow?, email_key, normalize_ip(ip_address)})
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    GenServer.call(@name, :reset)
  end

  @impl true
  def init(_opts), do: {:ok, new_state()}

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, new_state()}

  def handle_call({:allow?, email_key, ip_address}, _from, state) do
    now = System.monotonic_time(:millisecond)

    keys = [
      {:email, protected_key(state.secret, "email", email_key)},
      {:ip, protected_key(state.secret, "ip", ip_address)},
      {:global, protected_key(state.secret, "global", "send")}
    ]

    refreshed =
      Map.new(keys, fn {kind, key} ->
        limit = Map.fetch!(state.limits, kind)
        bucket = Map.get(state.buckets, key, full_bucket(limit, now))
        {key, {kind, refill(bucket, limit, now)}}
      end)

    if Enum.all?(refreshed, fn {_key, {_kind, bucket}} -> bucket.tokens >= 1.0 end) do
      buckets =
        Enum.reduce(refreshed, state.buckets, fn {key, {_kind, bucket}}, acc ->
          Map.put(acc, key, %{bucket | tokens: bucket.tokens - 1.0})
        end)

      {:reply, true, %{state | buckets: buckets}}
    else
      buckets =
        Enum.reduce(refreshed, state.buckets, fn {key, {_kind, bucket}}, acc ->
          Map.put(acc, key, bucket)
        end)

      {:reply, false, %{state | buckets: buckets}}
    end
  end

  defp new_state do
    %{secret: :crypto.strong_rand_bytes(32), buckets: %{}, limits: limits()}
  end

  defp limits do
    configured =
      :sdd_orchestrator
      |> Application.fetch_env!(:passwordless)
      |> Keyword.fetch!(:rate_limits)

    Map.new([:email, :ip, :global], fn kind ->
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

  defp normalize_ip(ip_address) when is_tuple(ip_address) do
    ip_address
    |> :inet.ntoa()
    |> to_string()
  end

  defp normalize_ip(ip_address) when is_binary(ip_address), do: ip_address
  defp normalize_ip(_ip_address), do: "unavailable"
end
