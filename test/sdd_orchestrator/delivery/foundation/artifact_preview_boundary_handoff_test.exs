defmodule SddOrchestrator.Delivery.Foundation.ArtifactPreviewBoundaryHandoffTest do
  @moduledoc """
  Handoff proof for `capability:guided-delivery-artifact-preview-boundary` (Task 54).

  The deletion-and-recovery continuation removes what these boundaries hold,
  and deployment governance validates what they disclose. What those children
  may rely on is pinned here: an artifact reference is opaque and never a
  public URL, the artifact store exposes a complete idempotent deletion seam
  with a project-wide sweep, and a preview deployment carries its lifecycle,
  exact verified-commit binding, participant-safe link, and durable cleanup
  state through the shared store reads.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ArtifactStore, DeliveryStore, PreviewDeployment, Previews}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.PreviewAdapterDouble
  alias SddOrchestrator.PreviewPresentationFixtures

  setup do
    context = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(context.project, context.account)

    %{
      authority: context.workspace,
      project: context.project,
      feature: feature
    }
  end

  describe "the private artifact boundary" do
    test "a reference is opaque, scoped to its project, and never a public URL", ctx do
      ref = DeliveryFixtures.artifact_fixture(ctx.authority, ctx.project.id)

      assert String.starts_with?(ref, ArtifactStore.ref_prefix())
      assert ArtifactStore.valid_ref?(ref)
      refute ref =~ "://"
      refute ref =~ "?"

      assert {:ok, artifact} = ArtifactStore.fetch(ctx.authority, ctx.project.id, ref)

      # The returned value has no URL, host, link, or expiry field to leak; a
      # governance child validating "no public artifact URL" reads this shape.
      assert artifact |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:byte_size, :content, :content_type, :digest, :redacted, :ref]

      # Another project's authority-scoped read does not resolve the reference.
      other = DeliveryFixtures.delivery_project_fixture()
      assert {:error, :not_found} = ArtifactStore.fetch(ctx.authority, other.project.id, ref)
    end

    test "deletion is idempotent per item and complete per project", ctx do
      ref_a = DeliveryFixtures.artifact_fixture(ctx.authority, ctx.project.id)

      ref_b =
        DeliveryFixtures.artifact_fixture(ctx.authority, ctx.project.id, %{
          content: DeliveryFixtures.png_bytes("b")
        })

      assert Enum.sort(ArtifactStore.list_refs(ctx.authority, ctx.project.id)) ==
               Enum.sort([ref_a, ref_b])

      assert :ok = ArtifactStore.delete(ctx.authority, ctx.project.id, ref_a)
      assert {:error, :not_found} = ArtifactStore.fetch(ctx.authority, ctx.project.id, ref_a)

      # Removing what is not there is not an error, which is what makes a
      # replayed deletion pass safe.
      assert :ok = ArtifactStore.delete(ctx.authority, ctx.project.id, ref_a)

      # The project-wide sweep says how much it removed, and leaves nothing.
      assert {:ok, 1} = ArtifactStore.delete_project(ctx.authority, ctx.project.id)
      assert ArtifactStore.list_refs(ctx.authority, ctx.project.id) == []
      assert {:error, :not_found} = ArtifactStore.fetch(ctx.authority, ctx.project.id, ref_b)
    end
  end

  describe "the preview deployment boundary" do
    setup ctx do
      on_exit(PreviewPresentationFixtures.configure(ctx.project))
      :ok
    end

    test "the lifecycle and cleanup vocabularies are fixed" do
      assert PreviewDeployment.statuses() ==
               ~w(pending ready failed timed_out expired superseded)

      assert PreviewDeployment.cleanup_states() == ~w(none requested done failed)
    end

    test "a ready deployment binds the exact verified commit and a safe link", ctx do
      %{run: run, deployment: deployment} =
        PreviewPresentationFixtures.preview_fixture(
          ctx.authority,
          ctx.project,
          ctx.feature,
          :ready
        )

      assert deployment.status == "ready"
      assert deployment.commit_sha == PreviewPresentationFixtures.commit()
      assert deployment.branch == run.branch
      assert deployment.link == PreviewPresentationFixtures.link()
      assert String.starts_with?(deployment.link, "https://")
      assert deployment.cleanup_state == "none"

      # The store read the children govern through answers the same record.
      listed =
        DeliveryStore.list_preview_deployments(ctx.authority, ctx.project.id, run_id: run.id)

      assert Enum.map(listed, & &1.id) == [deployment.id]
    end

    test "cleanup is durable, recorded before the provider, and asked exactly once", ctx do
      %{deployment: deployment} =
        PreviewPresentationFixtures.preview_fixture(
          ctx.authority,
          ctx.project,
          ctx.feature,
          :ready
        )

      assert {:ok, %{deployment: released}} =
               Previews.cleanup(ctx.authority, ctx.project.id, deployment)

      assert released.cleanup_state == "done"
      assert released.cleanup_command_id == "preview-cleanup:" <> deployment.id
      assert [command] = PreviewAdapterDouble.cleaned()
      assert command.command_id == released.cleanup_command_id

      # A repeat call answers unchanged and the provider is not contacted again,
      # which is what lets a deletion pass replay safely.
      assert {:ok, %{deployment: unchanged, changed?: false}} =
               Previews.cleanup(ctx.authority, ctx.project.id, released)

      assert unchanged.cleanup_state == "done"
      assert PreviewAdapterDouble.cleaned() == [command]
    end
  end
end
