defmodule SddOrchestratorWeb.PersonalAIWorkerSocketTest do
  @moduledoc """
  Proof for personal AI worker authentication (Task 7).

  The property under test is that the pairing credential is the whole
  authentication: only a currently active paired worker connects, and a
  missing, malformed, tampered, revoked, or rotated-away credential is
  refused before any channel is reachable.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.PersonalAIWorkerDouble
  alias SddOrchestratorWeb.PersonalAIWorkerSocket

  setup do
    %{paired: PersonalAIWorkerDouble.pair_worker()}
  end

  describe "authentication" do
    test "an active paired credential opens one personal AI socket", %{paired: paired} do
      assert {:ok, socket} = PersonalAIWorkerDouble.connect_worker(paired.credential)
      assert socket.assigns.worker_id == paired.worker.id
      assert socket.assigns.device_workspace_id == paired.device_workspace_id
    end

    test "the socket id names the workspace and worker so one connection is disconnectable",
         %{paired: paired} do
      {:ok, socket} = PersonalAIWorkerDouble.connect_worker(paired.credential)

      assert PersonalAIWorkerSocket.id(socket) ==
               "personal_ai_worker_socket:#{paired.device_workspace_id}:#{paired.worker.id}"
    end

    test "a connection without a credential is refused" do
      assert PersonalAIWorkerDouble.connect_with(%{}) == :error
    end

    test "a malformed credential is refused" do
      assert PersonalAIWorkerDouble.connect_worker("not-a-credential") == :error
      assert PersonalAIWorkerDouble.connect_worker("#{Ecto.UUID.generate()}.") == :error
      assert PersonalAIWorkerDouble.connect_with(%{"credential" => 42}) == :error
    end

    test "a tampered credential is refused", %{paired: paired} do
      assert PersonalAIWorkerDouble.connect_worker(paired.credential <> "x") == :error
    end

    test "a revoked worker's credential is refused", %{paired: paired} do
      {:ok, _revoked} = Pairing.revoke_worker(paired.worker)

      assert PersonalAIWorkerDouble.connect_worker(paired.credential) == :error
    end

    test "rotation refuses the old credential and accepts the new one", %{paired: paired} do
      {:ok, %{credential: rotated}} = Pairing.rotate_credential(paired.worker)

      assert PersonalAIWorkerDouble.connect_worker(paired.credential) == :error
      assert {:ok, socket} = PersonalAIWorkerDouble.connect_worker(rotated)
      assert socket.assigns.worker_id == paired.worker.id
    end
  end
end
