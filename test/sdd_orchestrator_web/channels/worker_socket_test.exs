defmodule SddOrchestratorWeb.WorkerSocketTest do
  @moduledoc """
  Task 4 proof: the gateway credential carries exactly one scope.

  The property under test is separation. A project-scoped credential and a
  workspace-scoped credential are signed by the same boundary under the same
  salt and the same bounded lifetime, so the only thing keeping them apart is
  the claim shape `verify/1` accepts. Neither may ever verify as the other, and
  a claim that tries to be both must be refused outright.

  Task 5 adds the other half of that separation. Each scope opens a socket
  carrying only what its credential named, and the two are identified in
  separate spaces, so disconnecting one worker's sessions can never reach
  another's.
  """
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  alias SddOrchestrator.Delivery.WorkerProtocol
  alias SddOrchestratorWeb.{Endpoint, WorkerSocket}

  @endpoint SddOrchestratorWeb.Endpoint

  # The salt is repeated here on purpose: these cases forge claims the public
  # API cannot produce, so they must sign them the way a real attacker would.
  @signing_salt "worker-gateway-v1"
  @stale_seconds 30 * 24 * 60 * 60

  describe "project-scoped credentials" do
    test "a bare project id keeps issuing the project claim its callers depend on" do
      project_id = Ecto.UUID.generate()
      worker_id = "worker-#{System.unique_integer([:positive])}"

      token = WorkerSocket.issue(project_id, worker_id)

      assert WorkerSocket.verify(token) == {:ok, %{project_id: project_id, worker_id: worker_id}}
    end

    test "a project claim never carries a device workspace" do
      {:ok, claims} = WorkerSocket.verify(WorkerSocket.issue(Ecto.UUID.generate(), "worker-1"))

      refute Map.has_key?(claims, :device_workspace_id)
    end

    test "a project credential expires on the same bounded lifetime" do
      token =
        WorkerSocket.issue(Ecto.UUID.generate(), "worker-1",
          signed_at: System.system_time(:second) - @stale_seconds
        )

      assert WorkerSocket.verify(token) == :error
    end
  end

  describe "workspace-scoped credentials" do
    test "a device workspace scope issues a claim naming the workspace and the worker" do
      device_workspace_id = Ecto.UUID.generate()
      worker_id = "worker-#{System.unique_integer([:positive])}"

      token = WorkerSocket.issue({:device_workspace, device_workspace_id}, worker_id)

      assert WorkerSocket.verify(token) ==
               {:ok, %{device_workspace_id: device_workspace_id, worker_id: worker_id}}
    end

    test "a workspace claim never carries a project" do
      token = WorkerSocket.issue({:device_workspace, Ecto.UUID.generate()}, "worker-1")
      {:ok, claims} = WorkerSocket.verify(token)

      refute Map.has_key?(claims, :project_id)
    end

    test "a workspace credential expires on the same bounded lifetime" do
      token =
        WorkerSocket.issue({:device_workspace, Ecto.UUID.generate()}, "worker-1",
          signed_at: System.system_time(:second) - @stale_seconds
        )

      assert WorkerSocket.verify(token) == :error
    end

    test "a malformed id is refused even though the signature is valid" do
      assert WorkerSocket.verify(WorkerSocket.issue({:device_workspace, "not a valid id"}, "w")) ==
               :error

      assert WorkerSocket.verify(WorkerSocket.issue({:device_workspace, "ws"}, "worker id")) ==
               :error
    end
  end

  describe "scope separation" do
    test "a claim carrying both scopes verifies as neither" do
      token =
        Phoenix.Token.sign(Endpoint, @signing_salt, %{
          project_id: Ecto.UUID.generate(),
          device_workspace_id: Ecto.UUID.generate(),
          worker_id: "worker-1"
        })

      assert WorkerSocket.verify(token) == :error
    end

    test "a workspace credential opens a socket carrying no project" do
      device_workspace_id = Ecto.UUID.generate()
      token = WorkerSocket.issue({:device_workspace, device_workspace_id}, "worker-1")

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})

      assert socket.assigns.device_workspace_id == device_workspace_id
      assert socket.assigns.worker_id == "worker-1"
      refute Map.has_key?(socket.assigns, :project_id)
    end

    test "a project credential still opens the project socket it names" do
      project_id = Ecto.UUID.generate()
      token = WorkerSocket.issue(project_id, "worker-1")

      assert {:ok, socket} = connect(WorkerSocket, %{"token" => token})

      assert socket.assigns.project_id == project_id
      assert socket.assigns.worker_id == "worker-1"
    end

    test "an unsigned, tampered, or non-binary token is refused under either scope" do
      valid = WorkerSocket.issue({:device_workspace, Ecto.UUID.generate()}, "worker-1")

      assert WorkerSocket.verify("not-a-token") == :error
      assert WorkerSocket.verify(valid <> "x") == :error
      assert WorkerSocket.verify(nil) == :error
      assert WorkerSocket.verify(%{device_workspace_id: "ws", worker_id: "w"}) == :error
    end

    test "a token signed under another salt is refused" do
      token =
        Phoenix.Token.sign(Endpoint, "some-other-salt", %{
          device_workspace_id: Ecto.UUID.generate(),
          worker_id: "worker-1"
        })

      assert WorkerSocket.verify(token) == :error
    end
  end

  describe "socket identity" do
    test "a project socket keeps the identifier its callers already disconnect by" do
      project_id = Ecto.UUID.generate()
      {:ok, socket} = connect(WorkerSocket, %{"token" => WorkerSocket.issue(project_id, "w-1")})

      assert WorkerSocket.id(socket) == "worker_socket:#{project_id}:w-1"
    end

    test "a workspace socket is identified in its own space" do
      device_workspace_id = Ecto.UUID.generate()
      token = WorkerSocket.issue({:device_workspace, device_workspace_id}, "w-1")
      {:ok, socket} = connect(WorkerSocket, %{"token" => token})

      assert WorkerSocket.id(socket) == "worker_socket:workspace:#{device_workspace_id}:w-1"
    end

    test "the same id under the two scopes identifies two different sockets" do
      id = Ecto.UUID.generate()
      {:ok, project} = connect(WorkerSocket, %{"token" => WorkerSocket.issue(id, "w-1")})

      {:ok, workspace} =
        connect(WorkerSocket, %{"token" => WorkerSocket.issue({:device_workspace, id}, "w-1")})

      refute WorkerSocket.id(project) == WorkerSocket.id(workspace)
    end

    test "no accepted id can spell the separator the two spaces are kept apart by" do
      refute WorkerProtocol.valid_id?("workspace:#{Ecto.UUID.generate()}")
      refute WorkerProtocol.valid_id?("worker_socket:workspace")
    end
  end
end
