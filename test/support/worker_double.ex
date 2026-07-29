defmodule SddOrchestrator.WorkerDouble do
  @moduledoc """
  A protocol-compatible worker for tests.

  It does what a real worker does and nothing more: it dials in with a signed
  credential, negotiates one versioned capability contract, and speaks only
  envelopes the shared codec accepts — plus the malformed, oversized, and stale
  frames the gateway must refuse.

  Every payload comes from the shared protocol fixtures, so a change to the
  envelope contract breaks the double instead of quietly passing through it.
  """
  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.ProtocolLimits
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestratorWeb.{WorkerChannel, WorkerSocket}

  @endpoint SddOrchestratorWeb.Endpoint

  @stale_seconds 30 * 24 * 60 * 60

  @doc "Signs a worker credential for one project."
  def token(project_id, opts \\ []) do
    WorkerSocket.issue(
      project_id,
      Keyword.get(opts, :worker_id, DeliveryProtocolFixtures.worker_id()),
      Keyword.take(opts, [:signed_at])
    )
  end

  @doc "A credential whose bounded lifetime elapsed long ago."
  def stale_token(project_id, opts \\ []) do
    token(project_id, Keyword.put(opts, :signed_at, System.system_time(:second) - @stale_seconds))
  end

  @doc "Opens one authenticated worker socket."
  def connect_worker(project_id, opts \\ []) do
    credential = Keyword.get_lazy(opts, :token, fn -> token(project_id, opts) end)

    connect(WorkerSocket, %{"token" => credential})
  end

  @doc "Opens a socket with whatever connect parameters the caller supplies."
  def connect_with(params), do: connect(WorkerSocket, params)

  @doc """
  Connects and joins one project's worker topic.

  `:topic_project_id` joins a different project than the credential names, and
  `:announcement` overrides the negotiated protocol version or capabilities.
  """
  def attach(project_id, opts \\ []) do
    case connect_worker(project_id, opts) do
      {:ok, socket} ->
        join_worker(
          socket,
          Keyword.get(opts, :topic_project_id, project_id),
          Keyword.get(opts, :announcement, %{})
        )

      :error ->
        :error
    end
  end

  @doc "Joins one project's worker topic through the socket's own routing."
  def join_worker(socket, project_id, overrides \\ %{}) do
    subscribe_and_join(
      socket,
      "worker:#{project_id}",
      DeliveryProtocolFixtures.announcement(overrides)
    )
  end

  @doc "Joins an arbitrary topic on the channel, bypassing socket routing."
  def join_topic(socket, topic, payload \\ %{}) do
    subscribe_and_join(socket, WorkerChannel, topic, payload)
  end

  def acknowledge(channel, overrides \\ %{}),
    do: push(channel, "acknowledge", DeliveryProtocolFixtures.acknowledgement(overrides))

  def heartbeat(channel, overrides \\ %{}),
    do: push(channel, "heartbeat", DeliveryProtocolFixtures.heartbeat(overrides))

  def emit_event(channel, overrides \\ %{}),
    do: push(channel, "event", DeliveryProtocolFixtures.event(overrides))

  def reconcile(channel, overrides \\ %{}),
    do: push(channel, "reconcile", DeliveryProtocolFixtures.reconciliation_snapshot(overrides))

  @doc "Pushes a frame the codec must refuse: a required ordering field is gone."
  def malformed_event(channel),
    do: push(channel, "event", Map.delete(DeliveryProtocolFixtures.event(), "sequence"))

  @doc "Pushes a frame beyond the configured payload limit."
  def oversized_event(channel, overrides \\ %{}) do
    filler = String.duplicate("x", ProtocolLimits.get(:max_payload_bytes) + 1)

    emit_event(channel, Map.put(overrides, "payload", %{"summary" => filler}))
  end

  @doc "Pushes a message name the gateway does not implement."
  def unsupported(channel), do: push(channel, "provision", %{"anything" => true})
end
