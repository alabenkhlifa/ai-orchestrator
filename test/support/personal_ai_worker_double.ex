defmodule SddOrchestrator.PersonalAIWorkerDouble do
  @moduledoc """
  A paired personal AI worker for tests.

  It does what a real worker does and nothing more: it completes a real
  pairing through `SddOrchestrator.Devices.Pairing`, dials in with the
  credential the pairing returned once, negotiates one versioned AI
  capability contract, and answers pushed `"ai_request"` frames — plus the
  malformed, oversized, replayed, cross-scoped, and Slice 07 project-run
  frames the transport must refuse.

  Every payload comes from the shared personal AI protocol fixtures, so a
  change to the envelope contract breaks the double instead of quietly
  passing through it.
  """
  import Phoenix.ChannelTest

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.PersonalAIProtocolFixtures
  alias SddOrchestratorWeb.{PersonalAIWorkerChannel, PersonalAIWorkerSocket}

  @endpoint SddOrchestratorWeb.Endpoint

  @doc """
  Pairs one real worker to a device workspace through the pairing workflow,
  returning the worker, its raw credential, and the workspace id.
  """
  def pair_worker(opts \\ []) do
    device_workspace_id = Keyword.get(opts, :device_workspace_id, Ecto.UUID.generate())

    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{os_family: "macos", app_version: "1.0.0"})

    %{worker: worker, credential: credential, device_workspace_id: device_workspace_id}
  end

  @doc "Opens one authenticated personal AI socket with a pairing credential."
  def connect_worker(credential),
    do: connect(PersonalAIWorkerSocket, %{"credential" => credential})

  @doc "Opens a socket with whatever connect parameters the caller supplies."
  def connect_with(params), do: connect(PersonalAIWorkerSocket, params)

  @doc """
  Connects and joins one paired worker's workspace topic.

  `:workspace_id` joins a different workspace than the pairing authorized,
  and `:announcement` overrides the negotiated protocol version or
  capabilities.
  """
  def attach(paired, opts \\ []) do
    case connect_worker(paired.credential) do
      {:ok, socket} ->
        join_workspace(
          socket,
          Keyword.get(opts, :workspace_id, paired.device_workspace_id),
          Keyword.get(opts, :announcement, %{})
        )

      :error ->
        :error
    end
  end

  @doc "Joins one workspace's personal AI topic through the socket's own routing."
  def join_workspace(socket, device_workspace_id, overrides \\ %{}) do
    subscribe_and_join(
      socket,
      "personal_ai:#{device_workspace_id}",
      PersonalAIProtocolFixtures.announcement(overrides)
    )
  end

  @doc "Joins an arbitrary topic on the channel, bypassing socket routing."
  def join_topic(socket, topic, payload \\ %{}) do
    subscribe_and_join(socket, PersonalAIWorkerChannel, topic, payload)
  end

  @doc "Answers one pushed request, echoing its request and account scope."
  def respond_to(channel, pushed, result \\ %{"answered" => true}) do
    respond(channel, %{
      "request_id" => pushed["request_id"],
      "account_id" => pushed["account_id"],
      "result" => result
    })
  end

  @doc "Pushes one response frame built from the shared fixtures."
  def respond(channel, overrides \\ %{}),
    do: push(channel, "ai_response", PersonalAIProtocolFixtures.response(overrides))

  @doc "Pushes a response the protocol must refuse: the result field is gone."
  def malformed_response(channel, overrides \\ %{}) do
    push(
      channel,
      "ai_response",
      Map.delete(PersonalAIProtocolFixtures.response(overrides), "result")
    )
  end

  @doc "Pushes a response smuggling one extra top-level field past the allowlist."
  def smuggled_response(channel, field, overrides \\ %{}) do
    push(
      channel,
      "ai_response",
      Map.put(PersonalAIProtocolFixtures.response(overrides), field, "leaked-value")
    )
  end

  @doc "Pushes a response beyond the configured envelope limit."
  def oversized_response(channel, overrides \\ %{}) do
    respond(
      channel,
      Map.put(Map.new(overrides), "result", PersonalAIProtocolFixtures.oversized_result())
    )
  end

  @doc "Pushes one Slice 07 project-run message name the transport must refuse."
  def project_run_command(channel, name), do: push(channel, name, %{"anything" => true})

  @doc "Pushes a message name the transport does not implement."
  def unsupported(channel), do: push(channel, "provision", %{"anything" => true})
end
