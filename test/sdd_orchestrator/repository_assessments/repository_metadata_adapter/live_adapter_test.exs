defmodule SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.LiveAdapterTest do
  @moduledoc """
  Proves `RepositoryAssessments.prepare_binding/4` and `.start_assessment/4`
  reach an actual worker through the real, worker-backed adapter
  (`RepositoryMetadataAdapter.Worker`) rather than through a test fake, for
  both a hosted and a device authority. No real worker exists in a test, so
  `RepositoryMetadataTransportDouble` stands in for the Mac-scoped attachment
  and this file scripts its answers directly, mirroring the pattern
  `RepositoryMetadataTest` uses to drive `RepositoryMetadata.inspect/2`.
  """

  # `async: false`: the double swaps application environment, and both the
  # metadata request server and the device store are single processes shared
  # by the whole node.
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceStore.Local, Pairing}
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryAssessments.{AssessmentStore, BindingStore, RepositoryMetadataAdapter}
  alias SddOrchestrator.RepositoryMetadata
  alias SddOrchestrator.RepositoryMetadata.MetadataRequest
  alias SddOrchestrator.RepositoryMetadataTransportDouble, as: TransportDouble

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.ProjectsFixtures

  @scanner_digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)
  @commit "0123456789abcdef0123456789abcdef01234567"

  setup do
    on_exit(TransportDouble.install())

    store_path =
      Path.join(
        System.tmp_dir!(),
        "live-adapter-#{System.unique_integer([:positive])}/store.dets"
      )

    start_supervised!({Local, path: store_path})
    on_exit(fn -> File.rm_rf!(Path.dirname(store_path)) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    {:ok, device_project} =
      Devices.register_project(%{
        name: "Live adapter device project",
        repository_fingerprint: "live-adapter-device-fingerprint",
        status: "connected"
      })

    :ok = BindingStore.reset()

    account = account_fixture()
    workspace = workspace_fixture(account)
    hosted_project = registered_project(workspace)
    worker = reachable_worker(device_workspace.id)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %{
      device_project: device_project,
      device_workspace: device_workspace,
      hosted_project: hosted_project,
      now: now,
      worker: worker,
      workspace: workspace,
      account: account
    }
  end

  test "a hosted binding reaches the live adapter and start_assessment persists in the hosted store",
       context do
    assert {:ok, preparation} =
             prepare(hosted_authority(context), context.hosted_project.id, context)

    assert {:ok, assessment} =
             start_assessment(
               hosted_authority(context),
               context.hosted_project.id,
               preparation,
               context
             )

    assert assessment.project_id == context.hosted_project.id
    assert assessment.state == "pending_scan"
    assert AssessmentStore.count(hosted_authority(context), context.hosted_project.id) == 1

    # One push for prepare, one for the revalidate that start_assessment
    # issues, both carrying the real project's identity: the double was
    # reached through the real adapter, not a test fake.
    assert [prepare_request, revalidate_request] = TransportDouble.pushed()
    assert prepare_request.repository_provider == context.hosted_project.repository_provider
    assert prepare_request.repository_id == context.hosted_project.canonical_repository_id
    assert revalidate_request.repository_provider == prepare_request.repository_provider
    assert revalidate_request.repository_id == prepare_request.repository_id
  end

  test "a device binding reaches the live adapter and start_assessment persists in the device store",
       context do
    assert {:ok, preparation} =
             prepare(device_authority(context), context.device_project.id, context)

    assert {:ok, assessment} =
             start_assessment(
               device_authority(context),
               context.device_project.id,
               preparation,
               context
             )

    assert assessment.project_id == context.device_project.id
    assert Devices.repository_assessment_count(context.device_project.id) == 1

    assert [prepare_request, revalidate_request] = TransportDouble.pushed()
    assert prepare_request.repository_provider == context.device_project.repository_provider
    assert prepare_request.repository_id == context.device_project.repository_id
    assert revalidate_request.repository_provider == prepare_request.repository_provider
    assert revalidate_request.repository_id == prepare_request.repository_id
  end

  defp hosted_authority(context), do: {:hosted, context.account.id}
  defp device_authority(context), do: {:device, context.device_workspace}

  # Calls `prepare_binding/4` with the live adapter given explicitly as an
  # opt, exactly as `RepositoryAssessmentTest`'s own `prepare/4` helper passes
  # its fake `Adapter` -- the global config is never touched for this test.
  # `prepare_binding/4` blocks the calling process inside `RepositoryMetadata`,
  # so it runs in a `Task` and this helper answers the double before awaiting it.
  defp prepare(authority, project_id, context) do
    before_count = length(TransportDouble.pushed())

    task =
      Task.async(fn ->
        RepositoryAssessments.prepare_binding(
          authority,
          project_id,
          %{
            device_workspace_id: context.device_workspace.id,
            worker_ref: context.worker.id,
            selection_ref: "live-adapter-#{System.unique_integer([:positive])}",
            selected_root: ".",
            scanner_contract_digest: @scanner_digest,
            disclosure_digest: @disclosure_digest,
            confirmed_disclosure_digest: @disclosure_digest
          },
          adapter: RepositoryMetadataAdapter.Worker,
          now: context.now
        )
      end)

    answer_next(before_count)
    Task.await(task)
  end

  # `start_assessment/4` reuses the adapter recorded by `prepare/3` above (via
  # `BindingStore.put/3`), so it reaches the live adapter without naming it
  # again, and also blocks inside `RepositoryMetadata` for its own revalidate.
  defp start_assessment(authority, project_id, preparation, context) do
    before_count = length(TransportDouble.pushed())

    task =
      Task.async(fn ->
        RepositoryAssessments.start_assessment(authority, project_id, preparation,
          now: context.now
        )
      end)

    answer_next(before_count)
    Task.await(task)
  end

  defp answer_next(before_count) do
    request = wait_for_next_pushed(before_count)

    attachment = %{
      device_workspace_id: request.device_workspace_id,
      worker_id: request.worker_id
    }

    assert :ok =
             RepositoryMetadata.answer(attachment, %{
               "request_id" => request.id,
               "outcome" => "metadata",
               "repository_provider" => request.repository_provider,
               "repository_id" => request.repository_id,
               "root" => request.selected_root,
               "commit" => @commit
             })
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

  defp wait_for_next_pushed(before_count) do
    assert wait_until(fn -> length(TransportDouble.pushed()) > before_count end)
    %MetadataRequest{} = List.last(TransportDouble.pushed())
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> true
      attempts <= 0 -> false
      true -> wait_again(check, attempts)
    end
  end

  defp wait_again(check, attempts) do
    Process.sleep(10)
    wait_until(check, attempts - 1)
  end
end
