defmodule SddOrchestrator.Delivery.StartPreconditionsTest do
  @moduledoc """
  Proof for the start readout (Task 6 of specs/41-feature-delivery-from-the-ui,
  AC-06).

  A person who cannot start yet has to be told which item stopped them, so
  `Start.preconditions/3` answers every item rather than one verdict. These
  tests pin the five items and their order, that a project bound to a worker
  which is not attached right now does not meet the worker item, and that
  `available?/3` is that same list with nothing left over.
  """
  use SddOrchestrator.DataCase, async: false

  import Ecto.Query

  alias SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.Delivery.{
    GuidedRequirements,
    ProcessingDisclosure,
    Readiness,
    Start,
    Suggestions,
    WorkerAttachment
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments.RepositoryExecutionProfile
  alias SddOrchestrator.SpecificationStore

  @order [:ready, :boundary, :execution_profile, :worker, :ai_connection]

  setup do
    context = DeliveryFixtures.delivery_project_fixture()

    feature =
      DeliveryFixtures.feature_fixture(context.project, context.account, %{
        requirements: :filled
      })

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      owner_account: context.account,
      participant: context.participant_actor
    }
  end

  describe "the readout [AC-06]" do
    test "names every item in the order a person meets them, each with its route", ctx do
      items = preconditions(ctx, ctx.feature)

      assert Enum.map(items, & &1.key) == @order

      assert Enum.map(items, & &1.route) == [
               :readiness,
               :processing_boundary,
               :repository_profile,
               :project_connection,
               :ai_connections
             ]
    end

    test "an item a person may not see at all is unmet, whichever it is", ctx do
      ready = prepared(ctx)
      outsider = %{account_id: Ecto.UUID.generate(), hosted_identity_id: nil}

      assert unmet(preconditions(%{ctx | owner: outsider}, ready)) == @order
      refute Start.available?(ctx.authority, outsider, subject(ctx, ready))
    end
  end

  describe "each unmet item [AC-06]" do
    test "readiness is unmet in draft, met once ready, and unmet again once stale", ctx do
      assert :ready in unmet(preconditions(ctx, ctx.feature))

      ready = promoted(ctx)
      refute :ready in unmet(preconditions(ctx, ready))

      # A verdict about words nobody is looking at any more is not readiness,
      # which is exactly what the person has to be told to check again.
      write_requirements(ctx, "The rule changed after the check.")

      assert :ready in unmet(preconditions(ctx, ready))
    end

    test "the boundary is unmet until this person confirms the one in force", ctx do
      ready = promoted(ctx)

      assert :boundary in unmet(preconditions(ctx, ready))

      confirm_boundary(ctx)

      refute :boundary in unmet(preconditions(ctx, ready))
    end

    test "the execution profile is unmet when the project has approved none", ctx do
      ready = prepared(ctx)

      refute :execution_profile in unmet(preconditions(ctx, ready))

      Repo.delete_all(
        from profile in RepositoryExecutionProfile, where: profile.project_id == ^ctx.project.id
      )

      assert :execution_profile in unmet(preconditions(ctx, ready))
    end

    test "an AI connection is unmet while more than one active one could run this", ctx do
      ready = prepared(ctx)
      worker = bind_worker(ctx.project)

      # Nothing eligible governs the run, so there is nothing to choose between.
      refute :ai_connection in unmet(preconditions(ctx, ready))

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: ctx.owner_account,
        worker: worker
      })

      refute :ai_connection in unmet(preconditions(ctx, ready))

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: ctx.owner_account,
        worker: worker,
        label: "Second Codex"
      })

      assert :ai_connection in unmet(preconditions(ctx, ready))
    end
  end

  describe "the worker item [AC-06]" do
    setup do
      # The dev and test stand-in reports every paired worker as attached, so it
      # is off here: this is the one item whose whole point is that the control
      # plane has a live connection right now.
      previous = Application.get_env(:sdd_orchestrator, :device_worker_stub)
      Application.put_env(:sdd_orchestrator, :device_worker_stub, false)
      on_exit(fn -> Application.put_env(:sdd_orchestrator, :device_worker_stub, previous) end)
    end

    test "is unmet for a project bound to a worker that is not attached now", ctx do
      ready = prepared(ctx)

      assert :worker in unmet(preconditions(ctx, ready)), "an unbound project has no worker"

      bind_worker(ctx.project)

      assert :worker in unmet(preconditions(ctx, ready))
      refute Start.available?(ctx.authority, ctx.owner, subject(ctx, ready))
    end

    test "is met once that worker is attached, and every other item is too", ctx do
      ready = prepared(ctx)
      worker = bind_worker(ctx.project)
      attach(worker)

      assert unmet(preconditions(ctx, ready)) == []
      assert Start.available?(ctx.authority, ctx.owner, subject(ctx, ready))
    end
  end

  describe "the readout and the check [AC-06]" do
    test "agree on every combination, so nothing offered is refused", ctx do
      ready = prepared(ctx)
      worker = bind_worker(ctx.project)

      # Bound but not attached under the stand-in still reads as attached, so
      # the pair is compared with the stand-in off as well as on.
      for stub? <- [true, false] do
        Application.put_env(:sdd_orchestrator, :device_worker_stub, stub?)

        assert Start.available?(ctx.authority, ctx.owner, subject(ctx, ready)) ==
                 (unmet(preconditions(ctx, ready)) == [])
      end

      Application.put_env(:sdd_orchestrator, :device_worker_stub, true)
      attach(worker)

      for feature <- [ctx.feature, ready], actor <- [ctx.owner, ctx.participant] do
        assert Start.available?(ctx.authority, actor, subject(ctx, feature)) ==
                 (unmet(preconditions(%{ctx | owner: actor}, feature)) == [])
      end
    end
  end

  defp preconditions(ctx, feature),
    do: Start.preconditions(ctx.authority, ctx.owner, subject(ctx, feature))

  defp subject(ctx, feature), do: %{project: ctx.project, feature: feature}

  defp unmet(items), do: items |> Enum.reject(& &1.met?) |> Enum.map(& &1.key)

  # Ready with a current verdict and the boundary confirmed: what a person has
  # done before the readout is about anything but the machine.
  defp prepared(ctx) do
    ready = promoted(ctx)
    confirm_boundary(ctx)
    ready
  end

  defp promoted(ctx) do
    {:ok, _assessment} =
      Readiness.assess(ctx.authority, ctx.owner, subject(ctx, ctx.feature))

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        ctx.authority,
        ctx.owner,
        subject(ctx, ctx.feature),
        "ready:#{ctx.feature.id}"
      )

    ready
  end

  defp confirm_boundary(ctx) do
    {:ok, _confirmation} =
      ProcessingDisclosure.confirm(
        ctx.project.id,
        ctx.owner,
        ProcessingDisclosure.describe().digest
      )

    :ok
  end

  defp write_requirements(ctx, rules) do
    {:ok, current} =
      SpecificationStore.get_current(ctx.authority, ctx.project.id, ctx.feature.specification_id)

    parts = Map.put(DeliveryFixtures.filled_requirements(), "rules", rules)

    {:ok, appended} =
      SpecificationStore.append_revision(
        ctx.authority,
        ctx.project.id,
        ctx.feature.specification_id,
        current.revision.id,
        %{
          revision_id: Ecto.UUID.generate(),
          documents: %{
            requirements: GuidedRequirements.render(parts),
            design: current.revision.design_document,
            tasks: current.revision.tasks_document
          }
        }
      )

    appended
  end

  # The routing record the connect path writes, so `Start`'s own lookup finds a
  # bound worker without depending on that module's device-workspace proof.
  defp bind_worker(project) do
    worker = AIRuntimeFixtures.personal_ai_worker_fixture()

    %HostedLocalRepositoryBinding{}
    |> HostedLocalRepositoryBinding.changeset(%{
      project_id: project.id,
      worker_id: worker.id,
      last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    worker
  end

  # A real attachment for that Mac, registered exactly as an authenticated
  # worker channel registers itself. It lives only while this test process does.
  defp attach(worker) do
    {:ok, _pid} =
      WorkerAttachment.attach(worker.device_workspace_id, %{
        worker_id: worker.id,
        protocol_version: 1,
        capabilities: ["run.start"]
      })

    :ok
  end
end
