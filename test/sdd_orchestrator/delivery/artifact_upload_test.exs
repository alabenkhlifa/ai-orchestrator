defmodule SddOrchestrator.Delivery.ArtifactUploadTest do
  @moduledoc """
  Proof for the worker artifact-upload decision (Task 52).

  Two promises are pinned here. The first is that the credential decides the
  project: a `project_id` in the request cannot widen it, another project's run
  is unreachable, and a superseded attempt writes nothing — the same fence rule
  every worker event already passes.

  The second is that a device-authoritative project is refused as a decision
  rather than by accident. `specs/05` forbids keeping its data in the hosted
  database, so the refusal is a named reason and the hosted artifact table stays
  empty even when the upload is otherwise perfectly formed.

  Refusals that would answer "does this exist?" are named here and collapsed at
  the transport, which is why this test proves the names and the controller test
  proves that the answers are indistinguishable.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Delivery.{ArtifactStore, ArtifactUpload, EvidenceArtifact, RunAttempt}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  setup do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    %{run: run, attempt: attempt} =
      DeliveryFixtures.run_with_attempt_fixture(hosted.project, feature)

    %{
      hosted: hosted,
      project: hosted.project,
      authority: hosted.workspace,
      feature: feature,
      run: run,
      attempt: attempt,
      claims: %{project_id: hosted.project.id, worker_id: "worker-1"}
    }
  end

  describe "accepting one upload" do
    test "stores the bytes and reports the reference they address", context do
      content = DeliveryFixtures.png_bytes()
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      assert {:ok, accepted} = ArtifactUpload.accept(context.claims, params, content)
      assert accepted.stored
      assert accepted.digest == DeliveryFixtures.content_digest(content)
      assert accepted.ref == ArtifactStore.ref_for(accepted.digest)

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, accepted.ref)

      assert artifact.content == content
      assert artifact.content_type == "image/png"
      refute artifact.redacted
    end

    test "carries the declared redaction claim into the store", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{redacted: true})

      assert {:ok, accepted} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, accepted.ref)

      assert artifact.redacted
    end

    test "answers a repeat of the same digest without storing it twice", context do
      content = DeliveryFixtures.png_bytes()
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      assert {:ok, first} = ArtifactUpload.accept(context.claims, params, content)
      assert {:ok, second} = ArtifactUpload.accept(context.claims, params, content)

      assert first.ref == second.ref
      assert first.stored
      refute second.stored
      assert Repo.aggregate(EvidenceArtifact, :count) == 1
    end

    test "refuses the same digest under a contradictory description", context do
      content = DeliveryFixtures.png_bytes()
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      assert {:ok, _stored} = ArtifactUpload.accept(context.claims, params, content)

      assert {:error, :artifact_conflict} =
               ArtifactUpload.accept(
                 context.claims,
                 Map.put(params, "content_type", "text/plain"),
                 content
               )

      assert Repo.aggregate(EvidenceArtifact, :count) == 1
    end
  end

  describe "proving the bytes match what was declared" do
    test "refuses content whose digest is not the declared one", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          digest: DeliveryFixtures.content_digest("something else")
        })

      assert {:error, :digest_mismatch} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())

      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses a content type outside the allowlist", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          content_type: "application/zip"
        })

      assert {:error, :unsupported_content_type} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses content beyond the shared artifact size limit", context do
      content = String.duplicate("x", ArtifactStore.max_bytes() + 1)

      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          content: content,
          content_type: "text/plain"
        })

      assert {:error, :artifact_too_large} =
               ArtifactUpload.accept(context.claims, params, content)
    end

    test "refuses an empty body", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{content: ""})

      assert {:error, :empty_artifact} = ArtifactUpload.accept(context.claims, params, "")
    end

    test "refuses a redaction claim that is neither true nor false", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          redacted: "maybe"
        })

      assert {:error, :invalid_redaction} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses metadata it cannot read at all", context do
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      for missing <- ~w(run_id attempt_id fence digest content_type) do
        assert {:error, :invalid_request} =
                 ArtifactUpload.accept(
                   context.claims,
                   Map.delete(params, missing),
                   DeliveryFixtures.png_bytes()
                 )
      end

      assert {:error, :invalid_request} =
               ArtifactUpload.accept(
                 context.claims,
                 Map.put(params, "fence", "not-a-fence"),
                 DeliveryFixtures.png_bytes()
               )
    end
  end

  describe "scoping the upload to one run attempt" do
    test "refuses a run this project does not have", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          run_id: Ecto.UUID.generate()
        })

      assert {:error, :unknown_run} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses another project's run even with a valid credential", context do
      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      %{run: other_run, attempt: other_attempt} =
        DeliveryFixtures.run_with_attempt_fixture(other.project, other_feature)

      params = DeliveryFixtures.artifact_upload_params(other_run, other_attempt)

      assert {:error, :unknown_run} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())

      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "ignores a project_id the request supplies", context do
      other = DeliveryFixtures.delivery_project_fixture()
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      assert {:ok, accepted} =
               ArtifactUpload.accept(
                 context.claims,
                 Map.put(params, "project_id", other.project.id),
                 DeliveryFixtures.png_bytes()
               )

      assert {:ok, _held} =
               ArtifactStore.fetch(context.authority, context.project.id, accepted.ref)

      assert {:error, :not_found} =
               ArtifactStore.fetch(other.workspace, other.project.id, accepted.ref)
    end

    test "refuses an attempt that is not the run's current one", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          attempt_id: Ecto.UUID.generate()
        })

      assert {:error, :stale_attempt} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses a superseded attempt that still believes it holds the run", context do
      superseded = context.attempt
      _current = supersede(context.run, superseded)

      params = DeliveryFixtures.artifact_upload_params(context.run, superseded)

      assert {:error, :stale_attempt} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())

      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses a fence the current attempt does not hold", context do
      params =
        DeliveryFixtures.artifact_upload_params(context.run, context.attempt, %{
          fence: context.attempt.fence_token + 1
        })

      assert {:error, :stale_fence} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses a run with no current attempt", context do
      Repo.update!(
        RunAttempt.transition_changeset(
          context.attempt,
          "canceled",
          context.attempt.state_version
        )
      )

      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)

      assert {:error, :no_current_attempt} =
               ArtifactUpload.accept(context.claims, params, DeliveryFixtures.png_bytes())
    end
  end

  describe "refusing what must never reach the hosted store" do
    test "refuses a project the control plane does not hold", context do
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)
      claims = %{project_id: Ecto.UUID.generate(), worker_id: "worker-1"}

      assert {:error, :unknown_project} =
               ArtifactUpload.accept(claims, params, DeliveryFixtures.png_bytes())
    end

    test "refuses a device-authoritative project and writes nothing hosted", context do
      device = start_device_project()
      params = DeliveryFixtures.artifact_upload_params(context.run, context.attempt)
      claims = %{project_id: device.id, worker_id: "worker-1"}

      assert {:error, :device_authoritative} =
               ArtifactUpload.accept(claims, params, DeliveryFixtures.png_bytes())

      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end
  end

  describe "the refusals the transport must not tell apart" do
    test "names every reason that would disclose whether project state exists" do
      assert ArtifactUpload.undisclosed?(:unauthorized_worker)
      assert ArtifactUpload.undisclosed?(:unknown_project)
      assert ArtifactUpload.undisclosed?(:device_authoritative)
      assert ArtifactUpload.undisclosed?(:unknown_run)
      assert ArtifactUpload.undisclosed?(:no_current_attempt)
      assert ArtifactUpload.undisclosed?(:stale_attempt)
      assert ArtifactUpload.undisclosed?(:stale_fence)
    end

    test "leaves refusals about the caller's own bytes visible" do
      refute ArtifactUpload.undisclosed?(:digest_mismatch)
      refute ArtifactUpload.undisclosed?(:unsupported_content_type)
      refute ArtifactUpload.undisclosed?(:artifact_too_large)
      refute ArtifactUpload.undisclosed?(:artifact_conflict)
      refute ArtifactUpload.undisclosed?(:invalid_request)
    end
  end

  # Ends the current attempt and starts the next one, exactly as a continuation
  # does, so the earlier attempt is genuinely superseded rather than merely old.
  defp supersede(run, attempt) do
    Repo.update!(RunAttempt.transition_changeset(attempt, "superseded", attempt.state_version))

    DeliveryFixtures.attempt_fixture(run, %{
      attempt_number: attempt.attempt_number + 1,
      continuation_reason: "manual_retry",
      fence_token: attempt.fence_token + 1
    })
  end

  defp start_device_project do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, _workspace} = Devices.establish_workspace()

    {:ok, project} =
      Devices.register_project(%{
        name: "Device project #{System.unique_integer([:positive])}",
        repository_fingerprint: DeliveryFixtures.digest("device-repo"),
        status: "connected"
      })

    project
  end
end
