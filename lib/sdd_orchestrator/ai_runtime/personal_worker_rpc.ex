defmodule SddOrchestrator.AIRuntime.PersonalWorkerRPC do
  @moduledoc """
  The control plane's boundary for bounded personal AI worker operations.

  A paired worker registers its one live personal AI connection here when it
  joins its workspace channel, so a request is a registry lookup rather than
  an outbound connection. Registration is unique per `{device_workspace_id,
  worker_id}`: a reconnect replaces the stale channel instead of queueing
  behind it, and nothing authoritative lives in the registry — after a restart
  every worker reconnects and re-registers.

  `request/6` binds one account to one capability call on one worker's
  workspace, enforces the envelope contract and payload limit before anything
  is sent, and awaits the correlated response under a bounded deadline. Every
  outcome is a typed atom; raw worker text never crosses this boundary.
  """

  alias SddOrchestrator.AIRuntime.PersonalWorkerProtocol
  alias SddOrchestrator.AIRuntime.SecurityLog

  @registry SddOrchestrator.AIRuntime.PersonalWorkerRegistry

  @default_timeout_ms 15_000
  @idempotency_key_bytes 16

  @typedoc "The only failures a caller can observe."
  @type error ::
          :worker_unavailable
          | :timeout
          | :worker_disconnected
          | :unsupported_capability
          | :payload_too_large
          | :invalid_request
          | :cross_workspace
          | :cross_account
          | :duplicate_request

  @typed_errors ~w(
    worker_unavailable timeout worker_disconnected unsupported_capability
    payload_too_large invalid_request cross_workspace cross_account
    duplicate_request
  )a

  @type connection_meta :: %{
          protocol_version: String.t(),
          capabilities: [String.t()],
          attached_at: DateTime.t()
        }

  @doc "The registry of live personal AI connections, keyed per paired worker."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc """
  Registers the calling channel process as the live personal AI connection for
  one paired worker. Keys are unique: a second registration for the same
  worker is refused with the stale owner's pid so the joining channel can
  replace it deterministically.
  """
  @spec attach(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, pid()} | {:error, {:already_registered, pid()}}
  def attach(device_workspace_id, worker_id, contract) do
    Registry.register(@registry, {device_workspace_id, worker_id}, %{
      protocol_version: Map.fetch!(contract, :protocol_version),
      capabilities: Map.fetch!(contract, :capabilities),
      attached_at: DateTime.utc_now()
    })
  end

  @doc "The live connection for one paired worker, if any."
  @spec connection(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, pid(), connection_meta()} | :error
  def connection(device_workspace_id, worker_id) do
    case Registry.lookup(@registry, {device_workspace_id, worker_id}) do
      [{channel, meta}] -> {:ok, channel, meta}
      [] -> :error
    end
  end

  @doc """
  Carries one bounded, account-scoped capability request to one paired worker
  and awaits its correlated response.

  The registry key is what makes a request addressed to workspace W only ever
  reachable by the worker authenticated for W; the channel re-checks the
  envelope's workspace against its own authenticated assigns as defense in
  depth. Options:

    * `:timeout_ms` — how long to await the response (default #{@default_timeout_ms}).
    * `:idempotency_key` — caller-supplied retry identity; generated when absent.
      Repeating a completed request with the same key returns the cached
      response without re-contacting the worker; reusing the key with
      different content is refused as `:duplicate_request`.

  On timeout the caller stops waiting and the pending entry is canceled, so a
  response arriving later is refused as a replay.
  """
  @spec request(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def request(account_id, device_workspace_id, worker_id, capability, params, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    envelope = %{
      "request_id" => Ecto.UUID.generate(),
      "idempotency_key" => Keyword.get_lazy(opts, :idempotency_key, &generate_idempotency_key/0),
      "account_id" => account_id,
      "device_workspace_id" => device_workspace_id,
      "capability" => capability,
      "params" => params
    }

    result =
      with {:ok, channel, meta} <- lookup(device_workspace_id, worker_id),
           :ok <- validate(envelope, meta) do
        await(channel, envelope, timeout_ms)
      end

    # Every catalog, quota, connection, and observation operation carried over
    # this transport leaves one content-free line when it does not succeed.
    SecurityLog.audit(result, :worker_rpc_request)
  end

  @doc "Generates one opaque idempotency key for a request without a caller-supplied one."
  @spec generate_idempotency_key() :: String.t()
  def generate_idempotency_key,
    do: Base.url_encode64(:crypto.strong_rand_bytes(@idempotency_key_bytes), padding: false)

  defp lookup(device_workspace_id, worker_id) do
    case connection(device_workspace_id, worker_id) do
      {:ok, channel, meta} -> {:ok, channel, meta}
      :error -> {:error, :worker_unavailable}
    end
  end

  # The payload limit and field allowlist are enforced here, before anything
  # is sent, against the capabilities this connection actually negotiated.
  defp validate(envelope, meta) do
    case PersonalWorkerProtocol.validate_request(envelope, meta.capabilities) do
      :ok -> :ok
      {:error, reason} -> {:error, normalize(reason)}
    end
  end

  defp await(channel, envelope, timeout_ms) do
    ref = Process.monitor(channel)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    send(channel, {:ai_request, envelope, self(), ref, deadline})

    receive do
      {__MODULE__, ^ref, reply} ->
        Process.demonitor(ref, [:flush])
        normalize_reply(reply)

      {:DOWN, ^ref, :process, _channel, _reason} ->
        {:error, :worker_disconnected}
    after
      timeout_ms ->
        Process.demonitor(ref, [:flush])
        send(channel, {:cancel_ai_request, envelope["request_id"]})
        drain(ref)
        {:error, :timeout}
    end
  end

  # A reply racing the timeout is discarded here; the channel refuses the
  # worker's late frame as a replay, so neither side acts on it.
  defp drain(ref) do
    receive do
      {__MODULE__, ^ref, _late} -> :ok
    after
      0 -> :ok
    end
  end

  defp normalize_reply({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize_reply({:error, reason}), do: {:error, normalize(reason)}
  defp normalize_reply(_reply), do: {:error, :invalid_request}

  defp normalize(reason) when reason in @typed_errors, do: reason
  defp normalize(_reason), do: :invalid_request
end
