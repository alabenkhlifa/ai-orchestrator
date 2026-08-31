defmodule SddOrchestrator.Delivery.ReviewContinuationTest do
  @moduledoc """
  Proof that rejected work continues on the same run and branch (Task 35).

  The promise under test is continuity. A rejection does not start a run over: it
  is the same run, the same branch, and the same workspace, with one further
  ordered attempt carrying the feedback and every earlier proof still readable
  [AC-26, AC-35]. So the run identity and branch are compared whole rather than
  field by chosen field, and the prior evidence and the prior verdict are read
  back after the continuation to show that preservation was achieved by not
  touching them.

  The second promise is that the verdict and the continuation are one commit. A
  rejection that cannot commit leaves no verdict, no attempt, and no command, and
  the test forces that failure rather than assuming the transaction holds.

  The third is that an agent never adjudicates the product agreement. When the
  reviewer declares that acting on their feedback would change the approved
  agreement, nothing is dispatched at all: the run pauses on a blocking question,
  its current attempt stays current, and the route back is the accepted answer
  that writes the agreement first.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's records in the
  hosted database and two implementations are only safe once they answer the
  same way. The one exception is named where it appears.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    Answers,
    Blocking,
    BlockingQuestion,
    DeliveryStore,
    ExecutionManifest,
    Feature,
    Review,
    ReviewContinuation,
    ReviewHandoff,
    RunAttempt,
    RunCommand,
    RunTransitions
  }

  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  @contract ["mix test"]
  @commit "a1b2c3d4e5f6a7b8c9d0"
  @later_commit "0f1e2d3c4b5a69788796"
  @feedback "The empty state still shows a spinner"
  @contradiction "Guests should never reach this screen at all"

  setup context do
    root = Path.join(System.tmp_dir!(), "continuation-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    put_env(:worker_workspace_root, root)

    hosted = DeliveryFixtures.delivery_project_fixture()

    # Responsibility resolves to the assignee, which is also who a blocking
    # question routes to, so one person can both reject and answer.
    feature =
      DeliveryFixtures.feature_fixture(hosted.project, hosted.account, %{
        assigned_account_id: hosted.identity.account.id
      })

    path = Path.join(System.tmp_dir!(), "continuation-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    # A device-authoritative project keeps its own approved profile, which is
    # what a continued attempt's manifest is built from under this authority.
    {authority, profile} =
      case context[:authority] do
        :device ->
          workspace = %DeviceWorkspace{id: device_workspace.id}
          {workspace, DeliveryFixtures.approve_device_profile!(workspace, hosted.project)}

        _hosted ->
          {hosted.workspace, hosted.profile}
      end

    developing = seed_feature(authority, hosted.project, feature)
    %{run: run} = seed_run(authority, hosted.project, developing)

    %{
      authority: authority,
      hosted: hosted,
      project: hosted.project,
      owner_actor: hosted.owner_actor,
      responsible: hosted.identity,
      responsible_actor: hosted.participant_actor,
      workspace_root: root,
      feature: developing,
      profile: profile,
      run: run
    }
  end

  for authority <- [:hosted, :device] do
    describe "continuing the same run (#{authority})" do
      @describetag authority: authority

      test "the run and its branch are the run and branch that were rejected [AC-35]",
           context do
        context = ready(context)
        before = run(context)

        {:ok, _results} = reject(context, @feedback)

        # Compared whole: the point is that the run is the same run, not that one
        # chosen field happens to match.
        assert {before.id, before.branch} == {run(context).id, run(context).branch}
      end

      test "the same workspace continues because the run identity does [AC-35]", context do
        context = ready(context)

        {:ok, before} =
          ReviewContinuation.manifest(context.authority, run(context), latest(context))

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        {:ok, after_manifest} =
          ReviewContinuation.manifest(context.authority, run(context), attempt)

        assert Workspace.working_directory(before) == Workspace.working_directory(after_manifest)

        assert {:ok, root} = Workspace.root()
        assert {:ok, directory} = Workspace.working_directory(after_manifest)
        assert String.starts_with?(directory, root)
        assert String.contains?(directory, context.run.id)
      end

      test "the next attempt is the next ordered attempt of the same run [AC-26]", context do
        context = ready(context)
        rejected = latest(context)

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        assert attempt.run_id == context.run.id
        assert attempt.attempt_number == rejected.attempt_number + 1
        assert attempt.continuation_reason == "review_feedback"
        assert attempt.fence_token == rejected.fence_token + 1
        assert RunAttempt.current?(attempt)

        assert {:ok, current} =
                 DeliveryStore.current_attempt(
                   context.authority,
                   project(context),
                   context.run.id
                 )

        assert current.id == attempt.id
      end

      test "the attempt that was rejected is superseded [AC-26]", context do
        context = ready(context)
        rejected = latest(context)

        {:ok, _results} = reject(context, @feedback)

        assert attempt_state(context, rejected.id) == "superseded"
        assert length(attempts(context)) == 2
      end

      test "an attempt that already ended is not superseded a second time", context do
        context = ready(context)
        end_attempt(context, latest(context))
        ended = latest(context)

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        # Ending it again would be offered against the version the first move
        # already bumped, and the store would reject the whole commit.
        assert attempt_state(context, ended.id) == "failed"
        assert attempt.attempt_number == ended.attempt_number + 1
      end

      test "the feature returns to `In development` with no status [AC-26]", context do
        context = ready(context)

        {:ok, results} = reject(context, @feedback)

        assert results.feature.lifecycle_column == "in_development"
        assert results.feature.status == "none"
        assert feature(context).lifecycle_column == "in_development"
      end

      test "the next attempt is bound to the approved execution profile", context do
        context = ready(context)
        rejected = latest(context)

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        # The digest covers every field, so an equal digest is proof that the
        # continued attempt carries the profile's base revision, checks, root,
        # commands, and scope, and nothing the reviewer wrote.
        expected =
          DeliveryFixtures.continuation_manifest(run(context), attempt, context.profile, %{
            "reason" => "review_feedback",
            "prior_attempt_number" => rejected.attempt_number
          })

        assert ExecutionManifest.digest(expected) == attempt.manifest_digest

        assert attempt.required_checks ==
                 DeliveryFixtures.required_check_contract(context.profile.required_checks)
      end

      test "the resume command names the new attempt and the manifest it carries [AC-35]",
           context do
        context = ready(context)

        {:ok, %{attempt: attempt, command: command}} = reject(context, @feedback)

        assert command.operation == "resume"
        assert command.run_id == context.run.id
        assert command.attempt_id == attempt.id
        assert command.manifest_digest == attempt.manifest_digest
        assert [^command] = commands(context)
      end

      test "the manifest continues the rejected attempt on the run's own branch", context do
        context = ready(context)
        rejected = latest(context)
        {:ok, manifest} = ReviewContinuation.manifest(context.authority, run(context), rejected)

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        assert manifest.target_branch == context.run.branch
        assert manifest.attempt_number == attempt.attempt_number
        assert ExecutionManifest.digest(manifest) == attempt.manifest_digest

        assert manifest.continuation == %{
                 "reason" => "review_feedback",
                 "prior_attempt_number" => rejected.attempt_number
               }
      end

      test "the rejection is one activity entry that says what happened next [AC-26]",
           context do
        context = ready(context)

        {:ok, %{activity: activity, attempt: attempt}} = reject(context, @feedback)

        assert activity.type == Review.rejected_activity_type()
        assert activity.actor_kind == "participant"
        assert activity.payload["feedback"] == @feedback
        assert activity.payload["column"] == "in_development"
        assert activity.payload["branch"] == context.run.branch
        assert activity.payload["continuation_reason"] == "review_feedback"
        assert activity.payload["attempt_number"] == attempt.attempt_number
        refute activity.payload["blocked_for_specification"]

        assert length(rejections(context)) == 1
      end

      test "a run already executing continues without leaving `running`", context do
        context = ready(context)
        start_running(context)

        {:ok, %{attempt: attempt}} = reject(context, @feedback)

        # There is no `running` to `running` transition, so an executing run
        # advances its attempt ordering instead of being resumed into the state
        # it is already in.
        assert run(context).state == "running"
        assert run(context).current_attempt_number == attempt.attempt_number
      end
    end

    describe "what a continuation preserves (#{authority})" do
      @describetag authority: authority

      test "prior evidence is still listed and unchanged [AC-35]", context do
        context = ready(context)
        before = evidence(context)
        refute before == []

        {:ok, _results} = reject(context, @feedback)

        assert evidence(context) == before
      end

      test "the verdict that sent the work back is still readable [AC-26]", context do
        context = ready(context)

        {:ok, %{decision: decision}} = reject(context, @feedback)

        held = Review.decision(context.authority, project(context), feature(context))
        assert held.id == decision.id
        assert held.feedback == @feedback
      end

      test "an earlier verdict survives a later one on the same run [AC-35]", context do
        context = ready(context)
        {:ok, %{decision: first}} = reject(context, @feedback)

        # The same run reaches review again on its continued attempt, which is
        # the whole point of continuing rather than starting over.
        context = ready(context, @later_commit)
        {:ok, %{decision: second}} = reject(context, "Still not right")

        assert first.id != second.id
        assert Enum.map(decisions(context), & &1.id) == [first.id, second.id]
        assert Enum.map(decisions(context), & &1.feedback) == [@feedback, "Still not right"]
        assert length(attempts(context)) == 3
      end

      test "the whole feedback is recoverable from the verdict, not the history", context do
        context = ready(context)
        long = String.duplicate("a", 500)

        {:ok, %{decision: decision, activity: activity}} = reject(context, long)

        # The history carries a bounded excerpt because one payload is bounded at
        # 4 KB in total. The verdict record is authoritative for the full text.
        assert String.length(activity.payload["feedback"]) == 400
        assert decision.feedback == long
      end
    end

    describe "deciding the same attempt twice (#{authority})" do
      @describetag authority: authority

      test "a repeated rejection continues the run once [AC-26]", context do
        context = ready(context)

        {:ok, first} = reject(context, @feedback)
        assert first.applied?

        # The screen still holds the feature it rendered, which is exactly what a
        # double-pressed button offers back.
        assert {:ok, second} = reject(context, @feedback)
        refute second.applied?
        refute second.attempt
        refute second.command

        assert length(attempts(context)) == 2
        assert length(commands(context)) == 1
        assert length(decisions(context)) == 1
      end
    end

    describe "a continuation that cannot commit (#{authority})" do
      @describetag authority: authority

      test "leaves no verdict, no attempt, and no command [AC-26]", context do
        context = ready(context)
        before = world(context)

        # The feature moved under the reviewer between render and press, so the
        # transition is offered against a version that no longer exists.
        stale = %{context.feature | state_version: context.feature.state_version + 5}

        assert {:error, _reason} =
                 Review.reject(
                   context.authority,
                   context.responsible_actor,
                   %{project: context.project, feature: stale},
                   @feedback
                 )

        assert world(context) == before
        assert decisions(context) == []
        assert commands(context) == []
        assert length(attempts(context)) == 1
      end
    end

    describe "feedback that contradicts the approved agreement (#{authority})" do
      @describetag authority: authority

      test "nothing is dispatched and the run pauses on a question [AC-26]", context do
        context = ready(context)
        current = latest(context)

        {:ok, results} = reject(context, @contradiction, contradicts_agreement?: true)

        assert results.applied?
        refute results.attempt
        refute results.command
        assert commands(context) == []
        assert length(attempts(context)) == 1

        # The attempt is deliberately left current: an accepted answer resumes
        # this run, and it has nothing to resume without one.
        assert attempt_state(context, current.id) == current.state
        assert RunAttempt.current?(latest(context))
      end

      test "a run nobody dispatched is paused by its question, not by a state move",
           context do
        context = ready(context)

        {:ok, %{question: question}} =
          reject(context, @contradiction, contradicts_agreement?: true)

        # `blocked` is only reachable from `running`, and a run no worker ever
        # picked up has nothing to pause. The open question and the feature's own
        # status are what make the pause visible, in either case.
        assert run(context).state == "pending"
        assert BlockingQuestion.open?(question)
        assert feature(context).status == "blocked"
      end

      test "the run is blocked and the feature shows it in development [AC-26]", context do
        context = ready(context)
        start_running(context)

        {:ok, results} = reject(context, @contradiction, contradicts_agreement?: true)

        assert run(context).state == "blocked"
        assert results.feature.lifecycle_column == "in_development"
        assert results.feature.status == "blocked"
        assert feature(context).status == "blocked"
      end

      test "the question carries the feedback, the branch, and the run's workspace [AC-26]",
           context do
        context = ready(context)

        {:ok, manifest} =
          ReviewContinuation.manifest(context.authority, run(context), latest(context))

        {:ok, %{question: question, activity: activity}} =
          reject(context, @contradiction, contradicts_agreement?: true)

        assert question.question == @contradiction
        assert question.branch == context.run.branch
        assert question.run_id == context.run.id
        assert BlockingQuestion.open?(question)
        assert {:ok, question.workspace_path} == Workspace.working_directory(manifest)

        assert activity.payload["blocked_for_specification"]
        assert activity.payload["question_id"] == question.id
      end

      test "feedback longer than a question stays whole in the verdict", context do
        context = ready(context)
        long = String.duplicate("b", BlockingQuestion.max_question_bytes() + 500)

        {:ok, %{question: question, decision: decision}} =
          reject(context, long, contradicts_agreement?: true)

        assert byte_size(question.question) == BlockingQuestion.max_question_bytes()
        assert decision.feedback == long
      end

      test "a run already waiting on a question is refused rather than given a second",
           context do
        context = ready(context)
        {:ok, _blocked} = reject(context, @contradiction, contradicts_agreement?: true)

        # A different attempt would have to be decided for a second rejection to
        # be reached at all, so this proves the guard rather than the ledger.
        assert {:error, :question_already_open} =
                 ReviewContinuation.plan(context.authority, %{
                   feature: feature(context),
                   run: run(context),
                   attempt: latest(context),
                   feedback: @contradiction,
                   contradicts_agreement?: true
                 })
      end
    end
  end

  # `Blocking.for_feature/3` reads open questions from the hosted database
  # directly, so the answer path is provable in the hosted authority only. That
  # limitation belongs to the question-routing read, not to this continuation.
  describe "returning from a contradictory rejection" do
    @describetag authority: :hosted

    test "an accepted answer produces the next attempt of the same run [AC-35]", context do
      {:ok, _current} =
        SpecificationStore.create(
          context.authority,
          context.project.id,
          SpecificationFixtures.specification_attrs(),
          actor_ref: "owner"
        )

      context = ready(context)
      start_running(context)
      blocked = latest(context)

      {:ok, %{question: question}} =
        reject(context, @contradiction, contradicts_agreement?: true)

      assert {:ok, held} =
               Blocking.for_feature(
                 context.project.id,
                 context.responsible_actor,
                 context.feature.id
               )

      assert held.id == question.id

      {:ok, results} =
        Answers.accept(
          context.authority,
          context.responsible_actor,
          %{project: context.project, feature: feature(context)},
          question.id,
          "Guests are out of scope for this slice"
        )

      assert results.attempt.attempt_number == blocked.attempt_number + 1
      assert results.attempt.continuation_reason == "blocking_answer"
      assert results.command.operation == "resume"
      assert run(context).id == context.run.id
      assert run(context).branch == context.run.branch
    end
  end

  defp reject(context, feedback, opts \\ []) do
    Review.reject(
      context.authority,
      context.responsible_actor,
      %{project: context.project, feature: context.feature},
      feedback,
      opts
    )
  end

  # Verified proof, then the handoff that actually puts the feature in front of a
  # reviewer. Reaching `Ready for review` any other way would prove the fixture
  # rather than the behaviour, and a second cycle has to travel the same road.
  defp ready(context, commit \\ @commit) do
    run = run(context)

    DeliveryFixtures.verified_completion_fixture(
      context.authority,
      context.project,
      run,
      latest(context),
      %{
        commit_sha: commit
      }
    )

    {:ok, %{feature: feature}} = ReviewHandoff.deliver(context.authority, project(context), run)

    %{context | feature: feature}
  end

  # The state a refused continuation must leave untouched, compared whole.
  defp world(context) do
    run = run(context)
    attempt = latest(context)
    feature = feature(context)

    %{
      run: {run.state, run.state_version, run.current_attempt_number},
      attempt: {attempt.state, attempt.attempt_number, attempt.state_version},
      feature: {feature.lifecycle_column, feature.status, feature.state_version},
      activity: Enum.map(activity(context), &{&1.id, &1.type, &1.sequence})
    }
  end

  defp project(context), do: context.project.id

  defp run(context) do
    {:ok, run} = DeliveryStore.fetch_run(context.authority, project(context), context.run.id)
    run
  end

  defp latest(context) do
    {:ok, attempt} =
      DeliveryStore.latest_attempt(context.authority, project(context), context.run.id)

    attempt
  end

  defp feature(context) do
    {:ok, feature} =
      DeliveryStore.fetch_feature(context.authority, project(context), context.feature.id)

    feature
  end

  defp evidence(context),
    do: DeliveryStore.list_evidence(context.authority, project(context), run_id: context.run.id)

  defp decisions(context),
    do: DeliveryStore.list_review_decisions(context.authority, project(context))

  defp activity(context),
    do: DeliveryStore.list_activity(context.authority, project(context), context.feature.id)

  defp rejections(context),
    do: Enum.filter(activity(context), &(&1.type == Review.rejected_activity_type()))

  defp attempt_state(context, attempt_id) do
    context |> attempts() |> Enum.find(&(&1.id == attempt_id)) |> Map.get(:state)
  end

  # Neither store lists a run's attempts or commands for a reader, so the test
  # asks each one the way its own adapter does.
  defp attempts(%{authority: %DeviceWorkspace{}} = context) do
    context
    |> device_values(:attempt, &RunAttempt.from_value/1)
    |> Enum.filter(&(&1.run_id == context.run.id))
    |> Enum.sort_by(& &1.attempt_number)
  end

  defp attempts(context) do
    RunAttempt
    |> Repo.all()
    |> Enum.filter(&(&1.run_id == context.run.id))
    |> Enum.sort_by(& &1.attempt_number)
  end

  defp commands(%{authority: %DeviceWorkspace{}} = context),
    do: context |> device_values(:command, &RunCommand.from_value/1) |> Enum.sort_by(& &1.due_at)

  defp commands(context) do
    RunCommand
    |> Repo.all()
    |> Enum.filter(&(&1.project_id == project(context)))
    |> Enum.sort_by(& &1.due_at)
  end

  defp device_values(context, kind, decode) do
    context
    |> project()
    |> Devices.list_delivery(kind)
    |> Enum.flat_map(fn value ->
      case decode.(value) do
        {:ok, record} -> [record]
        {:error, _reason} -> []
      end
    end)
  end

  # A worker's first accepted event is what moves a run from `pending`; this is
  # the same move without needing a whole event to prove an unrelated point.
  defp start_running(context) do
    {:ok, _results} =
      DeliveryStore.commit(context.authority, project(context), [
        {:run, {:transition_run, run(context), "running", []}}
      ])

    :ok
  end

  defp end_attempt(context, attempt) do
    {:ok, _results} =
      DeliveryStore.commit(context.authority, project(context), [
        {:attempt, {:transition_attempt, attempt, "failed"}}
      ])

    :ok
  end

  defp put_env(key, value) do
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

  # A device-authoritative project's feature lives in the device store, so the
  # world each authority operates on has to be its own.
  defp seed_feature(authority, project, feature) do
    authority
    |> put_device_feature(project, feature)
    |> then(&develop(authority, project, &1))
  end

  defp put_device_feature(%DeviceWorkspace{}, project, feature) do
    {:ok, _written} =
      Devices.commit_delivery(project.id, [
        {:put, :feature, feature.id, Feature.to_value(feature), nil}
      ])

    feature
  end

  defp put_device_feature(_hosted, _project, feature), do: feature

  # A feature reaches `In development` only through `Ready for development`;
  # the transition table is what makes the board's gates real.
  defp develop(authority, project, feature) do
    ready = move(authority, project, feature, "ready_for_development", "readiness_evaluated")
    move(authority, project, ready, "in_development", "run_started")
  end

  defp move(authority, project, feature, column, type) do
    {:ok, %{results: %{feature: moved}}} =
      RunTransitions.apply(authority, %{
        operation_key: "#{column}:#{feature.id}",
        project_id: project.id,
        feature: feature,
        feature_column: column,
        activity: %{
          project_id: project.id,
          feature_id: feature.id,
          actor_kind: "system",
          type: type,
          payload: %{}
        }
      })

    moved
  end

  defp seed_run(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/feature-#{unique}"
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            required_checks: DeliveryFixtures.required_check_contract(@contract),
            fence_token: 1
          }}}
      ])

    %{run: run, attempt: attempt}
  end
end
