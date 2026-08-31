defmodule SddOrchestratorWeb.WorkerWorkspaceChannelBoundProjectTest do
  @moduledoc """
  specs/41-feature-delivery-from-the-ui Task 7 proof: the control-plane half.

  A worker paired from the menu bar attaches for its Mac and holds no project
  connection, so a run for a project it was bound to would reach nobody. These
  tests prove the notice that closes that gap arrives whichever way round the
  two events happen: the binding first and the worker after it, or the worker
  first and the binding after it. An unbind is proved the same way, because a
  worker that keeps serving a project it lost is the same defect reversed.

  What the notice carries is proved too. It names a project id and nothing else,
  because the repository path never leaves the Mac, the repository identity
  belongs to the project record, and the worker exchanges its own credential
  when it opens the project connection.

  `async: false`: the attachment registry is one process for the whole node and
  the joins here read the database through the shared sandbox.
  """

  use SddOrchestrator.DataCase, async: false

  import Phoenix.ChannelTest
  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.WorkerAttachment
  alias SddOrchestrator.DeliveryProtocolFixtures
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Portability.HostedLocalRepositoryConnection
  alias SddOrchestrator.Projects.Project
  alias SddOrchestratorWeb.WorkerSocket

  @endpoint SddOrchestratorWeb.Endpoint

  describe "telling a Mac which projects it serves" do
    test "a worker that attaches after the binding is told about it at the join" do
      context = paired_project()

      {:ok, _binding} = bind(context)

      {:ok, _reply, _channel} = attach(context)

      assert_push "project_bound", payload
      assert payload == %{"project_id" => context.project.id}
    end

    test "a worker already attached is told when the binding is made" do
      context = paired_project()

      {:ok, _reply, _channel} = attach(context)
      refute_push "project_bound", _payload, 100

      {:ok, _connected} = bind(context)

      assert_push "project_bound", payload
      assert payload == %{"project_id" => context.project.id}
    end

    test "a worker is told when the project stops being its own" do
      context = paired_project()

      {:ok, _binding} = bind(context)
      {:ok, _reply, _channel} = attach(context)
      assert_push "project_bound", _bound

      assert {:ok, :disconnected} =
               HostedLocalRepositoryBindings.disconnect(
                 context.personal_workspace,
                 context.project.id
               )

      assert_push "project_unbound", payload
      assert payload == %{"project_id" => context.project.id}
    end

    test "a worker attached for another Mac hears nothing" do
      context = paired_project()
      {:ok, _binding} = bind(context)

      other_mac = Ecto.UUID.generate()
      {:ok, _reply, _channel} = attach(%{context | device_workspace_id: other_mac})

      refute_push "project_bound", _payload, 200
      assert WorkerAttachment.attached(other_mac) != []
    end

    test "a Mac with no binding is told about nothing at all" do
      context = paired_project()

      {:ok, _reply, _channel} = attach(context)

      refute_push "project_bound", _payload, 200
    end
  end

  # --- fixtures -----------------------------------------------------------

  defp paired_project do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())
    {worker, _credential} = available_worker_fixture(device_workspace)

    %{
      personal_workspace: personal_workspace,
      device_workspace: device_workspace,
      device_workspace_id: device_workspace.id,
      project: project,
      worker: worker
    }
  end

  # The real first-connection path, so the notice is proved where the product
  # actually makes a binding rather than at the storage boundary underneath it.
  # The matcher stands in for the worker's own repository proof, which happens
  # on the Mac and returns only a verdict.
  defp bind(context) do
    HostedLocalRepositoryConnection.connect(
      context.personal_workspace,
      context.project.id,
      context.device_workspace,
      context.worker.id,
      fn _repository_id -> {:ok, true} end
    )
  end

  defp attach(context) do
    token =
      WorkerSocket.issue({:device_workspace, context.device_workspace_id}, context.worker.id)

    {:ok, socket} = connect(WorkerSocket, %{"token" => token})

    subscribe_and_join(
      socket,
      "worker_workspace:#{context.device_workspace_id}",
      DeliveryProtocolFixtures.announcement()
    )
  end

  defp local_project_fixture(personal_workspace, repository_id) do
    %Project{}
    |> Project.changeset(%{
      name: "local-project-#{System.unique_integer([:positive])}",
      workspace_id: personal_workspace.id,
      storage_mode: "hosted",
      repository_provider: "local",
      canonical_repository_id: repository_id
    })
    |> Repo.insert!()
  end

  defp available_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
