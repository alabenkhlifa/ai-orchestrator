defmodule SddOrchestrator.Delivery.StartTest do
  @moduledoc """
  Proof for explicit development start (Task 13).

  Starting is the moment the product commits to consequential, costly work, so
  the tests pin what must be true at that instant rather than what was true
  when the button was drawn: current participation, current readiness against
  the revision actually in play, and a confirmed processing boundary. They also
  pin that nothing starts by itself and that nothing starts twice.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.AIRuntime.{PersonalConnections, RuntimeSessions}
  alias SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    ExecutionManifest,
    Feature,
    LocalWorkerRunGovernance,
    ProcessingDisclosure,
    Readiness,
    RunAttempt,
    RunCommand,
    Start,
    Suggestions
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.PersonalConnectionAdapterDouble
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @execution [
    approved_slice: "slice-07",
    repository_base_revision: "a1b2c3d4e5f6a7b8",
    required_checks: [%{"name" => "mix test", "command" => "mix test"}],
    agent_ref: %{"provider" => "configured-agent"},
    worker_ref: %{"target" => "configured-worker"}
  ]

  # Matches `AIRuntimeFixtures`' own default catalog/quota `retrieved_at`, so a
  # pin against a fixture-built catalog is proven against the snapshot's own
  # freshness window instead of the real wall clock racing its 300-second TTL.
  @runtime_now ~U[2026-08-03 12:00:00Z]

  @boundary [
    execution_location: "this computer",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    transfers: []
  ]

  setup do
    restore = ReadinessGuidanceDouble.install()
    on_exit(restore)

    for {key, value} <- [
          participation_email_delivery: ParticipationDeliveryDouble,
          delivery_execution: @execution,
          processing_boundary: @boundary
        ] do
      previous = Application.get_env(:sdd_orchestrator, key)
      Application.put_env(:sdd_orchestrator, key, value)

      on_exit(fn ->
        if previous do
          Application.put_env(:sdd_orchestrator, key, previous)
        else
          Application.delete_env(:sdd_orchestrator, key)
        end
      end)
    end

    ParticipationDeliveryDouble.succeed()

    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    {:ok, _current} =
      SpecificationStore.create(
        context.workspace,
        context.project.id,
        SpecificationFixtures.specification_attrs(),
        actor_ref: "owner"
      )

    %{
      context: context,
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      participant: context.participant_actor,
      owner_account: context.account
    }
  end

  describe "starting a ready feature [AC-15]" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "creates the run, first attempt, activity, and start command together", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert %AgentRun{} = results.run
      assert %RunAttempt{} = results.attempt
      assert %ActivityEntry{} = results.activity
      assert %RunCommand{} = results.command

      assert results.feature.lifecycle_column == "in_development"
      assert results.run.state == "pending"
      assert results.attempt.attempt_number == 1
      assert results.attempt.continuation_reason == "initial"
      assert results.command.operation == "start"
      assert results.command.manifest_digest == results.attempt.manifest_digest
    end

    test "binds the run to the exact current revision and its own branch", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, current} =
        SpecificationStore.current_snapshot(authority, project.id)
        |> then(fn {:ok, %{specifications: [entry | _]}} ->
          SpecificationStore.get_current(authority, project.id, entry.id)
        end)

      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert results.run.starting_revision_id == current.revision.id
      assert results.run.starting_revision_digest == current.revision.content_digest
      assert results.run.effective_revision_id == results.run.starting_revision_id
      assert results.run.branch == "sdd/run-#{results.run.id}"
      assert results.run.approved_slice == "slice-07"
    end

    test "records who started it, on which branch, against which revision", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert results.activity.type == "run_started"
      assert results.activity.actor_account_id == owner_account.id
      assert results.activity.payload["branch"] == results.run.branch
      assert results.activity.payload["revision_id"] == results.run.starting_revision_id
      assert results.activity.run_id == results.run.id
      assert results.activity.attempt_id == results.attempt.id
    end

    test "any current participant may start, not only the owner", %{
      authority: authority,
      project: project,
      participant: participant,
      ready: ready
    } do
      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(
          project.id,
          participant,
          ProcessingDisclosure.describe().digest
        )

      assert {:ok, results} =
               Start.start(authority, participant, %{project: project, feature: ready})

      assert results.run.state == "pending"
    end

    test "the attempt's manifest digest is the digest of a real manifest", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      {:ok, manifest} =
        ExecutionManifest.new(%{
          "manifest_version" => ExecutionManifest.manifest_version(),
          "project_id" => project.id,
          "feature_id" => ready.id,
          "run_id" => results.run.id,
          "attempt_number" => 1,
          "approved_slice" => "slice-07",
          "starting_revision_id" => results.run.starting_revision_id,
          "starting_revision_digest" => results.run.starting_revision_digest,
          "effective_revision_id" => results.run.effective_revision_id,
          "effective_revision_digest" => results.run.effective_revision_digest,
          "repository_base_revision" => "a1b2c3d4e5f6a7b8",
          "target_branch" => results.run.branch,
          "required_checks" => [%{"name" => "mix test", "command" => "mix test"}],
          "agent_ref" => %{"provider" => "configured-agent"},
          "worker_ref" => %{"target" => "configured-worker"},
          "continuation" => %{"reason" => "initial", "prior_attempt_number" => nil}
        })

      assert ExecutionManifest.digest(manifest) == results.attempt.manifest_digest
    end
  end

  describe "nothing starts by itself [AC-14]" do
    test "becoming ready creates no run, attempt, or command", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      _ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.aggregate(RunAttempt, :count) == 0
      assert Repo.aggregate(RunCommand, :count) == 0
    end

    test "a feature that is not ready cannot be started", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ReadinessGuidanceDouble.script({:findings, [blocker()]})

      {:ok, _assessment} =
        Readiness.assess(authority, owner, %{project: project, feature: feature})

      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(project.id, owner, ProcessingDisclosure.describe().digest)

      assert {:error, :not_ready} =
               Start.start(authority, owner, %{project: project, feature: feature})

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.get!(Feature, feature.id).lifecycle_column == "draft"
    end

    test "an unconfirmed processing boundary blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = promote(%{authority: authority, project: project, feature: feature, owner: owner})

      assert {:error, :boundary_unconfirmed} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "a boundary that changed since confirmation blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      Application.put_env(
        :sdd_orchestrator,
        :processing_boundary,
        Keyword.put(@boundary, :transfers, ["specifications"])
      )

      assert {:error, :boundary_unconfirmed} =
               Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "a revision edited after readiness blocks the start", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      {:ok, %{specifications: [entry | _rest]}} =
        SpecificationStore.current_snapshot(authority, project.id)

      {:ok, current} = SpecificationStore.get_current(authority, project.id, entry.id)

      {:ok, _appended} =
        SpecificationStore.append_revision(
          authority,
          project.id,
          entry.id,
          current.revision.id,
          %{
            revision_id: Ecto.UUID.generate(),
            documents:
              SpecificationFixtures.documents(%{requirements: "# Requirements\\n\\nNew."}),
            actor_ref: "owner"
          }
        )

      assert {:error, :not_ready} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end
  end

  describe "duplicate start" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "a second start while a run is live is rejected", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, results} = Start.start(authority, owner, %{project: project, feature: ready})

      assert {:error, :already_started} =
               Start.start(authority, owner, %{project: project, feature: results.feature})

      assert Repo.aggregate(AgentRun, :count) == 1
      assert Repo.aggregate(RunCommand, :count) == 1
    end

    test "starting again after cancellation creates a different run and branch", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      {:ok, first} = Start.start(authority, owner, %{project: project, feature: ready})

      {:ok, canceled} =
        first.run
        |> AgentRun.transition_changeset("canceled", first.run.state_version)
        |> Repo.update()

      {:ok, back_to_ready} =
        first.feature
        |> Feature.transition_changeset("ready_for_development", first.feature.state_version)
        |> Repo.update()

      assert {:ok, second} =
               Start.start(authority, owner, %{project: project, feature: back_to_ready})

      refute second.run.id == canceled.id
      refute second.run.branch == canceled.branch
      assert Repo.aggregate(AgentRun, :count) == 2
    end
  end

  describe "authorization" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "an outsider cannot start", %{authority: authority, project: project, ready: ready} do
      assert {:error, :unauthorized} =
               Start.start(authority, %{account_id: Ecto.UUID.generate()}, %{
                 project: project,
                 feature: ready
               })

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "a departed participant cannot start", %{
      authority: authority,
      context: context,
      project: project,
      owner_account: owner_account,
      participant: participant,
      ready: ready
    } do
      {:ok, _confirmed} =
        ProcessingDisclosure.confirm(
          project.id,
          participant,
          ProcessingDisclosure.describe().digest
        )

      {:ok, _removed} =
        Revocations.remove(project, owner_account.id, context.identity.hosted_identity.id)

      assert {:error, :unauthorized} =
               Start.start(authority, participant, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "an unsupported authority fails closed", %{project: project, ready: ready} do
      assert {:error, _reason} =
               Start.start(%DeviceWorkspace{id: Ecto.UUID.generate()}, %{account_id: nil}, %{
                 project: project,
                 feature: ready
               })
    end
  end

  describe "eligible personal AI connection resolution [AC-01]" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "starts normally when the project has no bound local worker", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      assert {:ok, _results} = Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "starts normally when the bound worker has no eligible connections", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      bind_local_worker(project)

      assert {:ok, _results} = Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "auto-selects when exactly one eligible connection exists", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      AIRuntimeFixtures.runtime_session_context_fixture(%{
        account: owner_account,
        worker: worker
      })

      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 now: @runtime_now
               )

      assert results.run.state == "pending"
    end

    test "requires an explicit choice with more than one eligible connection", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      %{connection: first} =
        AIRuntimeFixtures.personal_ai_connection_fixture(%{
          account: owner_account,
          worker: worker
        })

      %{connection: second} =
        AIRuntimeFixtures.personal_ai_connection_fixture(%{
          account: owner_account,
          worker: worker,
          label: "Second Codex"
        })

      assert {:error, {:ai_connection_selection_required, eligible_ids}} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Enum.sort(eligible_ids) == Enum.sort([first.id, second.id])
      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "an explicit connection id matching one of the eligible connections proceeds", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: owner_account,
        worker: worker
      })

      %{connection: chosen} =
        AIRuntimeFixtures.runtime_session_context_fixture(%{
          account: owner_account,
          worker: worker,
          label: "Second Codex"
        })

      assert {:ok, _results} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 ai_runtime_connection_id: chosen.id,
                 now: @runtime_now
               )
    end

    test "an explicit connection id that is not eligible still requires a choice", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: owner_account,
        worker: worker
      })

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: owner_account,
        worker: worker,
        label: "Second Codex"
      })

      assert {:error, {:ai_connection_selection_required, _eligible_ids}} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 ai_runtime_connection_id: Ecto.UUID.generate()
               )

      assert Repo.aggregate(AgentRun, :count) == 0
    end

    test "ignores a connection owned by a different account", %{
      authority: authority,
      project: project,
      owner: owner,
      ready: ready
    } do
      worker = bind_local_worker(project)
      AIRuntimeFixtures.personal_ai_connection_fixture(%{worker: worker})

      assert {:ok, _results} = Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "ignores a connection bound to a different worker", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      bind_local_worker(project)
      AIRuntimeFixtures.personal_ai_connection_fixture(%{account: owner_account})

      assert {:ok, _results} = Start.start(authority, owner, %{project: project, feature: ready})
    end

    test "ignores a connection whose revocation has been acknowledged", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      %{connection: connection} =
        AIRuntimeFixtures.personal_ai_connection_fixture(%{
          account: owner_account,
          worker: worker
        })

      {:ok, %{revocation_state: "acknowledged"}} =
        PersonalConnections.request_revocation(owner_account, connection.id,
          adapter: PersonalConnectionAdapterDouble
        )

      assert {:ok, _results} = Start.start(authority, owner, %{project: project, feature: ready})
    end
  end

  describe "pinning a governed run's runtime session [AC-02] [AC-03] [AC-04]" do
    setup ctx, do: %{ready: prepare(ctx)}

    test "pins a session and records the run's governance before it completes", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      %{connection: connection} =
        AIRuntimeFixtures.runtime_session_context_fixture(%{
          account: owner_account,
          worker: worker
        })

      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 now: @runtime_now
               )

      assert %LocalWorkerRunGovernance{} =
               governance =
               LocalWorkerRunGovernance.for_run(results.run.id)

      assert {:ok, session} =
               RuntimeSessions.fetch_for_consumer(
                 owner_account,
                 :working_agent,
                 "local_worker_run:" <> results.run.id
               )

      assert governance.session_id == session.session_id
      assert session.connection_id == connection.id
      assert session.model == "codex-test-model"
      assert session.effort == "medium"
    end

    test "refuses the start and leaves no rows behind when the catalog is unavailable", %{
      authority: authority,
      project: project,
      owner: owner,
      owner_account: owner_account,
      ready: ready
    } do
      worker = bind_local_worker(project)

      AIRuntimeFixtures.personal_ai_connection_fixture(%{
        account: owner_account,
        worker: worker
      })

      assert {:error, _reason} =
               Start.start(authority, owner, %{project: project, feature: ready})

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.aggregate(RunCommand, :count) == 0
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 0
    end

    test "refuses the start and leaves no rows behind when a required spending ceiling is missing",
         %{
           authority: authority,
           project: project,
           owner: owner,
           owner_account: owner_account,
           ready: ready
         } do
      worker = bind_local_worker(project)

      AIRuntimeFixtures.model_catalog_snapshot_fixture(%{
        connection_fixture:
          AIRuntimeFixtures.personal_ai_connection_fixture(%{
            account: owner_account,
            worker: worker,
            authentication_mode: "api_key"
          })
      })

      assert {:error, :spending_ceiling_required} =
               Start.start(authority, owner, %{project: project, feature: ready},
                 now: @runtime_now
               )

      assert Repo.aggregate(AgentRun, :count) == 0
      assert Repo.aggregate(RunCommand, :count) == 0
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 0
    end

    test "re-pinning the same run's consumer reference is idempotent", %{
      project: project,
      feature: feature,
      owner_account: owner_account
    } do
      run_id = DeliveryFixtures.run_fixture(project, feature).id

      context = AIRuntimeFixtures.runtime_session_context_fixture(%{account: owner_account})

      request = %{
        consumer: :working_agent,
        consumer_ref: "local_worker_run:" <> run_id,
        connection_id: context.connection.id,
        model: "codex-test-model",
        effort: "medium",
        scarcity: :standard,
        choices: [],
        spending_ceiling: nil
      }

      assert {:ok, first} = RuntimeSessions.pin_session(owner_account, request, now: @runtime_now)

      assert {:ok, second} =
               RuntimeSessions.pin_session(owner_account, request, now: @runtime_now)

      assert first.session_id == second.session_id

      assert {:ok, governance_a} = LocalWorkerRunGovernance.record(run_id, first.session_id)
      assert {:ok, governance_b} = LocalWorkerRunGovernance.record(run_id, second.session_id)
      assert governance_a.id == governance_b.id
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 1
    end
  end

  describe "availability" do
    test "is false until ready, confirmed, and in the right column", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner
    } do
      refute Start.available?(authority, owner, %{project: project, feature: feature})

      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      assert Start.available?(authority, owner, %{project: project, feature: ready})
    end

    test "is false for a participant who has not confirmed the boundary", %{
      authority: authority,
      project: project,
      feature: feature,
      owner: owner,
      participant: participant
    } do
      ready = prepare(%{authority: authority, project: project, feature: feature, owner: owner})

      refute Start.available?(authority, participant, %{project: project, feature: ready})
    end
  end

  # Assess with no blockers, promote to ready, and confirm the boundary — the
  # three things a person does before the start button is real.
  defp prepare(ctx) do
    ready = promote(ctx)

    {:ok, _confirmed} =
      ProcessingDisclosure.confirm(
        ctx.project.id,
        ctx.owner,
        ProcessingDisclosure.describe().digest
      )

    ready
  end

  defp promote(%{authority: authority, project: project, feature: feature, owner: owner}) do
    ReadinessGuidanceDouble.script({:findings, []})
    {:ok, _assessment} = Readiness.assess(authority, owner, %{project: project, feature: feature})

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        authority,
        owner,
        %{project: project, feature: feature},
        "ready:#{feature.id}"
      )

    ready
  end

  # Binds a real, active local worker to the project exactly the way
  # `HostedLocalRepositoryBindings.put_validated_binding/6` persists it, so
  # `Start`'s own lookup (`Repo.get(HostedLocalRepositoryBinding, project.id)`)
  # finds it without depending on that module's own device-workspace proof.
  defp bind_local_worker(project) do
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

  defp blocker do
    %{
      "id" => "missing-users",
      "category" => "missing",
      "blocking" => true,
      "summary" => "Nobody says who this is for.",
      "explanation" => "Name the people who will use this."
    }
  end
end
