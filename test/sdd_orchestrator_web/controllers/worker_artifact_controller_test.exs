defmodule SddOrchestratorWeb.WorkerArtifactControllerTest do
  @moduledoc """
  Proof for the authenticated worker artifact-upload transport (Task 52).

  This is the only place project content enters the control plane over HTTP, so
  what is pinned here is the boundary rather than the storage rule. The
  credential is the signed worker token and nothing else: no session is created,
  no cookie is set, and a missing, malformed, expired, or tampered token is
  refused before a single byte of the body is read.

  The refusals are deliberately one answer. An unauthorized worker, an unknown
  run, another project's run, a superseded attempt, and a device-authoritative
  project must be indistinguishable from outside, because telling them apart is
  itself the disclosure. Only refusals about the caller's own bytes are named,
  and only after the caller has proved it may upload to this run at all.

  A successful answer carries the opaque reference and its digest and nothing
  else — no URL, path, host, or credential — because a reference that could be
  dereferenced by anything but the artifact store would make private evidence a
  link.
  """
  use SddOrchestratorWeb.ConnCase, async: false

  alias SddOrchestrator.Delivery.{ArtifactStore, EvidenceArtifact, RunAttempt}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo
  alias SddOrchestrator.WorkerDouble

  @path "/worker/artifacts"

  setup %{conn: conn} do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    %{run: run, attempt: attempt} =
      DeliveryFixtures.run_with_attempt_fixture(hosted.project, feature)

    %{
      conn: conn,
      hosted: hosted,
      project: hosted.project,
      authority: hosted.workspace,
      run: run,
      attempt: attempt,
      token: WorkerDouble.token(hosted.project.id)
    }
  end

  describe "accepting one upload" do
    test "stores the bytes and answers with the reference they address", context do
      content = DeliveryFixtures.png_bytes()
      conn = upload(context, content)

      assert conn.status == 201
      body = json_response(conn, 201)
      assert body["digest"] == DeliveryFixtures.content_digest(content)
      assert body["ref"] == ArtifactStore.ref_for(body["digest"])
      assert Map.keys(body) |> Enum.sort() == ~w(digest ref)

      assert {:ok, artifact} =
               ArtifactStore.fetch(context.authority, context.project.id, body["ref"])

      assert artifact.content == content
    end

    test "answers with no link, location, or credential of any kind", context do
      conn = upload(context, DeliveryFixtures.png_bytes())
      body = json_response(conn, 201)

      refute body["ref"] =~ "://"
      refute body["ref"] =~ "/"
      refute Map.has_key?(body, "url")
      refute Map.has_key?(body, "path")
      refute Map.has_key?(body, "host")
      assert get_resp_header(conn, "set-cookie") == []
      assert get_resp_header(conn, "location") == []
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "answers a repeat of the same digest with the same reference", context do
      content = DeliveryFixtures.png_bytes()

      created = upload(context, content)
      repeated = upload(context, content)

      assert json_response(created, 201)["ref"] == json_response(repeated, 200)["ref"]
      assert Repo.aggregate(EvidenceArtifact, :count) == 1
    end

    test "refuses the same digest under a contradictory description", context do
      content = DeliveryFixtures.png_bytes()

      assert upload(context, content).status == 201

      conn = upload(context, content, %{content_type: "text/plain"})

      assert json_response(conn, 409) == %{"error" => "artifact_conflict"}
      assert Repo.aggregate(EvidenceArtifact, :count) == 1
    end
  end

  describe "authenticating the worker" do
    test "refuses a request with no credential", context do
      conn = post_artifact(context.conn, query(context), DeliveryFixtures.png_bytes(), nil)

      assert refused(conn)
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses a credential that is not a bearer token", context do
      conn =
        context.conn
        |> put_req_header("authorization", "Basic #{Base.encode64("worker:secret")}")
        |> put_req_header("content-type", "application/octet-stream")
        |> post(upload_url(query(context)), DeliveryFixtures.png_bytes())

      assert refused(conn)
    end

    test "refuses a malformed credential", context do
      assert refused(upload_with_token(context, "not-a-signed-token"))
    end

    test "refuses a credential whose bounded lifetime elapsed", context do
      assert refused(upload_with_token(context, WorkerDouble.stale_token(context.project.id)))
    end

    test "refuses a tampered credential", context do
      tampered = tamper(context.token)

      assert tampered != context.token
      assert refused(upload_with_token(context, tampered))
    end

    test "accepts the bearer scheme however it is capitalized", context do
      conn =
        context.conn
        |> put_req_header("authorization", "bearer " <> context.token)
        |> put_req_header("content-type", "application/octet-stream")
        |> post(upload_url(query(context)), DeliveryFixtures.png_bytes())

      assert conn.status == 201
    end
  end

  describe "scoping the upload to the credential's own project" do
    test "refuses another project's run", context do
      other = DeliveryFixtures.delivery_project_fixture()
      other_feature = DeliveryFixtures.feature_fixture(other.project, other.account)

      %{run: other_run, attempt: other_attempt} =
        DeliveryFixtures.run_with_attempt_fixture(other.project, other_feature)

      conn =
        post_artifact(
          context.conn,
          query(%{run: other_run, attempt: other_attempt}),
          DeliveryFixtures.png_bytes(),
          context.token
        )

      assert refused(conn)
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "does not let a project_id parameter widen the credential", context do
      other = DeliveryFixtures.delivery_project_fixture()
      content = DeliveryFixtures.png_bytes()

      conn =
        post_artifact(
          context.conn,
          Map.put(query(context), "project_id", other.project.id),
          content,
          context.token
        )

      ref = json_response(conn, 201)["ref"]

      assert {:ok, _held} = ArtifactStore.fetch(context.authority, context.project.id, ref)
      assert {:error, :not_found} = ArtifactStore.fetch(other.workspace, other.project.id, ref)
    end

    test "refuses a superseded attempt", context do
      superseded = context.attempt

      Repo.update!(
        RunAttempt.transition_changeset(superseded, "superseded", superseded.state_version)
      )

      DeliveryFixtures.attempt_fixture(context.run, %{
        attempt_number: superseded.attempt_number + 1,
        continuation_reason: "manual_retry",
        fence_token: superseded.fence_token + 1
      })

      assert refused(upload(context, DeliveryFixtures.png_bytes()))
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses a fence the current attempt does not hold", context do
      conn =
        upload(context, DeliveryFixtures.png_bytes(), %{fence: context.attempt.fence_token + 1})

      assert refused(conn)
    end
  end

  describe "refusing without disclosing" do
    test "answers an unauthorized worker and an unknown run identically", context do
      unauthorized =
        post_artifact(context.conn, query(context), DeliveryFixtures.png_bytes(), "forged")

      unknown =
        post_artifact(
          build_conn(),
          Map.put(query(context), "run_id", Ecto.UUID.generate()),
          DeliveryFixtures.png_bytes(),
          context.token
        )

      assert unauthorized.status == unknown.status
      assert json_response(unauthorized, 403) == json_response(unknown, 403)
    end

    test "answers a device-authoritative project like any other refusal", context do
      device = start_device_project()

      conn =
        post_artifact(
          build_conn(),
          query(context),
          DeliveryFixtures.png_bytes(),
          WorkerDouble.token(device.id)
        )

      assert refused(conn)
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
      assert ArtifactStore.list_refs(context.authority, device.id) == []
    end
  end

  describe "proving the bytes against what was declared" do
    test "refuses content whose digest is not the declared one", context do
      conn =
        upload(context, DeliveryFixtures.png_bytes(), %{
          digest: DeliveryFixtures.content_digest("other bytes")
        })

      assert json_response(conn, 422) == %{"error" => "digest_mismatch"}
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses a content type outside the allowlist", context do
      conn = upload(context, DeliveryFixtures.png_bytes(), %{content_type: "application/zip"})

      assert json_response(conn, 415) == %{"error" => "unsupported_content_type"}
    end

    test "refuses a body beyond the artifact size limit", context do
      oversized = String.duplicate("x", ArtifactStore.max_bytes() + 1)

      conn =
        post_artifact(
          context.conn,
          Map.merge(query(context), %{
            "content_type" => "text/plain",
            "digest" => DeliveryFixtures.content_digest(oversized)
          }),
          oversized,
          context.token
        )

      assert json_response(conn, 413) == %{"error" => "artifact_too_large"}
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "refuses metadata it cannot read", context do
      conn =
        post_artifact(
          context.conn,
          Map.delete(query(context), "fence"),
          DeliveryFixtures.png_bytes(),
          context.token
        )

      assert json_response(conn, 422) == %{"error" => "invalid_request"}
    end
  end

  defp upload(context, content, overrides \\ %{}) do
    post_artifact(build_conn(), query(context, overrides), content, context.token)
  end

  defp upload_with_token(context, token) do
    post_artifact(build_conn(), query(context), DeliveryFixtures.png_bytes(), token)
  end

  defp post_artifact(conn, params, content, token) do
    conn
    |> authorize(token)
    |> put_req_header("content-type", "application/octet-stream")
    |> post(upload_url(params), content)
  end

  defp authorize(conn, nil), do: conn
  defp authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp upload_url(params), do: @path <> "?" <> URI.encode_query(params)

  defp query(context, overrides \\ %{}),
    do: DeliveryFixtures.artifact_upload_params(context.run, context.attempt, overrides)

  # Rewrites the first character of the signature, whose bits are all significant.
  # The last character of a Base64 signature carries padding bits a decoder
  # ignores, so changing it would produce a different string that still verifies.
  defp tamper(token) do
    [protected, payload, signature] = String.split(token, ".")
    {first, rest} = String.split_at(signature, 1)

    Enum.join([protected, payload, altered(first) <> rest], ".")
  end

  defp altered("A"), do: "B"
  defp altered(_character), do: "A"

  # One refusal answer for every question about whether project state exists.
  defp refused(conn) do
    json_response(conn, 403) == %{"error" => "refused"}
  end

  defp start_device_project do
    path = Path.join(System.tmp_dir!(), "upload-web-#{System.unique_integer([:positive])}.dets")
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
