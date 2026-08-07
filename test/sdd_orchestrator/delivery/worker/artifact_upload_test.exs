defmodule SddOrchestrator.Delivery.Worker.ArtifactUploadTest do
  @moduledoc """
  Proof for the worker's side of the artifact-upload transport (Task 52).

  The promise pinned here is that where the bytes go is decided by the project's
  storage authority and by nothing else. A device-authoritative project makes no
  request at all — not a request that is later refused, but no request — because
  `specs/05` forbids a hosted copy of its data and the safest way to honour that
  is a branch with no URL and no credential in it.

  A hosted project's worker declares a digest it computed from the bytes it is
  actually sending, binds the upload to one run, attempt, and fence, and
  normalizes every answer into a reason a caller can act on. The request contract
  runs against a stub rather than a live control plane, so the shape of what is
  sent is proved without a network.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.Worker.ArtifactUpload
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local

  @stub SddOrchestrator.Delivery.Worker.ArtifactUploadTest.Stub
  @base_url "https://control-plane.test"
  @token "signed-worker-credential"

  setup do
    hosted = DeliveryFixtures.delivery_project_fixture()
    content = DeliveryFixtures.png_bytes()

    %{
      hosted: hosted,
      project_id: hosted.project.id,
      authority: hosted.workspace,
      content: content,
      capture: %{
        run_id: "run-1",
        fence: 3,
        content: content,
        content_type: "image/png"
      }
    }
  end

  describe "uploading for a hosted project" do
    test "binds the upload to the run, attempt, fence, and computed digest", context do
      stub_response(201, %{
        "ref" => ArtifactStore.ref_for(ArtifactUpload.digest(context.content)),
        "digest" => ArtifactUpload.digest(context.content)
      })

      assert {:ok, ref} = upload(context)
      assert ref == ArtifactStore.ref_for(ArtifactUpload.digest(context.content))

      assert_received {:uploaded, request}
      assert request.method == "POST"
      assert request.path == "/worker/artifacts"
      assert request.authorization == ["Bearer " <> @token]
      assert request.content_type == ["application/octet-stream"]
      assert request.body == context.content

      assert request.params == %{
               "run_id" => "run-1",
               "fence" => "3",
               "digest" => ArtifactUpload.digest(context.content),
               "content_type" => "image/png",
               "redacted" => "false"
             }
    end

    test "declares the redaction claim it was given", context do
      stub_response(201, %{"ref" => "artifact:v1:sha256:" <> String.duplicate("a", 64)})

      assert {:ok, _ref} = upload(context, %{redacted: true})

      assert_received {:uploaded, request}
      assert request.params["redacted"] == "true"
    end

    test "accepts an idempotent repeat as success", context do
      ref = ArtifactStore.ref_for(ArtifactUpload.digest(context.content))
      stub_response(200, %{"ref" => ref})

      assert {:ok, ^ref} = upload(context)
    end

    test "reads a refusal as one reason and asks the body nothing", context do
      stub_response(403, %{"error" => "refused"})

      assert {:error, :refused} = upload(context)
    end

    test "normalizes each named refusal into its own reason", context do
      for {status, error, reason} <- [
            {409, "artifact_conflict", :artifact_conflict},
            {413, "artifact_too_large", :artifact_too_large},
            {415, "unsupported_content_type", :unsupported_content_type},
            {422, "digest_mismatch", :digest_mismatch},
            {422, "invalid_redaction", :invalid_redaction},
            {422, "invalid_request", :invalid_request},
            {500, "upload_failed", :upload_failed}
          ] do
        stub_response(status, %{"error" => error})
        assert {:error, ^reason} = upload(context)
      end
    end

    test "does not mint an atom from a reason it does not know", context do
      stub_response(422, %{"error" => "something_new"})

      assert {:error, :upload_failed} = upload(context)
    end

    test "reports a transport failure as its own outcome", context do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, :transport_failed} = upload(context)
    end

    test "refuses a success answer that carries no reference", context do
      stub_response(201, %{"digest" => ArtifactUpload.digest(context.content)})

      assert {:error, :upload_failed} = upload(context)
    end
  end

  describe "capturing for a device-authoritative project" do
    test "writes to the device's own store and makes no request at all", context do
      authority = start_device_workspace()
      stub_response(201, %{"ref" => "artifact:v1:sha256:" <> String.duplicate("a", 64)})

      assert {:ok, ref} =
               ArtifactUpload.upload(
                 authority,
                 context.project_id,
                 context.capture,
                 base_url: @base_url,
                 token: @token,
                 req_options: [plug: {Req.Test, @stub}]
               )

      assert ref == ArtifactStore.ref_for(ArtifactUpload.digest(context.content))
      refute_received {:uploaded, _request}

      assert {:ok, artifact} = ArtifactStore.fetch(authority, context.project_id, ref)
      assert artifact.content == context.content
      assert artifact.content_type == "image/png"
    end

    test "refuses bytes the device store would not accept either", context do
      authority = start_device_workspace()

      assert {:error, :unsupported_content_type} =
               ArtifactUpload.upload(
                 authority,
                 context.project_id,
                 %{context.capture | content_type: "application/zip"},
                 base_url: @base_url,
                 token: @token
               )
    end
  end

  test "refuses an authority that resolves to no store", context do
    assert {:error, :unsupported_authority} =
             ArtifactUpload.upload(nil, context.project_id, context.capture,
               base_url: @base_url,
               token: @token
             )
  end

  defp upload(context, overrides \\ %{}) do
    ArtifactUpload.upload(
      context.authority,
      context.project_id,
      Map.merge(context.capture, overrides),
      base_url: @base_url,
      token: @token,
      req_options: [plug: {Req.Test, @stub}]
    )
  end

  # The stub records what the worker actually put on the wire, so the request
  # contract is proved rather than assumed from the client's own code.
  defp stub_response(status, body) do
    Req.Test.stub(@stub, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)

      send(
        self(),
        {:uploaded,
         %{
           method: conn.method,
           path: conn.request_path,
           params: conn.query_params,
           body: request_body,
           authorization: Plug.Conn.get_req_header(conn, "authorization"),
           content_type: Plug.Conn.get_req_header(conn, "content-type")
         }}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp start_device_workspace do
    path =
      Path.join(System.tmp_dir!(), "worker-upload-#{System.unique_integer([:positive])}.dets")

    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, workspace} = Devices.establish_workspace()
    %DeviceWorkspace{id: workspace.id}
  end
end
