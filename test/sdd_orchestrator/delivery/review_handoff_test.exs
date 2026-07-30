defmodule SddOrchestrator.Delivery.ReviewHandoffTest do
  @moduledoc """
  Proof for the ready-for-review handoff (Task 5).

  One promise is pinned above every other: a run that proved its work reaches
  `Ready for review` and can never reach `Done`. The agent's reward for a
  complete set of proof is a reviewer, not a finished feature, and the denial is
  asserted directly rather than inferred from the happy path.

  Three further promises are proved beside it. Only a recorded verified
  completion moves anything, so an unproven or refused run leaves the board
  exactly where it was. A preview is irrelevant to the move — absent or failed,
  verified work still becomes reviewable, which is the entire reason previews
  were kept out of the verdict. And the person the review waits on is resolved
  the way the rest of the slice resolves responsibility: the current assignee,
  otherwise the current creator, with the owner as the fail-closed fallback,
  recorded as an account reference and never as an address.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's records in the
  hosted database and two implementations are only safe once they answer the
  same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    Feature,
    Previews,
    ReviewHandoff,
    RunTransitions,
    VerificationCompletion,
    WorkerProtocol
  }

  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.PreviewAdapterDouble
  alias SddOrchestrator.Repo

  @contract ["mix test", "mix credo"]
  @commit "a1b2c3d4e5f6a7b8c9d0"
  @path "web"

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path =
      Path.join(System.tmp_dir!(), "review-handoff-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    developing = seed_feature(authority, hosted.project, feature)
    %{run: run, attempt: attempt} = seed_run(authority, hosted.project, developing)

    %{
      authority: authority,
      hosted: hosted,
      project: hosted.project,
      account: hosted.account,
      feature: developing,
      run: run,
      attempt: attempt
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "handing proven work to a person (#{authority})" do
      @describetag authority: authority

      test "a verified run moves the feature to `Ready for review` [AC-23]", context do
        verify(context)

        assert {:ok, results} = deliver(context)

        assert results.applied?
        assert results.feature.lifecycle_column == "ready_for_review"
        assert results.feature.status == "none"
        assert reload_feature(context).lifecycle_column == "ready_for_review"
      end

      test "the move is recorded as one ordered activity entry [AC-23]", context do
        verified = verify(context)

        {:ok, results} = deliver(context)

        assert results.activity.type == ReviewHandoff.activity_type()
        assert results.activity.actor_kind == "system"
        refute results.activity.actor_account_id
        assert results.activity.run_id == context.run.id
        assert results.activity.attempt_id == context.attempt.id
        assert results.activity.payload["column"] == "ready_for_review"

        # The branch and commit are the ones the gate proved, not a second
        # opinion derived here.
        assert results.activity.payload["branch"] == verified.activity.payload["branch"]
        assert results.activity.payload["commit_sha"] == verified.commit_sha

        # The handoff can only follow the completion it consumed.
        assert results.activity.sequence > verified.activity.sequence
      end

      test "an unverified run is refused and moves nothing [AC-23]", context do
        assert {:error, :not_verified} = deliver(context)

        assert reload_feature(context).lifecycle_column == "in_development"
        assert handoffs(context) == []
      end

      test "a refused completion is not a verified one [AC-23]", context do
        # No check result is recorded, so the gate genuinely refuses.
        refused = verify(context, checks: :skip)
        assert refused.activity.type == VerificationCompletion.refused_activity_type()

        assert {:error, :not_verified} = deliver(context)
        assert reload_feature(context).lifecycle_column == "in_development"
        assert handoffs(context) == []
      end

      test "an incomplete set of proof is refused and moves nothing", context do
        # One contracted check passes; the other never reports.
        record_check(context, "mix test")
        refused = complete(context, 5)

        assert refused.verdict.outcome == :refused
        assert refused.verdict.missing == ["mix credo"]

        assert {:error, :not_verified} = deliver(context)
        assert reload_feature(context).lifecycle_column == "in_development"
      end

      test "a run that already ended terminally hands over nothing", context do
        verify(context)

        {:ok, %{run: canceled}} =
          DeliveryStore.commit(context.authority, context.project.id, [
            {:run, {:transition_run, context.run, "canceled", []}}
          ])

        assert {:error, :run_not_active} =
                 ReviewHandoff.deliver(context.authority, context.project.id, canceled)

        assert reload_feature(context).lifecycle_column == "in_development"
        assert handoffs(context) == []
      end

      test "a feature that never entered development is refused", context do
        drafted = another_feature(context, in_development: false)
        verify(drafted)

        assert {:error, :not_in_development} = deliver(drafted)
        assert reload_feature(drafted).lifecycle_column == "draft"
      end
    end

    describe "what an agent cannot reach (#{authority})" do
      @describetag authority: authority

      test "a complete set of proof buys a reviewer, never `Done` [AC-23]", context do
        verify(context)

        {:ok, results} = deliver(context)

        assert results.feature.lifecycle_column == ReviewHandoff.column()
        refute results.feature.lifecycle_column == "done"
        assert reload_feature(context).lifecycle_column != "done"

        # The handoff has one destination and it is not the end of the board.
        assert ReviewHandoff.column() == "ready_for_review"
      end

      test "the board itself refuses development straight to `Done` [AC-23]", context do
        verify(context)

        refute Feature.legal_transition?("in_development", "done")

        # Not merely absent from the table: offered to the authoritative store as
        # an agent-driven write, it is rejected rather than applied.
        assert {:error, :feature, _refused} =
                 DeliveryStore.commit(context.authority, context.project.id, [
                   {:feature, {:transition_feature, context.feature, "done", []}}
                 ])

        assert reload_feature(context).lifecycle_column == "in_development"
      end

      test "a reviewed feature is still not finished by the run that proved it", context do
        verify(context)
        {:ok, %{feature: reviewable}} = deliver(context)

        # `Ready for review` to `Done` is a legal move, but nothing on this path
        # makes it: handing over again changes nothing at all.
        assert Feature.legal_transition?("ready_for_review", "done")
        assert {:ok, %{applied?: false}} = deliver(context)
        assert reload_feature(context).lifecycle_column == "ready_for_review"
        assert reload_feature(context).state_version == reviewable.state_version
      end
    end

    describe "review responsibility (#{authority})" do
      @describetag authority: authority

      test "resolves to the current assignee and records the reference", context do
        assignee = context.hosted.identity.account
        assigned = another_feature(context, assigned_account_id: assignee.id)
        verify(assigned)

        {:ok, results} = deliver(assigned)

        assert results.responsible.account_id == assignee.id
        assert results.activity.payload["responsible_account_id"] == assignee.id

        # A reference, never a name and never an address.
        assert results.responsible.display_name ==
                 Participation.member_profile(context.project.id, assignee.id).display_name

        refute Jason.encode!(results.activity.payload) =~ "@"
      end

      test "falls back to the creator when nobody is assigned", context do
        verify(context)

        {:ok, results} = deliver(context)

        assert results.responsible.account_id == context.account.id
        assert results.activity.payload["responsible_account_id"] == context.account.id
      end

      test "falls back to the owner when the assignee and creator have left", context do
        departing = context.hosted.identity

        left =
          another_feature(context,
            creator_account: departing.account,
            assigned_account_id: departing.account.id
          )

        verify(left)

        {:ok, _removed} =
          Revocations.remove(context.project, context.account.id, departing.hosted_identity.id)

        {:ok, results} = deliver(left)

        assert results.responsible.account_id == context.account.id
        assert results.responsible.role == :owner
        assert results.activity.payload["responsible_account_id"] == context.account.id
      end

      test "is resolved at handoff time rather than when the work finished", context do
        assignee = context.hosted.identity
        assigned = another_feature(context, assigned_account_id: assignee.account.id)
        verify(assigned)

        # The assignee leaves between the proof and the handoff.
        {:ok, _removed} =
          Revocations.remove(context.project, context.account.id, assignee.hosted_identity.id)

        {:ok, results} = deliver(assigned)

        refute results.responsible.account_id == assignee.account.id
        assert results.responsible.account_id == context.account.id
      end
    end

    describe "readiness does not depend on a preview (#{authority})" do
      @describetag authority: authority

      test "no preview at all still reaches `Ready for review` [AC-23]", context do
        verify(context)

        # Nothing was ever deployed, and nothing could be.
        assert {:error, :preview_not_configured} =
                 Previews.start(context.authority, context.project.id, context.run)

        assert Previews.list(context.authority, context.project.id) == []

        assert {:ok, %{applied?: true, feature: feature}} = deliver(context)
        assert feature.lifecycle_column == "ready_for_review"
      end

      test "a failed preview stays visible and still reaches `Ready for review` [AC-23]",
           context do
        verify(context)

        on_exit(
          PreviewAdapterDouble.install(
            script: :failed,
            projects: %{context.project.id => [@path]}
          )
        )

        assert {:ok, %{deployment: deployment}} =
                 Previews.start(context.authority, context.project.id, context.run, path: @path)

        assert deployment.status == "failed"
        refute deployment.link

        assert {:ok, %{applied?: true, feature: feature}} = deliver(context)
        assert feature.lifecycle_column == "ready_for_review"

        # The failure is still there to read afterwards.
        assert {:ok, %{status: "failed", failure_reason: reason}} =
                 Previews.current(context.authority, context.project.id, context.run.id)

        assert reason
      end
    end

    describe "handing the same completion over twice (#{authority})" do
      @describetag authority: authority

      test "a repeated handoff neither moves the feature nor appends again", context do
        verify(context)

        {:ok, first} = deliver(context)
        assert first.applied?

        assert {:ok, second} = deliver(context)
        refute second.applied?
        assert second.activity.id == first.activity.id

        assert length(handoffs(context)) == 1
        assert reload_feature(context).lifecycle_column == "ready_for_review"
      end

      test "a worker's resent completion cannot move the feature a second time", context do
        verify(context)
        {:ok, _first} = deliver(context)

        # The same claim arrives again under its own identifier, so the gate
        # records a second verified completion. The feature has already left
        # development, and no second handoff follows.
        resent = complete(context, 20)
        assert resent.activity.type == VerificationCompletion.verified_activity_type()

        assert {:error, :not_in_development} = deliver(context)
        assert length(handoffs(context)) == 1
        assert reload_feature(context).lifecycle_column == "ready_for_review"
      end
    end
  end

  describe "device authority creates no hosted copy" do
    @describetag authority: :device

    test "a device handoff leaves the hosted feature row untouched", context do
      verify(context)

      {:ok, %{applied?: true, feature: feature}} = deliver(context)

      assert feature.lifecycle_column == "ready_for_review"

      # The hosted row never moved at all: the device holds its own copy, and
      # every column this feature ever reached was written only there.
      assert Repo.get!(Feature, context.feature.id).lifecycle_column == "draft"
    end
  end

  defp deliver(context),
    do: ReviewHandoff.deliver(context.authority, context.project.id, context.run)

  defp verify(context, attrs \\ []) do
    DeliveryFixtures.verified_completion_fixture(
      context.authority,
      context.project,
      context.run,
      context.attempt,
      Map.new(attrs)
    )
  end

  # One completion claim, sent the way a worker sends one. Used where a test
  # needs a second claim under its own identifier, which the fixture's single
  # ordered send cannot express.
  defp complete(context, sequence) do
    unique = System.unique_integer([:positive])

    envelope = %{
      "type" => "event",
      "protocol_version" => WorkerProtocol.version(),
      "event_id" => "evt-#{unique}",
      "run_id" => context.run.id,
      "command_id" => "cmd-#{unique}",
      "attempt_number" => context.attempt.attempt_number,
      "fence_token" => context.attempt.fence_token,
      "sequence" => sequence,
      "event_type" => VerificationCompletion.event_type(),
      "source" => "worker",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{
        "branch" => context.run.branch,
        "revision_id" => context.attempt.effective_revision_id,
        "commit_sha" => @commit
      }
    }

    {:ok, results} =
      VerificationCompletion.ingest(context.authority, context.project.id, envelope)

    results
  end

  # One contracted check reporting on its own, for the case where the set of
  # proof is genuinely incomplete rather than absent.
  defp record_check(context, name) do
    {:ok, %{evidence: evidence}} =
      DeliveryStore.commit(context.authority, context.project.id, [
        {:evidence,
         {:insert_evidence,
          %{
            project_id: context.project.id,
            feature_id: context.feature.id,
            run_id: context.run.id,
            attempt_id: context.attempt.id,
            command_id: Ecto.UUID.generate(),
            kind: "required_check",
            name: name,
            outcome: "passed",
            command: name,
            exit_code: 0,
            duration_ms: 1_000,
            branch: context.run.branch,
            commit_sha: "a1b2c3d4e5f6a7b8c9d0",
            source: "check",
            recorded_at: DateTime.utc_now(),
            digest: DeliveryFixtures.digest(name),
            redacted: false
          }}}
      ])

    evidence
  end

  # The device authority keeps its own feature copy, so a reload has to ask the
  # store the handoff actually wrote to.
  defp reload_feature(context) do
    case DeliveryStore.fetch_feature(context.authority, context.project.id, context.feature.id) do
      {:ok, feature} -> feature
      :error -> Repo.get!(Feature, context.feature.id)
    end
  end

  defp handoffs(context) do
    context.authority
    |> DeliveryStore.list_activity(context.project.id, context.feature.id)
    |> Enum.filter(&(&1.type == ReviewHandoff.activity_type()))
  end

  # Another feature of the same project, with its own run and its own current
  # attempt, for the cases that need a different creator, assignee, or column.
  defp another_feature(context, attrs) do
    attrs = Map.new(attrs)
    creator = Map.get(attrs, :creator_account, context.account)

    feature =
      DeliveryFixtures.feature_fixture(context.project, creator, %{
        assigned_account_id: Map.get(attrs, :assigned_account_id)
      })

    feature = put_device_feature(context.authority, context.project, feature)

    feature =
      if Map.get(attrs, :in_development, true) do
        develop(context.authority, context.project, feature)
      else
        feature
      end

    %{run: run, attempt: attempt} = seed_run(context.authority, context.project, feature)

    %{context | feature: feature, run: run, attempt: attempt}
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
