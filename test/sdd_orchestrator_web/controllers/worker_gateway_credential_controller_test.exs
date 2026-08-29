defmodule SddOrchestratorWeb.WorkerGatewayCredentialControllerTest do
  @moduledoc """
  Proof for the authenticated worker gateway-credential exchange (Tasks 1, 4).

  This is the first caller of `WorkerSocket.issue/3`. A worker that already
  holds a per-worker pairing credential exchanges it for a short-lived gateway
  credential.

  Naming a project asks for the project-scoped credential, which names exactly
  the project its device workspace's local-repository binding points at. Naming
  no project asks for the workspace-scoped credential, which a worker paired
  from the app's menu bar can hold before it has any project — it must name that
  worker's own device workspace and nothing else, and it must not become a way
  to reach a project.

  Every refusal — a missing credential, a revoked or rotated-away one, a
  cross-workspace worker, an unknown project, and a malformed project id — is
  answered identically under both exchanges, so none of them can be told apart
  from outside.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import ExUnit.CaptureLog
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

  describe "exchanging a pairing credential with no project named" do
    test "issues a token scoped to the worker's own device workspace", context do
      conn = projectless_request(context.conn, context.credential)

      assert conn.status == 200
      body = json_response(conn, 200)
      assert Map.keys(body) == ["token"]

      assert {:ok, claims} = WorkerSocket.verify(body["token"])

      assert claims == %{
               device_workspace_id: context.device_workspace.id,
               worker_id: context.worker.id
             }
    end

    # The whole point of the projectless exchange is that it cannot answer a
    # question about a project. A token that verified as project-scoped would
    # be exactly that answer.
    test "issues nothing that verifies as project-scoped", context do
      conn = projectless_request(context.conn, context.credential)

      {:ok, claims} = WorkerSocket.verify(json_response(conn, 200)["token"])

      refute Map.has_key?(claims, :project_id)
    end

    test "the project exchange in turn issues nothing that verifies as workspace-scoped",
         context do
      conn = request(context.conn, context.project.id, context.credential)

      {:ok, claims} = WorkerSocket.verify(json_response(conn, 200)["token"])

      assert claims == %{project_id: context.project.id, worker_id: context.worker.id}
      refute Map.has_key?(claims, :device_workspace_id)
    end

    test "issues a workspace token to a worker that has no binding at all" do
      {worker, credential} = available_worker_fixture(%DeviceWorkspace{id: Ecto.UUID.generate()})

      conn = projectless_request(build_conn(), credential)

      assert {:ok, claims} = WorkerSocket.verify(json_response(conn, 200)["token"])
      assert claims.device_workspace_id == worker.device_workspace_id
      assert claims.worker_id == worker.id
    end

    test "answers with private-response hygiene and no cookie", context do
      conn = projectless_request(context.conn, context.credential)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "refuses a request with no credential", context do
      conn =
        context.conn
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{})

      assert refused(conn)
    end

    test "refuses an unknown credential", context do
      conn = projectless_request(context.conn, "#{Ecto.UUID.generate()}.not-a-secret")

      assert refused(conn)
    end

    test "refuses a revoked worker's credential", context do
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      assert refused(projectless_request(context.conn, context.credential))
    end

    test "refuses a credential that was rotated away", context do
      original_credential = context.credential
      {:ok, %{}} = Pairing.rotate_credential(context.worker)

      assert refused(projectless_request(context.conn, original_credential))
    end

    # A named project the caller cannot express is still a question about that
    # project, so it must not be quietly answered with a different scope.
    test "refuses a request naming a malformed project rather than falling back", context do
      conn =
        context.conn
        |> authorize(context.credential)
        |> put_req_header("content-type", "application/json")
        |> post(@path, %{"project_id" => %{"nested" => "value"}})

      assert refused(conn)
    end

    test "answers a missing, unknown, and revoked credential identically", context do
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      missing = projectless_request(build_conn(), nil)
      unknown = projectless_request(build_conn(), "#{Ecto.UUID.generate()}.not-a-secret")
      revoked = projectless_request(build_conn(), context.credential)

      assert missing.status == unknown.status
      assert unknown.status == revoked.status
      assert json_response(missing, 403) == json_response(unknown, 403)
      assert json_response(unknown, 403) == json_response(revoked, 403)
    end

    test "refuses a missing credential identically whether or not a project is named", context do
      projectless = projectless_request(build_conn(), nil)
      project_scoped = request(build_conn(), context.project.id, nil)

      assert projectless.status == project_scoped.status
      assert json_response(projectless, 403) == json_response(project_scoped, 403)
    end
  end

  # These cases capture whatever this request actually emits at the level the
  # suite runs, which is the level a leak would have to survive to be seen.
  # Raising it here is not an option: the process level is combined with the
  # primary level by taking the higher of the two, and the module and
  # application overrides that would win are global and would change what every
  # other async test observes.
  describe "credential hygiene" do
    test "neither the presented credential nor the issued token reaches a log", context do
      {conn, log} = with_log(fn -> projectless_request(context.conn, context.credential) end)

      token = json_response(conn, 200)["token"]

      refute log =~ context.credential
      refute log =~ secret_of(context.credential)
      refute log =~ token
    end

    test "a refused credential does not reach a log or the answer", context do
      {:ok, _revoked} = Pairing.revoke_worker(context.worker)

      {conn, log} = with_log(fn -> projectless_request(context.conn, context.credential) end)

      assert refused(conn)
      refute log =~ context.credential
      refute log =~ secret_of(context.credential)
      refute conn.resp_body =~ secret_of(context.credential)
    end

    test "the project-scoped exchange leaks nothing either", context do
      {conn, log} =
        with_log(fn -> request(context.conn, context.project.id, context.credential) end)

      token = json_response(conn, 200)["token"]

      refute log =~ context.credential
      refute log =~ secret_of(context.credential)
      refute log =~ token
    end

    # The issued token is the only thing the answer may carry, so the presented
    # credential must not come back with it.
    test "the answer carries the issued token and nothing else", context do
      conn = projectless_request(context.conn, context.credential)

      assert Map.keys(json_response(conn, 200)) == ["token"]
      refute conn.resp_body =~ secret_of(context.credential)
    end
  end

  # A pairing credential is `<worker id>.<secret>`; only the second half is
  # secret material, so it is the half a truncated log would still expose.
  defp secret_of(credential) do
    [_worker_id, secret] = String.split(credential, ".", parts: 2)
    secret
  end

  defp request(conn, project_id, credential) do
    conn
    |> authorize(credential)
    |> put_req_header("content-type", "application/json")
    |> post(@path, %{"project_id" => project_id})
  end

  defp projectless_request(conn, credential) do
    conn
    |> authorize(credential)
    |> put_req_header("content-type", "application/json")
    |> post(@path, %{})
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
