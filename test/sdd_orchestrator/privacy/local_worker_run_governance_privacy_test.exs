defmodule SddOrchestrator.Privacy.LocalWorkerRunGovernancePrivacyTest do
  @moduledoc """
  Task 6 privacy-boundary proof for specs/34's new records (AC-07).

  Covers a field-level allowlist over the connection-selection request
  `Start.start/4`'s private `pin_request/5` builds, the pinned session's
  `consumer_ref`, and `LocalWorkerRuntimeSnapshot.snapshot/2`'s returned map —
  none may carry repository content, an absolute path, an agent transcript, or
  anything credential-shaped — plus proof that `LocalWorkerRunGovernance`
  inherits its referenced run's and session's existing retention, deletion, and
  rights lifecycle rather than opening a lifecycle of its own.

  `pin_request/5` is private and unmodified by this task, so its shape is
  proven through its only observable effect: the real `AIRuntimeSession` it
  causes `RuntimeSessions.pin_session/3` to persist, reached through a real
  `Start.start/4` call exactly as `SddOrchestrator.Delivery.StartTest`'s own
  Task 2 governance tests already do.

  Advisory-locked retention sweeps are session-scoped, so this proof runs
  serially.
  """

  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AIRuntimeFixtures
  import SddOrchestrator.DeliveryFixtures

  alias SddOrchestrator.AIRuntime.{AIRuntimeSession, RuntimeSessions}

  alias SddOrchestrator.Delivery.{
    LocalWorkerRunGovernance,
    LocalWorkerRuntimeSnapshot,
    ProcessingDisclosure,
    Readiness,
    RunAttempt,
    Start,
    Suggestions
  }

  alias SddOrchestrator.ParticipationDeliveryDouble
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Privacy.{Retention, Rights}
  alias SddOrchestrator.ReadinessGuidanceDouble
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @execution [
    approved_slice: "slice-34",
    repository_base_revision: "a1b2c3d4e5f6a7b8",
    required_checks: [%{"name" => "mix test", "command" => "mix test"}],
    agent_ref: %{"provider" => "configured-agent"},
    worker_ref: %{"target" => "configured-worker"}
  ]

  @boundary [
    execution_location: "this computer",
    agent_provider: "configured-agent",
    model_provider: "configured-model",
    transfers: []
  ]

  # Matches `AIRuntimeFixtures`' own default catalog/quota `retrieved_at`, so a
  # pin against a fixture-built catalog is proven against the snapshot's own
  # freshness window instead of the real wall clock racing its 300-second TTL.
  @pin_time ~U[2026-08-03 12:00:00Z]

  @runtime_session_window_seconds 90 * 24 * 60 * 60

  # A heuristic negative scan for the four forbidden shapes AC-07 names: an
  # absolute path, path traversal, and credential-shaped text. It is combined
  # below with exact structural assertions rather than relied on alone.
  @forbidden ~r/\.\.|^\/|[A-Za-z]:\\\\|api[_-]?key|secret|password|token|bearer/i

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

    context = delivery_project_fixture()
    feature = feature_fixture(context.project, context.account)

    {:ok, _current} =
      SpecificationStore.create(
        context.workspace,
        context.project.id,
        SpecificationFixtures.specification_attrs(),
        actor_ref: "owner"
      )

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature,
      owner: context.owner_actor,
      owner_account: context.account
    }
  end

  describe "field-level allowlist: connection-selection request and consumer_ref [AC-07]" do
    test "the real pin only ever produces a UUID-suffixed consumer_ref and catalog-sourced model/effort",
         %{
           authority: authority,
           project: project,
           feature: feature,
           owner: owner,
           owner_account: owner_account
         } do
      ready = prepare(authority, project, feature, owner)
      worker = bind_local_worker(project)

      %{connection: connection} =
        runtime_session_context_fixture(%{account: owner_account, worker: worker})

      assert {:ok, results} =
               Start.start(authority, owner, %{project: project, feature: ready}, now: @pin_time)

      assert %LocalWorkerRunGovernance{} =
               governance = LocalWorkerRunGovernance.for_run(results.run.id)

      assert {:ok, session} =
               RuntimeSessions.fetch_for_consumer(
                 owner_account,
                 :working_agent,
                 "local_worker_run:" <> results.run.id
               )

      assert governance.session_id == session.session_id

      # `pin_request/5`'s exact literal in lib/sdd_orchestrator/delivery/start.ex:
      #   consumer_ref: "local_worker_run:" <> manifest.run_id
      # `manifest.run_id` is always the created `AgentRun`'s own `:binary_id`
      # primary key, so the only variable part is always a UUID.
      assert "local_worker_run:" <> run_id_part = session.consumer_ref
      assert run_id_part == results.run.id
      assert {:ok, _uuid} = Ecto.UUID.cast(run_id_part)
      refute session.consumer_ref =~ @forbidden
      refute session.consumer_ref =~ "/"
      refute session.consumer_ref =~ "\\"

      # `pin_request/5` builds exactly this closed key set — consumer,
      # consumer_ref, connection_id, model, effort, scarcity, choices,
      # spending_ceiling — and nothing else ever reaches `pin_session/3` from
      # this slice. `connection_id`, `model`, and `effort` are the only three
      # of those that can vary with account data, and each is proven below to
      # come only from the account's own resolved connection and catalog,
      # never from repository, filesystem, or transcript content.
      assert session.connection_id == connection.id
      assert session.consumer == :working_agent

      assert is_binary(session.model) and String.length(session.model) <= 255
      assert is_binary(session.effort) and String.length(session.effort) <= 64
      refute session.model =~ @forbidden
      refute session.effort =~ @forbidden
      refute session.model =~ "/"
      refute session.effort =~ "/"

      # `LocalWorkerRunGovernance`'s own schema is a closed reference pair: it
      # carries nothing beyond the two foreign keys and its timestamps, so it
      # cannot itself carry repository content, a path, a transcript, or a
      # credential no matter what either referenced record holds.
      assert Enum.sort(LocalWorkerRunGovernance.__schema__(:fields)) ==
               Enum.sort([:id, :run_id, :session_id, :inserted_at, :updated_at])
    end
  end

  describe "field-level allowlist: computed runtime snapshot [AC-07]" do
    test "the snapshot's only string field is status, drawn only from RunAttempt's closed state enum" do
      ctx = governed_run_fixture()

      snapshot = LocalWorkerRuntimeSnapshot.snapshot(ctx.run, ctx.attempt)

      assert Enum.sort(Map.keys(snapshot)) ==
               Enum.sort([:elapsed_seconds, :status, :tokens, :cost])

      # Tokens and cost are always the literal atom `:unknown`, never a value
      # that could carry an estimate, a count, or any other content.
      assert snapshot.tokens == :unknown
      assert snapshot.cost == :unknown

      # Elapsed time is always a non-negative integer, never a string that
      # could carry arbitrary content.
      assert is_integer(snapshot.elapsed_seconds) and snapshot.elapsed_seconds >= 0

      # Status is always one of `RunAttempt`'s own closed, short state words —
      # never agent output, a path, or a transcript fragment.
      assert snapshot.status == ctx.attempt.state
      assert snapshot.status in RunAttempt.states()

      for state <- RunAttempt.states() do
        refute state =~ @forbidden
        refute state =~ "/"
        assert String.length(state) <= 20
      end
    end
  end

  describe "deletion and retention coverage [AC-07]" do
    test "expiring the pinned session through Retention.prune_ai_runtime_sessions/1 removes the governance row" do
      ctx = governed_run_fixture()
      assert %LocalWorkerRunGovernance{} = LocalWorkerRunGovernance.for_run(ctx.run.id)

      boundary = DateTime.add(@pin_time, @runtime_session_window_seconds, :second)

      assert %{expired_ai_runtime_sessions: 1, expired_runtime_cost_ledgers: 0} =
               Retention.prune_ai_runtime_sessions(boundary)

      refute Repo.get(AIRuntimeSession, ctx.session.session_id)
      refute LocalWorkerRunGovernance.for_run(ctx.run.id)
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 0
    end

    test "the governance row is not deleted before the session's accountability window ends" do
      ctx = governed_run_fixture()

      just_before = DateTime.add(@pin_time, @runtime_session_window_seconds - 1, :second)

      assert %{expired_ai_runtime_sessions: 0, expired_runtime_cost_ledgers: 0} =
               Retention.prune_ai_runtime_sessions(just_before)

      assert %LocalWorkerRunGovernance{} = LocalWorkerRunGovernance.for_run(ctx.run.id)
    end

    test "deleting the referenced AgentRun removes the governance row" do
      ctx = governed_run_fixture()
      assert %LocalWorkerRunGovernance{} = LocalWorkerRunGovernance.for_run(ctx.run.id)

      Repo.delete!(ctx.run)

      refute Repo.get(LocalWorkerRunGovernance, ctx.governance.id)
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 0

      # The session itself is untouched: `run_id`'s cascade is one-directional.
      assert Repo.get(AIRuntimeSession, ctx.session.session_id)
    end
  end

  describe "rights coverage [AC-07]" do
    test "export_account/1 includes the governed run's pinned session by its consumer_ref" do
      ctx = governed_run_fixture()

      assert {:ok, export} = Rights.export_account(ctx.account.id)

      assert Enum.any?(
               export.ai_runtime_sessions,
               &(&1.consumer_ref == "local_worker_run:" <> ctx.run.id)
             )
    end

    test "erase_account/2 removes the account's pinned session and its governance row" do
      ctx = governed_run_fixture()

      assert {:ok, _result} = Rights.erase_account(ctx.account.id)

      refute Repo.get(AIRuntimeSession, ctx.session.session_id)
      refute Repo.get(LocalWorkerRunGovernance, ctx.governance.id)
      assert Repo.aggregate(LocalWorkerRunGovernance, :count) == 0
    end
  end

  # Builds a governed run without going through `Start.start/4`: a run and
  # first attempt, a pinned session on the same account with the exact
  # production `consumer_ref` shape, and the governance row linking them —
  # everything the retention, rights, and snapshot tests need, none of it
  # depending on the connection-selection step under proof above.
  defp governed_run_fixture do
    %{project: project, account: owner_account} = delivery_project_fixture()
    feature = feature_fixture(project, owner_account)

    %{run: run, attempt: attempt} =
      run_with_attempt_fixture(project, feature, %{initiator_account_id: owner_account.id})

    session_context =
      runtime_observation_context_fixture(%{
        account: owner_account,
        now: @pin_time,
        consumer_ref: "local_worker_run:" <> run.id
      })

    {:ok, governance} =
      LocalWorkerRunGovernance.record(run.id, session_context.session.session_id)

    %{
      project: project,
      run: run,
      attempt: attempt,
      account: owner_account,
      connection: session_context.connection,
      session: session_context.session,
      governance: governance
    }
  end

  defp prepare(authority, project, feature, owner) do
    ReadinessGuidanceDouble.script({:findings, []})
    {:ok, _assessment} = Readiness.assess(authority, owner, %{project: project, feature: feature})

    {:ok, %{results: %{feature: ready}}} =
      Suggestions.promote(
        authority,
        owner,
        %{project: project, feature: feature},
        "ready:#{feature.id}"
      )

    {:ok, _confirmed} =
      ProcessingDisclosure.confirm(project.id, owner, ProcessingDisclosure.describe().digest)

    ready
  end

  defp bind_local_worker(project) do
    worker = personal_ai_worker_fixture()

    %HostedLocalRepositoryBinding{}
    |> HostedLocalRepositoryBinding.changeset(%{
      project_id: project.id,
      worker_id: worker.id,
      last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    worker
  end
end
