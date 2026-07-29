defmodule SddOrchestrator.Delivery.ExecutionManifestTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.DeliveryProtocolFixtures, as: Fixtures

  @fixtures Path.expand("../../fixtures/delivery", __DIR__)

  describe "encoding" do
    test "encodes the exact byte-stable manifest fixture" do
      manifest = Fixtures.manifest()

      assert {:ok, encoded} = ExecutionManifest.encode(manifest)
      assert encoded == read_fixture("execution_manifest_v1.json")
    end

    test "produces identical bytes and digests regardless of attribute order" do
      attrs = Fixtures.manifest_attrs()
      reordered = attrs |> Enum.reverse() |> Map.new()

      assert {:ok, original} = ExecutionManifest.new(attrs)
      assert {:ok, shuffled} = ExecutionManifest.new(reordered)

      assert ExecutionManifest.encode(original) == ExecutionManifest.encode(shuffled)
      assert ExecutionManifest.digest(original) == ExecutionManifest.digest(shuffled)
    end

    test "round trips through its protocol representation" do
      manifest = Fixtures.manifest()

      assert {:ok, encoded} = ExecutionManifest.encode(manifest)
      assert {:ok, decoded} = ExecutionManifest.decode(encoded)
      assert decoded == manifest
      assert ExecutionManifest.digest(decoded) == ExecutionManifest.digest(manifest)

      assert {:ok, ^manifest} =
               manifest |> ExecutionManifest.to_map() |> ExecutionManifest.from_map()
    end
  end

  describe "digest/1" do
    test "matches the recorded fixture digest" do
      assert ExecutionManifest.digest(Fixtures.manifest()) ==
               read_fixture("execution_manifest_v1.digest")
    end

    test "changes when any bound field changes" do
      baseline = ExecutionManifest.digest(Fixtures.manifest())

      changes = [
        %{"attempt_number" => 2, "continuation" => continuation("manual_retry", 1)},
        %{"approved_slice" => "07-guided-specification-delivery-b"},
        %{"effective_revision_id" => "rev_01HZX0000000000000000009"},
        %{"effective_revision_digest" => String.duplicate("b2", 32)},
        %{"repository_base_revision" => "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d"},
        %{"target_branch" => "sdd/feature/ftr-0002/run-0004"},
        %{"required_checks" => [%{"name" => "test", "command" => "mix test"}]},
        %{"agent_ref" => %{"provider_ref" => "other-agent", "model_ref" => "configured-model"}},
        %{"worker_ref" => %{"execution_target_ref" => "configured-remote-worker"}}
      ]

      digests = Enum.map(changes, &ExecutionManifest.digest(Fixtures.manifest(&1)))

      refute baseline in digests
      assert length(Enum.uniq(digests)) == length(changes)
    end

    test "stays stable across repeated computation" do
      manifest = Fixtures.manifest()
      digests = Enum.map(1..25, fn _index -> ExecutionManifest.digest(manifest) end)

      assert length(Enum.uniq(digests)) == 1
      assert String.match?(hd(digests), ~r/\A[0-9a-f]{64}\z/)
    end
  end

  describe "field validation" do
    test "rejects a missing manifest field" do
      for key <- Map.keys(Fixtures.manifest_attrs()) do
        attrs = Map.delete(Fixtures.manifest_attrs(), key)
        assert {:error, :missing_manifest_field} = ExecutionManifest.new(attrs)
      end
    end

    test "rejects an unknown manifest field" do
      attrs = Map.put(Fixtures.manifest_attrs(), "workspace_path", "/tmp/run")
      assert {:error, :unknown_manifest_field} = ExecutionManifest.new(attrs)
    end

    test "rejects an unsupported manifest version" do
      assert {:error, :unsupported_manifest_version} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"manifest_version" => 2}))

      assert {:error, :unsupported_manifest_version} =
               ExecutionManifest.from_map(Fixtures.manifest_attrs(%{"manifest_version" => 99}))
    end

    test "rejects invalid identities, revisions, and branches" do
      cases = [
        {%{"project_id" => "prj 0001"}, :invalid_manifest_identity},
        {%{"run_id" => ""}, :invalid_manifest_identity},
        {%{"attempt_number" => 0}, :invalid_attempt_number},
        {%{"attempt_number" => "1"}, :invalid_attempt_number},
        {%{"approved_slice" => ""}, :invalid_approved_slice},
        {%{"starting_revision_id" => "rev id"}, :invalid_revision_id},
        {%{"starting_revision_digest" => "not-a-digest"}, :invalid_revision_digest},
        {%{"effective_revision_digest" => String.duplicate("A1", 32)}, :invalid_revision_digest},
        {%{"repository_base_revision" => "HEAD"}, :invalid_base_revision},
        {%{"target_branch" => "feature/../main"}, :invalid_target_branch},
        {%{"target_branch" => "-feature"}, :invalid_target_branch},
        {%{"target_branch" => "feature/"}, :invalid_target_branch},
        {%{"target_branch" => "feature branch"}, :invalid_target_branch}
      ]

      for {override, expected} <- cases do
        assert ExecutionManifest.new(Fixtures.manifest_attrs(override)) == {:error, expected}
      end
    end

    test "rejects malformed, duplicated, and oversized required checks" do
      assert {:error, :invalid_required_checks} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"required_checks" => "mix test"}))

      assert {:error, :invalid_required_check} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{"required_checks" => [%{"name" => "test"}]})
               )

      assert {:error, :invalid_required_check} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "required_checks" => [%{"name" => "", "command" => "mix test"}]
                 })
               )

      duplicates = [
        %{"name" => "test", "command" => "mix test"},
        %{"name" => "test", "command" => "mix test --stale"}
      ]

      assert {:error, :duplicate_required_check} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"required_checks" => duplicates}))

      too_many =
        Enum.map(1..51, fn index -> %{"name" => "check#{index}", "command" => "mix test"} end)

      assert {:error, :too_many_required_checks} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"required_checks" => too_many}))
    end

    test "accepts configured references and rejects malformed ones" do
      assert {:ok, _manifest} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"agent_ref" => %{}}))

      assert {:error, :invalid_agent_ref} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"agent_ref" => "configured"}))

      assert {:error, :invalid_worker_ref} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{"worker_ref" => %{"execution_target_ref" => 7}})
               )

      assert {:error, :invalid_worker_ref} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "worker_ref" => %{"execution_target_ref" => String.duplicate("r", 513)}
                 })
               )
    end

    test "binds the continuation reason to the attempt number" do
      assert {:ok, _manifest} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "attempt_number" => 3,
                   "continuation" => continuation("blocking_answer", 2)
                 })
               )

      assert {:error, :invalid_continuation} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"attempt_number" => 2}))

      assert {:error, :invalid_continuation} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "attempt_number" => 2,
                   "continuation" => continuation("review_feedback", 2)
                 })
               )

      assert {:error, :invalid_continuation_reason} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "attempt_number" => 2,
                   "continuation" => continuation("because", 1)
                 })
               )

      assert {:error, :invalid_continuation} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{"continuation" => %{"reason" => "initial"}})
               )
    end
  end

  describe "credential and size boundaries" do
    test "rejects raw credential fields anywhere in the manifest" do
      assert {:error, :secret_field_rejected} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "worker_ref" => %{"token" => "ghp_live_secret_value"}
                 })
               )

      assert {:error, :secret_field_rejected} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "agent_ref" => %{"API_KEY" => "sk-live-secret"}
                 })
               )

      assert {:error, :secret_material_rejected} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "agent_ref" => %{
                     "provider_ref" => "-----BEGIN OPENSSH PRIVATE KEY-----",
                     "model_ref" => "configured-model"
                   }
                 })
               )
    end

    test "keeps opaque configured references that only name a credential" do
      assert {:ok, manifest} =
               ExecutionManifest.new(
                 Fixtures.manifest_attrs(%{
                   "worker_ref" => %{"credential_ref" => "worker-vault://configured"}
                 })
               )

      assert manifest.worker_ref == %{"credential_ref" => "worker-vault://configured"}
    end

    test "rejects an oversized manifest" do
      oversized =
        Enum.map(1..40, fn index ->
          %{"name" => "check#{index}", "command" => String.duplicate("x", 8_000)}
        end)

      assert {:error, :manifest_too_large} =
               ExecutionManifest.new(Fixtures.manifest_attrs(%{"required_checks" => oversized}))
    end

    test "rejects malformed input before validation" do
      assert {:error, :invalid_manifest} = ExecutionManifest.new("manifest")
      assert {:error, :invalid_manifest} = ExecutionManifest.from_map(%{"run_id" => "run_1"})
      assert {:error, :invalid_json} = ExecutionManifest.decode(<<0xFF, 0xFE>>)
      assert {:error, :invalid_json} = ExecutionManifest.decode("{")
      assert {:error, :invalid_manifest} = ExecutionManifest.decode("[]")
    end
  end

  defp continuation(reason, prior),
    do: %{"reason" => reason, "prior_attempt_number" => prior}

  defp read_fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> String.trim_trailing("\n")
  end
end
