defmodule SddOrchestrator.InitializationWorkerDouble do
  @moduledoc """
  A paired worker for initialization-dispatch tests.

  It pairs a real worker through `SddOrchestrator.Devices.Pairing`, dials in
  with the credential the pairing returned once, and joins one device
  workspace's initialization topic through the socket's own routing.
  """
  import Phoenix.ChannelTest

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.InitializationDispatchFixtures, as: Fixtures
  alias SddOrchestratorWeb.{InitializationWorkerChannel, InitializationWorkerSocket}

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

  @doc "Opens one authenticated initialization socket with a pairing credential."
  def connect_worker(credential),
    do: connect(InitializationWorkerSocket, %{"credential" => credential})

  @doc "Opens a socket with whatever connect parameters the caller supplies."
  def connect_with(params), do: connect(InitializationWorkerSocket, params)

  @doc """
  Connects and joins one paired worker's device workspace initialization topic.

  `:workspace_id` joins a different workspace than the pairing authorized,
  and `:announcement` overrides the negotiated capability grants.
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

  @doc "Joins one workspace's initialization topic through the socket's own routing."
  def join_workspace(socket, device_workspace_id, overrides \\ %{}) do
    subscribe_and_join(
      socket,
      "initialization:#{device_workspace_id}",
      Fixtures.announcement(overrides)
    )
  end

  @doc "Joins an arbitrary topic on the channel, bypassing socket routing."
  def join_topic(socket, topic, payload \\ %{}) do
    subscribe_and_join(socket, InitializationWorkerChannel, topic, payload)
  end
end
