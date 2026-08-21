defmodule SddOrchestratorWeb.WorkerGatewayCredentialControllerTest do
  @moduledoc """
  Proof for the authenticated worker gateway-credential exchange (Task 1).

  This is the first caller of `WorkerSocket.issue/3`. A worker that already
  holds a per-worker pairing credential exchanges it for a short-lived,
  project-scoped gateway credential naming exactly the project its device
  workspace's local-repository binding points at. Every refusal — a missing
  credential, a revoked or rotated-away one, a cross-workspace worker, an
  unknown project, and a malformed project id — is answered identically, so
  none of them can be told apart from outside.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Portability.HostedLocalRepositoryBindings
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.WorkerSocket

  @path "/worker/gateway_credentials"

  setup %{conn: conn} do
    account = account_fixture()
    personal_workspace = workspace_fixture(account)
    device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
    project = local_project_fixture(personal_workspace, portable_identifier())

    {worker, credential} = available_worker_fixture(device_workspace)

    {:ok, %{binding: binding}} =
      HostedLocalRepositoryBindings.put_validated_binding(
        personal_workspace,
        project.id,
        device_workspace,
        worker.id,
        project.canonical_repository_id
      )

    %{
      conn: conn,
      account: account,
      personal_workspace: personal_workspace,
      device_workspace: device_workspace,
      project: project,
      worker: worker,
      credential: credential,
      binding: binding
    }
  end

  describe "exchanging a pairing credential for a gateway credential" do
    test "issues a token that verifies to exactly the requesting worker's project", context do
      other_project = local_project_fixture(context.personal_workspace, portable_identifier())

      {:ok, %{}} =
        HostedLocalRepositoryBindings.put_validated_binding(
          context.personal_workspace,
          other_project.id,
          context.device_workspace,
          context.worker.id,
          other_project.canonical_repository_id
        )

      conn = request(context.conn, context.project.id, context.credential)

      assert conn.status == 200
      body = json_response(conn, 200)
      assert Map.keys(body) == ["token"]

      assert {:ok, %{project_id: project_id, worker_id: worker_id}} =
               WorkerSocket.verify(body["token"])

      assert project_id == context.project.id
      assert worker_id == context.worker.id
      assert project_id != other_project.id
    end

    test "answers with private-response hygiene and no cookie", context do
      conn = request(context.conn, context.project.id, context.credential)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "refuses a request with no credential", context do
      conn =
        context.conn
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"project_id" => context.project.id})

      assert refused(conn)
    end

    test "refuses a credential presented with a non-bearer scheme", context do
      conn =
        context.conn
        |> put_req_header("authorization", "Basic #{Base.encode64("worker:secret")}")
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"project_id" => context.project.id})

      assert refused(conn)
    end

    test "refuses a revoked worker's credential", context do
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      conn = request(context.conn, context.project.id, context.credential)

      assert refused(conn)
    end

    test "refuses a credential that was rotated away", context do
      original_credential = context.credential
      {:ok, %{}} = Pairing.rotate_credential(context.worker)

      conn = request(context.conn, context.project.id, original_credential)

      assert refused(conn)
    end

    test "refuses a worker paired to a different device workspace", context do
      foreign_device_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}
      {foreign_worker, foreign_credential} = available_worker_fixture(foreign_device_workspace)

      refute foreign_worker.device_workspace_id == context.device_workspace.id

      conn = request(context.conn, context.project.id, foreign_credential)

      assert refused(conn)
    end

    test "refuses a project with no local-repository binding", context do
      conn = request(context.conn, Ecto.UUID.generate(), context.credential)

      assert refused(conn)
    end

    test "refuses a malformed project id", context do
      conn = request(context.conn, "not-a-uuid", context.credential)

      assert refused(conn)
    end

    test "answers a revoked credential and an unknown project identically", context do
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      revoked = request(build_conn(), context.project.id, context.credential)
      unknown = request(build_conn(), Ecto.UUID.generate(), context.credential)

      assert revoked.status == unknown.status
      assert json_response(revoked, 403) == json_response(unknown, 403)
    end
  end

  defp request(conn, project_id, credential) do
    conn
    |> authorize(credential)
    |> put_req_header("content-type", "application/json")
    |> post(@path, %{"project_id" => project_id})
  end

  defp authorize(conn, nil), do: conn

  defp authorize(conn, credential),
    do: put_req_header(conn, "authorization", "Bearer " <> credential)

  # One refusal answer for every question about whether a credential or project exists.
  defp refused(conn), do: json_response(conn, 403) == %{"error" => "refused"}

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
    {worker, credential} = paired_worker_fixture(device_workspace)
    {:ok, worker} = Pairing.mark_seen(worker)
    {worker, credential}
  end

  defp paired_worker_fixture(device_workspace) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace.id)

    {:ok, %{worker: worker, credential: credential}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {worker, credential}
  end

  defp portable_identifier do
    salt = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    "local-repo:v1:#{salt}:#{digest}"
  end
end
