defmodule SddOrchestratorWeb.RepositoryAssessmentScanTest.MetadataAdapter do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  @commit "0123456789abcdef0123456789abcdef01234567"

  def commit, do: @commit

  @impl true
  def prepare(request), do: respond(request)

  @impl true
  def revalidate(request), do: respond(request)

  defp respond(request) do
    {:ok,
     %{
       repository_provider: request.repository_provider,
       repository_id: request.repository_id,
       root: request.selected_root,
       commit: @commit
     }}
  end
end

defmodule SddOrchestratorWeb.RepositoryAssessmentScanTest do
  @moduledoc """
  Task 9 proof: pressing `Start assessment` actually assesses.

  Covers AC-07 and AC-08. The screen shows the scan running with a control
  that stops it, a completed scan renders the completed state and the way to
  the execution profile, and every ending that is not a completion leaves the
  person on a step they can start from with a sentence that says why.

  `async: false`, because the scan adapter double swaps application
  environment.
  """

  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments.BindingStore
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryScanAdapterDouble, as: ScanAdapter
  alias SddOrchestratorWeb.RepositoryAssessmentScanTest.MetadataAdapter

  @sha256 String.duplicate("d", 64)

  setup %{conn: conn} do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-scan-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    :ok = BindingStore.reset()

    previous_metadata = Application.get_env(:sdd_orchestrator, :repository_metadata_adapter)
    Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, MetadataAdapter)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(store_path))

      case previous_metadata do
        nil -> Application.delete_env(:sdd_orchestrator, :repository_metadata_adapter)
        adapter -> Application.put_env(:sdd_orchestrator, :repository_metadata_adapter, adapter)
      end
    end)

    on_exit(ScanAdapter.install({:ok, evidence()}))

    %{conn: owner_conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    {:ok, device_workspace} = Devices.establish_workspace()
    worker = reachable_worker(device_workspace.id)

    attempt =
      ProjectsFixtures.device_attempt_ready_for_hosted(device_workspace, workspace,
        worker_id: worker.id
      )

    {:ok, project} = Projects.register_project(workspace, attempt)

    %{
      account: account,
      device_workspace: device_workspace,
      owner_conn: owner_conn,
      project: project,
      worker: worker
    }
  end

  describe "starting the assessment" do
    test "shows the scan running on the chosen worker, with a way to stop it", context do
      ScanAdapter.hold()
      view = start_assessment(context)

      assert has_element?(view, "[data-assessment-scanning]")
      assert view |> element("[data-assessment-state]") |> render() =~ "Scanning"
      assert has_element?(view, "[data-stop-scan]")
      refute has_element?(view, "[data-assessment-completed]")

      ScanAdapter.release()
      render_async(view)

      assert has_element?(view, "[data-assessment-completed]")
    end

    test "asks the worker the person chose, under this binding's own selection", context do
      view = start_assessment(context)
      render_async(view)

      assert [request] = ScanAdapter.requests()
      assert request.worker_ref == context.worker.id
      assert request.device_workspace_id == context.device_workspace.id
      assert request.command.commit == MetadataAdapter.commit()
      assert String.starts_with?(request.selection_ref, "assessment-root-")
    end

    test "no longer says a scan command is not issued", context do
      {:ok, view, _html} = live(context.owner_conn, assessment_path(context))

      view
      |> form("#assessment-binding-form",
        assessment: %{selected_root: ".", worker_ref: context.worker.id, confirmed: "true"}
      )
      |> render_submit()

      html = render_async(view)

      refute html =~ "This task sends no repository scan command."
      assert html =~ "Starting saves the assessment and sends the scan to the worker you chose."
    end
  end

  describe "a completed scan" do
    test "renders the completed state and the way to the execution profile", context do
      view = start_assessment(context)
      render_async(view)

      assert has_element?(view, "[data-assessment-completed]")
      assert view |> element("[data-assessment-state]") |> render() =~ "Completed"

      assert view |> element("[data-profile-link]") |> render() =~
               "/projects/#{context.project.id}/profile"

      assert Repo.get!(RepositoryAssessment, assessment_id()).state == "completed"
    end
  end

  describe "a scan that does not complete" do
    test "an expired binding asks the person to verify it again", context do
      ScanAdapter.script({:error, :selection_expired})

      view = start_assessment(context)
      render_async(view)

      refute has_element?(view, "[data-assessment-completed]")
      refute has_element?(view, "[data-assessment-scanning]")

      assert render(view) =~ "The verified repository binding expired."
      assert render(view) =~ ~s(data-assessment-stage="disclosure")
    end

    test "a refusal names its own reason and leaves a startable screen", context do
      ScanAdapter.script({:error, :stale_commit})

      view = start_assessment(context)
      render_async(view)

      assert render(view) =~ "The repository moved to a different commit"
      assert has_element?(view, "#assessment-binding-form")
    end

    test "a worker that is not there says so in the screen's one wording", context do
      ScanAdapter.script({:error, :worker_unavailable})

      view = start_assessment(context)
      render_async(view)

      assert render(view) =~ "No worker is available right now."
      assert Repo.get!(RepositoryAssessment, assessment_id()).state == "failed"
    end

    test "stopping the scan ends the assessment and leaves nothing running", context do
      ScanAdapter.hold()
      view = start_assessment(context)

      assert has_element?(view, "[data-stop-scan]")
      view |> element("[data-stop-scan]") |> render_click()

      assert render(view) =~ "The scan was stopped."
      refute has_element?(view, "[data-assessment-scanning]")
      assert Repo.get!(RepositoryAssessment, assessment_id()).state == "canceled"

      ScanAdapter.release()
    end
  end

  describe "the device route" do
    test "is unchanged by any of this", context do
      {:ok, device_project} =
        Devices.register_project(%{
          name: "Device assessment",
          repository_fingerprint: ProjectsFixtures.local_repository_metadata().fingerprint,
          status: "connected"
        })

      {:ok, view, html} = live(context.conn, ~p"/local/projects/#{device_project.id}/assessment")

      assert html =~ ~s(data-assessment-stage="disclosure")
      refute has_element?(view, "[data-assessment-scanning]")
      refute has_element?(view, "[data-assessment-completed]")
    end
  end

  defp start_assessment(context) do
    {:ok, view, _html} = live(context.owner_conn, assessment_path(context))

    view
    |> form("#assessment-binding-form",
      assessment: %{selected_root: ".", worker_ref: context.worker.id, confirmed: "true"}
    )
    |> render_submit()

    render_async(view)

    view |> form("#assessment-start-form") |> render_submit()

    view
  end

  defp assessment_path(context), do: ~p"/projects/#{context.project.id}/assessment"

  defp assessment_id do
    assert %RepositoryAssessment{id: id} = Repo.one!(RepositoryAssessment)
    id
  end

  defp evidence do
    %{
      findings: [
        %{category: "check", path: "Makefile", bytes: 12, sha256: @sha256, line_count: 2}
      ],
      structure: [%{path: "Makefile", kind: "file"}],
      stats: %{discovered_paths: 4, inspected_files: 1, bytes_read: 12},
      proposal: %{
        commands: ["make test"],
        required_checks: ["make test"],
        allowed_scope: ["."],
        gaps: ["missing_repository_instructions"],
        conflicts: [],
        multi_root_blockers: []
      },
      provenance: %{source: "fresh_scan", cache_stored: true}
    }
  end

  defp reachable_worker(device_workspace_id) do
    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: "macos",
        os_major: "26",
        app_version: "1.0.0",
        protocol_version: "1"
      })

    {:ok, worker} = Pairing.mark_seen(worker)
    worker
  end
end
