defmodule SddOrchestratorWeb.InitializationWorkerSocketTest do
  @moduledoc """
  Task 1 proof: worker-authorization accept/refuse at the initialization socket.

  The property under test is that the pairing credential is the whole
  authentication: only a currently active paired worker connects, and a
  missing, malformed, tampered, revoked, or rotated-away credential is
  refused before any channel is reachable.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.InitializationWorkerDouble
  alias SddOrchestratorWeb.InitializationWorkerSocket

  setup do
    %{paired: InitializationWorkerDouble.pair_worker()}
  end

  describe "authentication" do
    test "an active paired credential opens one initialization socket", %{paired: paired} do
      assert {:ok, socket} = InitializationWorkerDouble.connect_worker(paired.credential)
      assert socket.assigns.worker_id == paired.worker.id
      assert socket.assigns.device_workspace_id == paired.device_workspace_id
    end

    test "the socket id names the workspace and worker so one connection is disconnectable",
         %{paired: paired} do
      {:ok, socket} = InitializationWorkerDouble.connect_worker(paired.credential)

      assert InitializationWorkerSocket.id(socket) ==
               "initialization_worker_socket:#{paired.device_workspace_id}:#{paired.worker.id}"
    end

    test "a connection without a credential is refused" do
      assert InitializationWorkerDouble.connect_with(%{}) == :error
    end

    test "a malformed credential is refused" do
      assert InitializationWorkerDouble.connect_worker("not-a-credential") == :error
      assert InitializationWorkerDouble.connect_worker("#{Ecto.UUID.generate()}.") == :error
      assert InitializationWorkerDouble.connect_with(%{"credential" => 42}) == :error
    end

    test "a tampered credential is refused", %{paired: paired} do
      assert InitializationWorkerDouble.connect_worker(paired.credential <> "x") == :error
    end

    test "a revoked worker's credential is refused", %{paired: paired} do
      {:ok, _revoked} = Pairing.revoke_worker(paired.worker)

      assert InitializationWorkerDouble.connect_worker(paired.credential) == :error
    end

    test "rotation refuses the old credential and accepts the new one", %{paired: paired} do
      {:ok, %{credential: rotated}} = Pairing.rotate_credential(paired.worker)

      assert InitializationWorkerDouble.connect_worker(paired.credential) == :error
      assert {:ok, socket} = InitializationWorkerDouble.connect_worker(rotated)
      assert socket.assigns.worker_id == paired.worker.id
    end
  end
end
