defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanRunTest.MetadataAdapter do
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

defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanRunTest.ScanAdapter do
  @moduledoc """
  A scripted `RepositoryScanAdapter` for one test process.

  It records the request it was handed, so a test can prove the command and
  the selection reference that actually left the domain, and replays whatever
  outcome the test scripted.
  """
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter

  def install(outcome) do
    Process.put(__MODULE__, %{outcome: outcome, requests: []})
    __MODULE__
  end

  def requests, do: Process.get(__MODULE__, %{requests: []}).requests

  @impl true
  def scan(request) do
    state = Process.get(__MODULE__, %{outcome: {:error, :worker_unavailable}, requests: []})
    Process.put(__MODULE__, %{state | requests: state.requests ++ [request]})
    state.outcome
  end
end

defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanRunTest do
  @moduledoc """
  Task 8 proof: one worker answer becomes one stored terminal assessment.

  Covers AC-10. A completed scan is stored with the envelope this side
  derives, and every other ending is stored as a terminal failure or
  cancellation, so a row left at `pending_scan` means a scan still running and
  nothing else.

  The answer is deliberately not trusted beyond its evidence: the result and
  the envelope are rebuilt from the command the control plane issued, and an
  answer that cannot be made to match it is refused and stored as a failure.
  """

  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.Projects
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.BindingStore
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryAssessments.RepositoryScanRunTest.MetadataAdapter
  alias SddOrchestrator.RepositoryAssessments.RepositoryScanRunTest.ScanAdapter

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @sha256 String.duplicate("d", 64)

  setup do
    store_path =
      Path.join(
        System.tmp_dir!(),
        "repository-scan-run-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()
    :ok = BindingStore.reset()

    account = account_fixture()
    workspace = workspace_fixture(account)
    worker = reachable_worker(device_workspace.id)

    attempt =
      device_attempt_ready_for_hosted(device_workspace, workspace, worker_id: worker.id)

    {:ok, project} = Projects.register_project(workspace, attempt)

    selection_ref = "assessment-#{System.unique_integer([:positive])}"
    authority = {:hosted, account.id}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, preparation} =
      RepositoryAssessments.prepare_binding(
        authority,
        project.id,
        %{
          device_workspace_id: device_workspace.id,
          worker_ref: worker.id,
          selection_ref: selection_ref,
          selected_root: ".",
          scanner_contract_digest: @scanner_digest,
          disclosure_digest: @disclosure_digest,
          confirmed_disclosure_digest: @disclosure_digest
        },
        adapter: MetadataAdapter,
        now: now
      )

    {:ok, assessment} =
      RepositoryAssessments.start_assessment(authority, project.id, preparation, now: now)

    %{
      account: account,
      assessment: assessment,
      authority: authority,
      device_workspace: device_workspace,
      project: project,
      scan_attrs: %{device_workspace_id: device_workspace.id, selection_ref: selection_ref},
      worker: worker
    }
  end

  describe "a completed scan" do
    test "is stored with a proposal envelope the control plane derived", context do
      adapter = ScanAdapter.install({:ok, evidence()})

      assert {:ok, completed} = run(context, adapter)
      assert completed.state == "completed"
      assert completed.id == context.assessment.id

      assert {:ok, review} =
               RepositoryAssessments.profile_review(context.authority, context.project.id)

      assert review.proposal.commands == ["make test"]
      assert review.proposal.required_checks == ["make test"]

      assert {:ok, _profile} =
               RepositoryAssessments.approve_profile(
                 context.authority,
                 context.project.id,
                 review.proposal
               )
    end

    test "asks for the command it issued, under the binding's own selection", context do
      adapter = ScanAdapter.install({:ok, evidence()})

      assert {:ok, _completed} = run(context, adapter)

      assert [request] = ScanAdapter.requests()
      assert request.selection_ref == context.scan_attrs.selection_ref
      assert request.device_workspace_id == context.device_workspace.id
      assert request.worker_ref == context.worker.id
      assert request.command.assessment_id == context.assessment.id
      assert request.command.commit == MetadataAdapter.commit()
    end

    test "keeps the worker's own cache provenance rather than inventing one", context do
      adapter =
        ScanAdapter.install(
          {:ok, evidence(%{provenance: %{source: "complete_cache", cache_stored: true}})}
        )

      assert {:ok, completed} = run(context, adapter)
      assert completed.cache_source == "complete_cache"
    end
  end

  describe "an answer that does not match the command it was sent for" do
    test "is refused and stored as a failure, not as a completion", context do
      adapter =
        ScanAdapter.install(
          {:ok, evidence(%{stats: %{discovered_paths: 0, inspected_files: 0, bytes_read: 0}})}
        )

      assert {:error, :invalid_worker_response} = run(context, adapter)
      assert stored(context).state == "failed"
    end

    test "a proposal that fails its own validation is refused", context do
      for broken <- [
            %{proposal() | allowed_scope: ["../elsewhere"]},
            %{proposal() | required_checks: ["npm test"]},
            %{proposal() | gaps: ["not_a_gap_code"]},
            Map.delete(proposal(), :conflicts)
          ] do
        {:ok, context} = restart_assessment(context)
        adapter = ScanAdapter.install({:ok, evidence(%{proposal: broken})})

        assert {:error, :invalid_worker_response} = run(context, adapter)
        assert stored(context).state == "failed"
      end
    end

    test "the six proposal fields are the worker's word, and this is the boundary that bounds them",
         context do
      # Deriving a proposal needs the repository's own file contents, which
      # deliberately never leave the Mac, so this side cannot recompute one. A
      # proposal that passes its own validation is therefore stored even when
      # the findings beside it do not evidence every command in it. What the
      # boundary does enforce is the validation above: a known command shape,
      # required checks drawn from those commands, a scope inside the root,
      # and allowlisted gap and conflict codes.
      adapter =
        ScanAdapter.install(
          {:ok, evidence(%{proposal: %{proposal() | commands: ["make test", "npm test"]}})}
        )

      assert {:ok, completed} = run(context, adapter)
      assert completed.state == "completed"

      assert {:ok, review} =
               RepositoryAssessments.profile_review(context.authority, context.project.id)

      assert review.proposal.commands == ["make test", "npm test"]
    end

    test "an answer with no provenance is refused", context do
      adapter = ScanAdapter.install({:ok, Map.delete(evidence(), :provenance)})

      assert {:error, :invalid_worker_response} = run(context, adapter)
      assert stored(context).state == "failed"
    end
  end

  describe "every other ending is terminal" do
    test "a refusal is stored as failed under its own allowlisted code", context do
      adapter = ScanAdapter.install({:error, :stale_commit})

      assert {:error, :stale_commit} = run(context, adapter)

      assessment = stored(context)
      assert assessment.state == "failed"
      assert assessment.failure_code == "stale_commit"
    end

    test "an expired folder hold is stored as unavailable and reported by its own name",
         context do
      adapter = ScanAdapter.install({:error, :selection_expired})

      assert {:error, :selection_expired} = run(context, adapter)

      assessment = stored(context)
      assert assessment.state == "failed"
      assert assessment.failure_code == "repository_unavailable"
    end

    test "a lost worker and an unanswered window are both stored as failures", context do
      for reason <- [:worker_unavailable, :invalid_worker_response] do
        {:ok, context} = restart_assessment(context)
        adapter = ScanAdapter.install({:error, reason})

        assert {:error, ^reason} = run(context, adapter)

        assessment = stored(context)
        assert assessment.state == "failed"
        assert assessment.failure_code == "repository_unavailable"
      end
    end

    test "a cancelled scan is stored as canceled", context do
      adapter = ScanAdapter.install({:error, :cancelled})

      assert {:error, :cancelled} = run(context, adapter)
      assert stored(context).state == "canceled"
    end

    test "a new assessment can be started after a failed one", context do
      adapter = ScanAdapter.install({:error, :worker_unavailable})
      assert {:error, :worker_unavailable} = run(context, adapter)

      assert {:ok, context} = restart_assessment(context)
      assert context.assessment.state == RepositoryAssessment.pending_state()

      assert {:ok, completed} = run(context, ScanAdapter.install({:ok, evidence()}))
      assert completed.state == "completed"
    end
  end

  describe "authorization" do
    test "a person who does not own the project is refused with nothing stored and no scan",
         context do
      other = account_fixture()
      adapter = ScanAdapter.install({:ok, evidence()})

      assert {:error, :not_found} =
               RepositoryAssessments.run_assessment(
                 {:hosted, other.id},
                 context.project.id,
                 context.assessment,
                 context.scan_attrs,
                 adapter: adapter
               )

      assert stored(context).state == RepositoryAssessment.pending_state()
    end

    test "the configured default refuses without a worker rather than reaching one", context do
      assert RepositoryAssessments.RepositoryScanAdapter.configured() ==
               RepositoryAssessments.RepositoryScanAdapter.Unavailable

      assert {:error, :worker_unavailable} =
               RepositoryAssessments.run_assessment(
                 context.authority,
                 context.project.id,
                 context.assessment,
                 context.scan_attrs
               )

      assert stored(context).state == "failed"
    end
  end

  describe "a request the domain cannot build" do
    test "is refused before any scan, and stores nothing", context do
      adapter = ScanAdapter.install({:ok, evidence()})

      for attrs <- [
            %{},
            %{device_workspace_id: "not-a-uuid", selection_ref: "selection"},
            %{device_workspace_id: context.device_workspace.id, selection_ref: ""}
          ] do
        assert {:error, :invalid_command} =
                 RepositoryAssessments.run_assessment(
                   context.authority,
                   context.project.id,
                   context.assessment,
                   attrs,
                   adapter: adapter
                 )
      end

      assert ScanAdapter.requests() == []
      assert stored(context).state == RepositoryAssessment.pending_state()
    end
  end

  defp run(context, adapter) do
    RepositoryAssessments.run_assessment(
      context.authority,
      context.project.id,
      context.assessment,
      context.scan_attrs,
      adapter: adapter
    )
  end

  defp stored(context) do
    Repo.get!(RepositoryAssessment, context.assessment.id)
  end

  # A failed assessment is terminal, so the next attempt is a new one: a fresh
  # binding preparation, consumed into a new pending row.
  defp restart_assessment(context) do
    selection_ref = "assessment-#{System.unique_integer([:positive])}"

    {:ok, preparation} =
      RepositoryAssessments.prepare_binding(
        context.authority,
        context.project.id,
        %{
          device_workspace_id: context.device_workspace.id,
          worker_ref: context.worker.id,
          selection_ref: selection_ref,
          selected_root: ".",
          scanner_contract_digest: @scanner_digest,
          disclosure_digest: @disclosure_digest,
          confirmed_disclosure_digest: @disclosure_digest
        },
        adapter: MetadataAdapter
      )

    {:ok, assessment} =
      RepositoryAssessments.start_assessment(context.authority, context.project.id, preparation)

    {:ok,
     %{
       context
       | assessment: assessment,
         scan_attrs: %{
           device_workspace_id: context.device_workspace.id,
           selection_ref: selection_ref
         }
     }}
  end

  defp evidence(overrides \\ %{}) do
    Map.merge(
      %{
        findings: [
          %{
            category: "check",
            path: "Makefile",
            bytes: 12,
            sha256: @sha256,
            line_count: 2
          }
        ],
        structure: [%{path: "Makefile", kind: "file"}],
        stats: %{discovered_paths: 4, inspected_files: 1, bytes_read: 12},
        proposal: proposal(),
        provenance: %{source: "fresh_scan", cache_stored: true}
      },
      overrides
    )
  end

  defp proposal do
    %{
      commands: ["make test"],
      required_checks: ["make test"],
      allowed_scope: ["."],
      gaps: ["missing_repository_instructions"],
      conflicts: [],
      multi_root_blockers: []
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
