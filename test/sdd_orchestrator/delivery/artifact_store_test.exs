defmodule SddOrchestrator.Delivery.ArtifactStoreTest do
  @moduledoc """
  Proof for private evidence-artifact storage (Task 29).

  One promise is pinned above all others: an artifact is private project data.
  It has no public URL, no host, no query string, and no credential anywhere in
  its reference or its stored form. The reference is opaque and digest-addressed,
  the hosted column is encrypted at rest, the device copy is vault-sealed, and
  the only way to a screenshot's bytes is an authorized fetch against the
  project that owns them.

  The second promise is that the reference means something. The declared digest
  is recomputed before anything is stored, so a reader who retrieves an artifact
  can check it against the evidence row that named it instead of trusting it.

  Every behavioural test runs against both storage authorities, because
  `specs/05` forbids keeping a device-authoritative project's data in the hosted
  database and two implementations are only safe once they answer the same way.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.ArtifactStoreDouble
  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact
  alias SddOrchestrator.Delivery.{DeliveryStore, EvidenceArtifact}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Repo

  @commit "a1b2c3d4e5f6a7b8c9d0"
  @migration_version 20_260_730_000_000

  setup context do
    hosted = DeliveryFixtures.delivery_project_fixture()
    feature = DeliveryFixtures.feature_fixture(hosted.project, hosted.account)

    path = Path.join(System.tmp_dir!(), "artifacts-#{System.unique_integer([:positive])}.dets")
    start_supervised!({Local, path: path})
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, device_workspace} = Devices.establish_workspace()
    device_authority = %DeviceWorkspace{id: device_workspace.id}

    authority =
      case context[:authority] do
        :device -> device_authority
        _hosted -> hosted.workspace
      end

    %{
      authority: authority,
      hosted_authority: hosted.workspace,
      device_authority: device_authority,
      hosted: hosted,
      project: hosted.project,
      feature: feature
    }
  end

  # Every behaviour below runs twice: once against PostgreSQL and once against
  # the worker-owned device store.
  for authority <- [:hosted, :device] do
    describe "storing and retrieving one artifact (#{authority})" do
      @describetag authority: authority

      test "returns an opaque, digest-addressed reference that fits an evidence row", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()

        assert {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
        assert ref == "artifact:v1:sha256:" <> attrs.digest
        assert ArtifactStore.valid_ref?(ref)
        assert {:ok, attrs.digest} == ArtifactStore.digest_from_ref(ref)
        assert byte_size(ref) <= 512
      end

      test "gives back byte-identical content with the description it was stored under", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs(redacted: true)
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert {:ok, %Artifact{} = artifact} = ArtifactStore.fetch(authority, project.id, ref)
        assert artifact.content == attrs.content
        assert artifact.content_type == "image/png"
        assert artifact.byte_size == byte_size(attrs.content)
        assert artifact.digest == attrs.digest
        assert artifact.redacted
        assert artifact.ref == ref
      end

      test "reports what an artifact is without loading its bytes", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert {:ok, %Artifact{} = metadata} = ArtifactStore.stat(authority, project.id, ref)
        refute metadata.content
        assert metadata.content_type == "image/png"
        assert metadata.byte_size == byte_size(attrs.content)
        assert metadata.digest == attrs.digest
        refute metadata.redacted
      end

      test "the same bytes stored twice are one artifact, not two", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()

        assert {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
        assert {:ok, ^ref} = ArtifactStore.put(authority, project.id, attrs)

        assert ArtifactStore.list_refs(authority, project.id) == [ref]

        assert {:ok, %Artifact{content: content}} =
                 ArtifactStore.fetch(authority, project.id, ref)

        assert content == attrs.content
      end

      test "the same bytes cannot carry two contradictory descriptions", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert {:error, :artifact_conflict} =
                 ArtifactStore.put(authority, project.id, %{attrs | content_type: "text/plain"})

        assert {:error, :artifact_conflict} =
                 ArtifactStore.put(authority, project.id, %{attrs | redacted: true})

        assert ArtifactStore.list_refs(authority, project.id) == [ref]

        assert {:ok, %Artifact{content_type: "image/png", redacted: false}} =
                 ArtifactStore.stat(authority, project.id, ref)
      end
    end

    describe "refusing what must not be stored (#{authority})" do
      @describetag authority: authority

      test "a content type outside the allowlist is refused", %{
        authority: authority,
        project: project
      } do
        for content_type <- ["application/zip", "text/html", "image/svg+xml", "", nil] do
          attrs = DeliveryFixtures.artifact_attrs(content_type: content_type)

          assert {:error, :unsupported_content_type} =
                   ArtifactStore.put(authority, project.id, attrs)
        end

        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "an artifact past the size limit never reaches storage", %{
        authority: authority,
        project: project
      } do
        oversized = String.duplicate("x", ArtifactStore.max_bytes() + 1)
        attrs = DeliveryFixtures.artifact_attrs(content: oversized, content_type: "text/plain")

        assert {:error, :artifact_too_large} = ArtifactStore.put(authority, project.id, attrs)
        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "an artifact with no content is refused rather than stored empty", %{
        authority: authority,
        project: project
      } do
        for content <- ["", nil, :not_a_binary] do
          attrs = %{
            content: content,
            content_type: "image/png",
            digest: empty_digest(),
            redacted: false
          }

          assert {:error, :empty_artifact} = ArtifactStore.put(authority, project.id, attrs)
        end

        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "a declared digest that does not match the bytes is refused", %{
        authority: authority,
        project: project
      } do
        wrong = DeliveryFixtures.artifact_attrs(digest: DeliveryFixtures.digest("other bytes"))

        assert {:error, :digest_mismatch} = ArtifactStore.put(authority, project.id, wrong)

        malformed = DeliveryFixtures.artifact_attrs(digest: "trust me")
        assert {:error, :digest_mismatch} = ArtifactStore.put(authority, project.id, malformed)

        missing = DeliveryFixtures.artifact_attrs(digest: nil)
        assert {:error, :digest_mismatch} = ArtifactStore.put(authority, project.id, missing)

        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "credential material is refused before it is ever written down", %{
        authority: authority,
        project: project
      } do
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow==\n-----END RSA PRIVATE KEY-----\n"
        attrs = DeliveryFixtures.artifact_attrs(content: pem, content_type: "text/plain")

        assert {:error, :secret_material_rejected} =
                 ArtifactStore.put(authority, project.id, attrs)

        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "a redaction claim that is not plainly true or false is refused", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs(redacted: "yes")

        assert {:error, :invalid_redaction} = ArtifactStore.put(authority, project.id, attrs)
        assert ArtifactStore.list_refs(authority, project.id) == []
      end
    end

    describe "removing artifacts (#{authority})" do
      @describetag authority: authority

      test "a deleted artifact is gone, and deleting it again is not an error", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert :ok = ArtifactStore.delete(authority, project.id, ref)
        assert {:error, :not_found} = ArtifactStore.fetch(authority, project.id, ref)
        assert {:error, :not_found} = ArtifactStore.stat(authority, project.id, ref)
        assert ArtifactStore.list_refs(authority, project.id) == []

        assert :ok = ArtifactStore.delete(authority, project.id, ref)
        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "deleting a reference this project never held is not an error", %{
        authority: authority,
        project: project
      } do
        never_stored = ArtifactStore.ref_for(DeliveryFixtures.digest("never stored"))

        assert :ok = ArtifactStore.delete(authority, project.id, never_stored)
        assert ArtifactStore.list_refs(authority, project.id) == []
      end

      test "the project cleanup seam removes every artifact and says how many", %{
        authority: authority,
        project: project
      } do
        for seed <- ["one", "two", "three"] do
          ArtifactStore.put(
            authority,
            project.id,
            DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes(seed))
          )
        end

        assert length(ArtifactStore.list_refs(authority, project.id)) == 3
        assert {:ok, 3} = ArtifactStore.delete_project(authority, project.id)
        assert ArtifactStore.list_refs(authority, project.id) == []
        assert {:ok, 0} = ArtifactStore.delete_project(authority, project.id)
      end

      test "a deleted digest can be stored again under a new description", %{
        authority: authority,
        project: project
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
        :ok = ArtifactStore.delete(authority, project.id, ref)

        assert {:ok, ^ref} =
                 ArtifactStore.put(authority, project.id, %{attrs | redacted: true})

        assert {:ok, %Artifact{redacted: true}} = ArtifactStore.stat(authority, project.id, ref)
      end
    end

    describe "keeping one project's artifacts out of another (#{authority})" do
      @describetag authority: authority

      test "a reference stored under one project is absent under another", %{
        authority: authority,
        project: project
      } do
        other = DeliveryFixtures.delivery_project_fixture()
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert {:error, :not_found} = ArtifactStore.fetch(authority, other.project.id, ref)
        assert {:error, :not_found} = ArtifactStore.stat(authority, other.project.id, ref)
        assert ArtifactStore.list_refs(authority, other.project.id) == []
      end

      test "deleting under another project leaves the owner's artifact alone", %{
        authority: authority,
        project: project
      } do
        other = DeliveryFixtures.delivery_project_fixture()
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

        assert :ok = ArtifactStore.delete(authority, other.project.id, ref)
        assert {:ok, 0} = ArtifactStore.delete_project(authority, other.project.id)

        assert {:ok, %Artifact{content: content}} =
                 ArtifactStore.fetch(authority, project.id, ref)

        assert content == attrs.content
        assert ArtifactStore.list_refs(authority, project.id) == [ref]
      end

      test "listing is scoped to the project that was asked about", %{
        authority: authority,
        project: project
      } do
        other = DeliveryFixtures.delivery_project_fixture()

        {:ok, mine} = ArtifactStore.put(authority, project.id, DeliveryFixtures.artifact_attrs())

        {:ok, theirs} =
          ArtifactStore.put(
            authority,
            other.project.id,
            DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("theirs"))
          )

        assert ArtifactStore.list_refs(authority, project.id) == [mine]
        assert ArtifactStore.list_refs(authority, other.project.id) == [theirs]
      end
    end

    describe "denying a public link (#{authority})" do
      @describetag authority: authority

      test "the reference is opaque: no scheme, host, query string, or credential", %{
        authority: authority,
        project: project
      } do
        ref = DeliveryFixtures.artifact_fixture(authority, project.id)

        assert ref =~ ~r/\Aartifact:v1:sha256:[0-9a-f]{64}\z/
        refute String.contains?(ref, "://")
        refute String.contains?(ref, "?")
        refute String.contains?(ref, "//")
        refute String.contains?(ref, "@")
        refute ref =~ ~r/https?/i
        refute ref =~ ~r/localhost|\.com|\.io|\.dev/i
      end

      test "neither a fetch nor a stat result carries a link of any kind", %{
        authority: authority,
        project: project
      } do
        ref = DeliveryFixtures.artifact_fixture(authority, project.id)

        {:ok, fetched} = ArtifactStore.fetch(authority, project.id, ref)
        {:ok, metadata} = ArtifactStore.stat(authority, project.id, ref)

        for artifact <- [fetched, metadata] do
          keys = artifact |> Map.from_struct() |> Map.keys() |> Enum.map(&Atom.to_string/1)

          assert Enum.sort(keys) ==
                   ~w(byte_size content content_type digest redacted ref)

          refute Enum.any?(keys, &(&1 =~ ~r/url|uri|link|href|host|endpoint|token/))
        end
      end

      test "a malformed reference is absent rather than a crash", %{
        authority: authority,
        project: project
      } do
        malformed = [
          "",
          "artifact:v1:sha256:",
          "artifact:v1:sha256:not-a-digest",
          "artifact:v1:sha256:" <> String.upcase(DeliveryFixtures.digest("shout")),
          "artifact:v2:sha256:" <> DeliveryFixtures.digest("version"),
          "https://example.com/artifact.png",
          "../../etc/passwd",
          DeliveryFixtures.digest("bare digest"),
          nil,
          :not_a_ref
        ]

        for ref <- malformed do
          refute ArtifactStore.valid_ref?(ref)
          assert {:error, :not_found} = ArtifactStore.fetch(authority, project.id, ref)
          assert {:error, :not_found} = ArtifactStore.stat(authority, project.id, ref)
          assert :ok = ArtifactStore.delete(authority, project.id, ref)
        end
      end
    end

    describe "reading the artifact one item of evidence names (#{authority})" do
      @describetag authority: authority

      test "an authorized participant receives the bytes", %{
        authority: authority,
        hosted: hosted,
        project: project,
        feature: feature
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
        evidence = record_evidence(authority, project, feature, artifact_ref: ref)

        for actor <- [hosted.owner_actor, hosted.participant_actor] do
          assert {:ok, %Artifact{content: content}} =
                   ArtifactStore.fetch_for_evidence(authority, project.id, evidence.id, actor)

          assert content == attrs.content
        end
      end

      test "every refusal is the same refusal", %{
        authority: authority,
        hosted: hosted,
        project: project,
        feature: feature
      } do
        attrs = DeliveryFixtures.artifact_attrs()
        {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
        evidence = record_evidence(authority, project, feature, artifact_ref: ref)
        without_artifact = record_evidence(authority, project, feature, artifact_ref: nil)

        stranger = DeliveryFixtures.delivery_project_fixture()

        # A stranger, a member of another project asking through their own
        # project, an item that never had an artifact, and an item that does not
        # exist all answer identically, so asking discloses nothing.
        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(
                   authority,
                   project.id,
                   evidence.id,
                   stranger.owner_actor
                 )

        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(
                   authority,
                   stranger.project.id,
                   evidence.id,
                   stranger.owner_actor
                 )

        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(
                   authority,
                   project.id,
                   without_artifact.id,
                   hosted.participant_actor
                 )

        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(
                   authority,
                   project.id,
                   Ecto.UUID.generate(),
                   hosted.participant_actor
                 )

        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(authority, project.id, evidence.id, %{})
      end

      test "an item naming an artifact the store no longer holds is also absent", %{
        authority: authority,
        hosted: hosted,
        project: project,
        feature: feature
      } do
        ref = DeliveryFixtures.artifact_fixture(authority, project.id)
        evidence = record_evidence(authority, project, feature, artifact_ref: ref)
        :ok = ArtifactStore.delete(authority, project.id, ref)

        assert {:error, :not_found} =
                 ArtifactStore.fetch_for_evidence(
                   authority,
                   project.id,
                   evidence.id,
                   hosted.participant_actor
                 )
      end
    end
  end

  describe "the two adapters as one contract" do
    test "the same call sequence answers the same way in either authority", %{
      hosted_authority: hosted_authority,
      device_authority: device_authority,
      project: project
    } do
      assert sequence(hosted_authority, project.id) == sequence(device_authority, project.id)
    end

    test "an authority with no adapter is empty rather than an error", %{project: project} do
      ref = ArtifactStore.ref_for(DeliveryFixtures.digest("nowhere"))

      refute ArtifactStore.supported?(%{})
      refute ArtifactStore.supported?(nil)

      assert {:error, :unsupported_authority} =
               ArtifactStore.put(%{}, project.id, DeliveryFixtures.artifact_attrs())

      assert {:error, :not_found} = ArtifactStore.fetch(%{}, project.id, ref)
      assert {:error, :not_found} = ArtifactStore.stat(%{}, project.id, ref)
      assert :ok = ArtifactStore.delete(%{}, project.id, ref)
      assert {:ok, 0} = ArtifactStore.delete_project(%{}, project.id)
      assert ArtifactStore.list_refs(%{}, project.id) == []
    end

    test "both real adapters are supported authorities", %{
      hosted_authority: hosted_authority,
      device_authority: device_authority
    } do
      assert ArtifactStore.supported?(hosted_authority)
      assert ArtifactStore.supported?(device_authority)
    end
  end

  describe "the hosted adapter's storage" do
    test "the bytes in the column are not the bytes that were stored", %{
      hosted_authority: authority,
      project: project
    } do
      attrs = DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("at rest"))
      {:ok, _ref} = ArtifactStore.put(authority, project.id, attrs)

      %{rows: [[raw]]} =
        Repo.query!("SELECT content FROM evidence_artifacts WHERE digest = $1", [attrs.digest])

      assert is_binary(raw)
      refute raw == attrs.content
      assert :binary.match(raw, attrs.content) == :nomatch
      assert byte_size(raw) > byte_size(attrs.content)
    end

    test "the artifact struct never prints its bytes", %{
      hosted_authority: authority,
      project: project
    } do
      attrs =
        DeliveryFixtures.artifact_attrs(content: "printable proof", content_type: "text/plain")

      {:ok, _ref} = ArtifactStore.put(authority, project.id, attrs)

      stored = Repo.get_by!(EvidenceArtifact, project_id: project.id, digest: attrs.digest)

      refute inspect(stored) =~ "printable proof"
      assert stored.content == attrs.content
    end

    test "the table has no column that could become a public link" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'evidence_artifacts'"
        )

      columns = List.flatten(rows)

      assert "content" in columns
      assert "digest" in columns
      refute Enum.any?(columns, &(&1 =~ ~r/url|uri|link|href|host|endpoint|token|path/))
    end

    test "the database refuses what the store would never write", %{project: project} do
      for {name, overrides} <- [
            {"evidence_artifacts_digest_format", %{digest: "trust me"}},
            {"evidence_artifacts_content_type_allowed", %{content_type: "application/zip"}},
            {"evidence_artifacts_byte_size_bounded", %{byte_size: 0}},
            {"evidence_artifacts_byte_size_bounded", %{byte_size: ArtifactStore.max_bytes() + 1}}
          ] do
        assert_raise Ecto.ConstraintError, ~r/#{name}/, fn ->
          raw_insert!(project, overrides)
        end
      end
    end

    test "the same digest cannot be stored twice in one project", %{project: project} do
      raw_insert!(project, %{})

      assert_raise Ecto.ConstraintError, ~r/evidence_artifacts_project_id_digest_index/, fn ->
        raw_insert!(project, %{})
      end
    end
  end

  describe "the device adapter's isolation" do
    @describetag authority: :device

    test "a device put creates no hosted row at all", %{authority: authority, project: project} do
      attrs = DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("device only"))

      assert {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
      assert Repo.aggregate(EvidenceArtifact, :count) == 0

      assert {:ok, %Artifact{content: content}} = ArtifactStore.fetch(authority, project.id, ref)
      assert content == attrs.content
      assert Repo.aggregate(EvidenceArtifact, :count) == 0
    end

    test "the device record holds sealed bytes, not the content", %{
      authority: authority,
      project: project
    } do
      attrs = DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("sealed"))
      {:ok, _ref} = ArtifactStore.put(authority, project.id, attrs)

      assert {:ok, value} = Devices.get_delivery(project.id, :artifact, attrs.digest)
      assert :binary.match(value["content"], attrs.content) == :nomatch
      refute Map.has_key?(value, "state_version")
      assert value["byte_size"] == byte_size(attrs.content)
    end

    test "a removed artifact leaves no readable content behind", %{
      authority: authority,
      project: project
    } do
      attrs = DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("erased"))
      {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)

      :ok = ArtifactStore.delete(authority, project.id, ref)

      assert {:ok, value} = Devices.get_delivery(project.id, :artifact, attrs.digest)
      refute Map.has_key?(value, "content")
      refute Map.has_key?(value, "content_type")
      refute Map.has_key?(value, "byte_size")
    end
  end

  describe "the deterministic adapter double" do
    test "takes over dispatch, records the artifact, and replays a scripted answer", %{
      authority: authority,
      project: project
    } do
      restore = ArtifactStoreDouble.install()
      on_exit(restore)

      attrs = DeliveryFixtures.artifact_attrs()

      assert {:ok, ref} = ArtifactStore.put(authority, project.id, attrs)
      assert ref == ArtifactStore.ref_for(attrs.digest)
      assert [{project_id, recorded}] = ArtifactStoreDouble.requested()
      assert project_id == project.id
      assert recorded.digest == attrs.digest
      assert recorded.byte_size == byte_size(attrs.content)

      assert {:ok, %Artifact{content: content}} = ArtifactStore.fetch(authority, project.id, ref)
      assert content == attrs.content
      assert {:ok, %Artifact{content: nil}} = ArtifactStore.stat(authority, project.id, ref)
      assert ArtifactStore.list_refs(authority, project.id) == [ref]

      # Nothing reached the real hosted adapter while the double was installed.
      assert Repo.aggregate(EvidenceArtifact, :count) == 0

      ArtifactStoreDouble.script({:error, :artifact_unavailable})

      assert {:error, :artifact_unavailable} =
               ArtifactStore.put(
                 authority,
                 project.id,
                 DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("later"))
               )

      ArtifactStoreDouble.script({:error, :artifact_too_large})

      assert {:error, :artifact_too_large} =
               ArtifactStore.put(
                 authority,
                 project.id,
                 DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("bigger"))
               )
    end

    test "shared validation still runs before the double is reached", %{
      authority: authority,
      project: project
    } do
      restore = ArtifactStoreDouble.install()
      on_exit(restore)

      assert {:error, :unsupported_content_type} =
               ArtifactStore.put(
                 authority,
                 project.id,
                 DeliveryFixtures.artifact_attrs(content_type: "application/zip")
               )

      assert ArtifactStoreDouble.requested() == []
    end

    test "the double is restored so later tests see the real adapters", %{
      authority: authority,
      project: project
    } do
      restore = ArtifactStoreDouble.install()
      restore.()

      assert {:ok, _ref} =
               ArtifactStore.put(authority, project.id, DeliveryFixtures.artifact_attrs())

      assert Repo.aggregate(EvidenceArtifact, :count) == 1
    end
  end

  describe "the migration" do
    test "rolls back and forward again" do
      module = migration_module()

      assert table_exists?("evidence_artifacts")

      # The lock is disabled because it would hold a second connection the Ecto
      # sandbox does not have. The migration itself still runs for real, inside
      # this test's transaction, so the rollback is proven and then undone.
      opts = [log: false, migration_lock: false]

      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      refute table_exists?("evidence_artifacts")

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
      assert table_exists?("evidence_artifacts")
    end
  end

  # One full lifecycle, expressed as data, so the two adapters can be compared
  # rather than described as equivalent.
  defp sequence(authority, project_id) do
    attrs = DeliveryFixtures.artifact_attrs(content: DeliveryFixtures.png_bytes("parity"))
    ref = ArtifactStore.ref_for(attrs.digest)

    [
      ArtifactStore.fetch(authority, project_id, ref),
      ArtifactStore.put(authority, project_id, attrs),
      ArtifactStore.put(authority, project_id, attrs),
      ArtifactStore.put(authority, project_id, %{attrs | content_type: "text/plain"}),
      ArtifactStore.put(authority, project_id, %{attrs | redacted: true}),
      ArtifactStore.put(authority, project_id, %{attrs | content_type: "application/zip"}),
      ArtifactStore.fetch(authority, project_id, ref),
      ArtifactStore.stat(authority, project_id, ref),
      ArtifactStore.list_refs(authority, project_id),
      ArtifactStore.delete(authority, project_id, ref),
      ArtifactStore.fetch(authority, project_id, ref),
      ArtifactStore.delete(authority, project_id, ref),
      ArtifactStore.list_refs(authority, project_id),
      ArtifactStore.delete_project(authority, project_id)
    ]
  end

  defp empty_digest, do: :sha256 |> :crypto.hash("") |> Base.encode16(case: :lower)

  defp record_evidence(authority, project, feature, overrides) do
    unique = System.unique_integer([:positive])
    revision = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: revision,
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
            effective_revision_digest: revision,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            fence_token: 1
          }}}
      ])

    attrs =
      Map.merge(
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: run.id,
          attempt_id: attempt.id,
          command_id: "cmd-#{unique}",
          kind: "screenshot",
          name: "board on mobile",
          outcome: "passed",
          duration_ms: 120,
          branch: run.branch,
          commit_sha: @commit,
          source: "worker",
          digest: DeliveryFixtures.digest("shot-#{unique}")
        },
        Map.new(overrides)
      )

    {:ok, %{evidence: evidence}} =
      DeliveryStore.commit(authority, project.id, [{:evidence, {:insert_evidence, attrs}}])

    evidence
  end

  # Inserted without the changeset so the constraint under test is the one the
  # database itself holds, not the one the schema restates.
  defp raw_insert!(project, overrides) do
    attrs =
      Map.merge(
        %{
          project_id: project.id,
          digest: DeliveryFixtures.digest("raw"),
          content_type: "image/png",
          byte_size: 70,
          redacted: false,
          content: DeliveryFixtures.png_bytes()
        },
        overrides
      )

    %EvidenceArtifact{} |> Ecto.Changeset.change(attrs) |> Repo.insert!()
  end

  defp table_exists?(table) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM information_schema.tables WHERE table_name = $1",
        [table]
      )

    count == 1
  end

  defp migration_module do
    module = SddOrchestrator.Repo.Migrations.CreateEvidenceArtifacts

    if Code.ensure_loaded?(module) do
      module
    else
      path =
        Path.join([
          File.cwd!(),
          "priv/repo/migrations/20260730000000_create_evidence_artifacts.exs"
        ])

      [{loaded, _binary} | _rest] = Code.compile_file(path)
      loaded
    end
  end
end
