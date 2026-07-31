defmodule SddOrchestrator.Delivery.PreviewPresentationTest do
  @moduledoc """
  Proof for presenting preview availability and failure (Task 33, AC-22).

  The criterion is not that a preview can be listed. It is that a reader is
  never told something untrue about one, which breaks into four promises.

  Absence has two causes and they are reported apart: a project with no
  authorized preview path never had one, and a project with a path that has
  verified nothing yet is waiting. A screen that answered both with silence
  would leave "why is there no link?" unanswerable.

  Every stopped state stays distinguishable. `failed`, `timed_out`, `expired`,
  and `superseded` all end a preview, and a reader deciding whether to retry,
  wait, or look elsewhere needs to know which happened — so an expiry is not a
  failure here, and a replaced preview stays on screen rather than disappearing.

  No nonexistent link is ever presented. The link is dropped for every state but
  `ready`, and re-validated even then, because three write-side guards do
  nothing about a link that arrives by a fourth path.

  And none of it touches review readiness, which is proved by comparing the
  feature and its recorded verdict whole across a preview that never existed,
  one still deploying, one that failed, one that timed out, and one that expired.

  Every behaviour runs against both storage authorities, because `specs/05`
  forbids keeping a device-authoritative project's records in the hosted
  database and two implementations are only safe once they answer the same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{PreviewDeployment, PreviewPresentation, VerificationCompletion}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Participation.Revocations
  alias SddOrchestrator.PreviewPresentationFixtures, as: Fixtures
  alias SddOrchestrator.Repo

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path = Path.join(System.tmp_dir!(), "preview-view-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()

    authority =
      case context[:authority] do
        :device -> %DeviceWorkspace{id: device_workspace.id}
        _hosted -> hosted.workspace
      end

    on_exit(Fixtures.configure(hosted.project))

    %{
      authority: authority,
      context: hosted,
      project: hosted.project,
      account: hosted.account,
      actor: hosted.owner_actor,
      feature: feature
    }
  end

  for authority <- [:hosted, :device] do
    describe "whether a preview path exists at all (#{authority})" do
      @describetag authority: authority

      test "a project with no authorized path says so rather than saying nothing [AC-22]", ctx do
        on_exit(Fixtures.unconfigure())

        assert {:ok, summary} = summary(ctx)

        refute summary.configured?
        assert summary.state == "not_configured"
        assert summary.provider == nil
        assert summary.path == nil
        assert summary.deployments == []
      end

      test "a project the preview configuration does not list has no path either", ctx do
        on_exit(SddOrchestrator.PreviewAdapterDouble.install(projects: %{}))

        assert {:ok, summary} = summary(ctx)

        refute summary.configured?
        assert summary.state == "not_configured"
      end

      test "a configured project with nothing deployed yet is waiting, not missing", ctx do
        assert {:ok, summary} = summary(ctx)

        assert summary.configured?
        assert summary.state == "none"
        assert summary.path == Fixtures.path()
        assert summary.provider == "configured-preview"
        assert summary.deployments == []
      end
    end

    describe "the state one deployment reached (#{authority})" do
      @describetag authority: authority

      test "a preview still deploying reports its deadline and no link [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :pending)

        assert {:ok, %{state: "pending", deployments: [item]}} = summary(ctx)

        assert item.status == "pending"
        assert item.open?
        assert item.link == nil
        refute item.link?
        refute item.link_withheld?
        refute item.failed?
        assert item.failure_reason == nil
        assert %DateTime{} = item.timeout_at
      end

      test "a ready preview carries the one safe link and what produced it [AC-22]", ctx do
        %{run: run, attempt: attempt} =
          Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)

        assert {:ok, %{state: "ready", deployments: [item]}} = summary(ctx)

        assert item.status == "ready"
        assert item.link == Fixtures.link()
        assert item.link?
        assert PreviewDeployment.safe_link?(item.link)

        # A preview is non-production, so it has to say which branch, run, and
        # commit it came from or a reader cannot tell what they are looking at.
        assert item.branch == run.branch
        assert item.commit_sha == Fixtures.commit()
        assert item.run_id == run.id
        assert item.attempt_id == attempt.id
        assert item.run_ref != nil
        assert item.attempt_ref != nil
        assert %DateTime{} = item.ready_at
        assert %DateTime{} = item.expires_at
      end

      test "a provider that refused is a failure with a reason and no link [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :failed)

        assert {:ok, %{state: "failed", deployments: [item]}} = summary(ctx)

        assert item.status == "failed"
        assert item.failed?
        assert item.failure_reason == "quota_exhausted"
        assert item.link == nil
        refute item.link?
        refute item.open?
      end

      test "a request nobody answered is a timeout, not a plain failure [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :timed_out)

        assert {:ok, %{state: "timed_out", deployments: [item]}} = summary(ctx)

        assert item.status == "timed_out"
        assert item.failed?
        assert item.failure_reason == "preview_request_timeout"
        assert item.link == nil
      end

      test "an expiry ends the preview without being a failure [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :expired)

        assert {:ok, %{state: "expired", deployments: [item]}} = summary(ctx)

        assert item.status == "expired"
        refute item.failed?
        assert item.failure_reason == nil
        assert item.link == nil
        assert %DateTime{} = item.expires_at
      end

      test "the recorded cleanup state is visible once a release is owed", ctx do
        %{deployment: deployment} =
          Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)

        assert {:ok, %{deployments: [before]}} = summary(ctx)
        assert before.cleanup_state == "none"

        {:ok, _released} =
          SddOrchestrator.Delivery.Previews.cleanup(
            ctx.authority,
            ctx.project.id,
            deployment,
            reason: :project_deleted
          )

        assert {:ok, %{deployments: [item]}} = summary(ctx)
        assert item.cleanup_state == "done"
      end

      test "every recorded status has a presented state", ctx do
        assert Enum.all?(PreviewDeployment.statuses(), &(&1 in PreviewPresentation.states()))
        assert "not_configured" in PreviewPresentation.states()
        assert "none" in PreviewPresentation.states()
        assert {:ok, _summary} = summary(ctx)
      end
    end

    describe "a preview a later commit replaced (#{authority})" do
      @describetag authority: authority

      test "stays visible as replaced beside the one that replaced it [AC-22]", ctx do
        first = Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)
        later = Fixtures.supersede_fixture(ctx.authority, ctx.project, first)

        assert {:ok, %{state: "ready", deployments: [replaced, current]}} = summary(ctx)

        assert replaced.id == first.deployment.id
        assert replaced.status == "superseded"
        assert replaced.superseded?
        refute replaced.current?
        assert replaced.replaced_by_ref != nil

        # Its link goes with it: a replaced preview is not somewhere to send a
        # reader, however recently it served one.
        assert replaced.link == nil

        assert current.id == later.deployment.id
        assert current.current?
        assert current.link == Fixtures.link()
        assert current.commit_sha == Fixtures.later_commit()
      end

      test "the summary follows the current deployment, not the replaced one", ctx do
        first = Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)
        Fixtures.supersede_fixture(ctx.authority, ctx.project, first, :failed)

        assert {:ok, %{state: "failed", deployments: [replaced, current]}} = summary(ctx)

        assert replaced.status == "superseded"
        assert current.status == "failed"
      end
    end

    describe "which previews belong to this feature (#{authority})" do
      @describetag authority: authority

      test "another feature's preview never appears", ctx do
        other = DeliveryFixtures.feature_fixture(ctx.project, ctx.account)
        mine = Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)
        _theirs = Fixtures.preview_fixture(ctx.authority, ctx.project, other, :failed)

        assert {:ok, %{deployments: [item]}} = summary(ctx)
        assert item.id == mine.deployment.id
      end

      test "deployments are listed oldest first, as the store holds them", ctx do
        first = Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :failed)
        second = Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)

        assert {:ok, %{deployments: items}} = summary(ctx)

        assert Enum.map(items, & &1.id) == [first.deployment.id, second.deployment.id]
      end
    end

    describe "who may read a preview (#{authority})" do
      @describetag authority: authority

      test "a stranger to the project is refused [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)
        outsider = SddOrchestrator.AccountsFixtures.account_fixture()
        actor = %{account_id: outsider.id, hosted_identity_id: nil}

        assert {:error, :unauthorized} =
                 PreviewPresentation.summary(
                   ctx.authority,
                   ctx.project.id,
                   actor,
                   ctx.feature.id
                 )
      end

      test "a participant who was removed is refused on the next read [AC-22]", ctx do
        Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)
        actor = ctx.context.participant_actor

        assert {:ok, %{deployments: [_item]}} =
                 PreviewPresentation.summary(
                   ctx.authority,
                   ctx.project.id,
                   actor,
                   ctx.feature.id
                 )

        {:ok, _removed} =
          Revocations.remove(
            ctx.project,
            ctx.account.id,
            ctx.context.identity.hosted_identity.id
          )

        assert {:error, :unauthorized} =
                 PreviewPresentation.summary(
                   ctx.authority,
                   ctx.project.id,
                   actor,
                   ctx.feature.id
                 )
      end

      test "a refused read learns nothing about the project's preview path", _ctx do
        assert PreviewPresentation.unavailable() == %{
                 configured?: false,
                 provider: nil,
                 path: nil,
                 state: "not_configured",
                 deployments: []
               }
      end
    end

    describe "what a preview never reaches (#{authority})" do
      @describetag authority: authority

      test "no provider handle reaches the reader", ctx do
        %{deployment: deployment} =
          Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, :ready)

        assert {:ok, summary} = summary(ctx)
        assert is_binary(deployment.provider_ref)

        refute scan(summary) =~ deployment.provider_ref
        refute scan(summary) =~ "vault://"
      end
    end

    describe "review readiness is independent of the preview (#{authority})" do
      @describetag authority: authority

      for state <- [:pending, :ready, :failed, :timed_out, :expired] do
        test "a #{state} preview leaves the verified completion exactly as it was", ctx do
          context = Fixtures.run_fixture(ctx.authority, ctx.project, ctx.feature)

          DeliveryFixtures.verified_completion_fixture(
            ctx.authority,
            ctx.project,
            context.run,
            context.attempt
          )

          before = truth(ctx, context.run)

          Fixtures.preview_fixture(ctx.authority, ctx.project, ctx.feature, unquote(state))

          assert truth(ctx, context.run) == before
        end
      end

      test "a feature with no preview path at all still holds its verified completion", ctx do
        context = Fixtures.run_fixture(ctx.authority, ctx.project, ctx.feature)

        DeliveryFixtures.verified_completion_fixture(
          ctx.authority,
          ctx.project,
          context.run,
          context.attempt
        )

        before = truth(ctx, context.run)
        on_exit(Fixtures.unconfigure())

        assert {:ok, %{state: "not_configured"}} = summary(ctx)
        assert truth(ctx, context.run) == before
      end
    end
  end

  # The link re-check cannot be reached through a store: the changeset, the
  # device decode, and a check constraint each refuse an unsafe or absent link
  # first. It is proved directly against a record none of them can hold, because
  # the whole point of the fourth guard is the path the first three do not cover.
  describe "the link a reader may be sent to" do
    test "a link carrying a query string is refused however it got stored [AC-22]" do
      item = PreviewPresentation.present(ready_with("https://preview.test/app?token=secret"))

      assert item.status == "ready"
      assert item.link == nil
      refute item.link?
      assert item.link_withheld?
    end

    test "a ready deployment with no link presents none rather than inventing one [AC-22]" do
      item = PreviewPresentation.present(ready_with(nil))

      assert item.link == nil
      assert item.link_withheld?
    end

    test "a loopback link a local worker serves is safe and is shown" do
      item = PreviewPresentation.present(ready_with("http://localhost:4321/preview"))

      assert item.link == "http://localhost:4321/preview"
      refute item.link_withheld?
    end

    test "a stopped deployment holding an otherwise safe link is still sent nowhere" do
      for status <- ~w(failed timed_out expired superseded) do
        item =
          PreviewPresentation.present(%{
            ready_with("https://preview.test/app")
            | status: status,
              failure_reason: "provider_failed"
          })

        assert item.link == nil
        refute item.link_withheld?
      end
    end
  end

  defp ready_with(link) do
    %PreviewDeployment{
      id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      feature_id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      attempt_id: Ecto.UUID.generate(),
      branch: "sdd/preview",
      commit_sha: "a1b2c3d4e5f6a7b8c9d0",
      path: "web",
      provider: "configured-preview",
      link: link,
      status: "ready",
      requested_at: DateTime.utc_now(),
      ready_at: DateTime.utc_now(),
      timeout_at: DateTime.utc_now(),
      cleanup_state: "none",
      state_version: 1
    }
  end

  defp summary(ctx),
    do: PreviewPresentation.summary(ctx.authority, ctx.project.id, ctx.actor, ctx.feature.id)

  # What a preview must never be able to move, compared whole.
  defp truth(ctx, run) do
    feature = Repo.get!(SddOrchestrator.Delivery.Feature, ctx.feature.id)

    {:ok, verified} =
      VerificationCompletion.verified_completion(
        ctx.authority,
        ctx.project.id,
        ctx.feature.id,
        run.id
      )

    %{
      feature: {feature.lifecycle_column, feature.status, feature.state_version},
      verified: {verified.id, verified.payload}
    }
  end

  defp scan(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end
