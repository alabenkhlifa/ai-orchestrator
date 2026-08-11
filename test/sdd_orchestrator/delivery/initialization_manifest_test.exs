defmodule SddOrchestrator.Delivery.InitializationManifestTest do
  @moduledoc """
  Task 1 proof: manifest enforced-key rejection for the pre-project,
  project-independent `InitializationManifest`.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.Delivery.InitializationManifest
  alias SddOrchestrator.InitializationDispatchFixtures, as: Fixtures

  describe "encoding" do
    test "produces identical bytes and digests regardless of attribute order" do
      attrs = Fixtures.manifest_attrs()
      reordered = attrs |> Enum.reverse() |> Map.new()

      assert {:ok, original} = InitializationManifest.new(attrs)
      assert {:ok, shuffled} = InitializationManifest.new(reordered)

      assert InitializationManifest.encode(original) == InitializationManifest.encode(shuffled)
      assert InitializationManifest.digest(original) == InitializationManifest.digest(shuffled)
    end

    test "round trips through its protocol representation" do
      manifest = Fixtures.manifest()

      assert {:ok, encoded} = InitializationManifest.encode(manifest)
      assert {:ok, decoded} = InitializationManifest.decode(encoded)
      assert decoded == manifest
      assert InitializationManifest.digest(decoded) == InitializationManifest.digest(manifest)

      assert {:ok, ^manifest} =
               manifest |> InitializationManifest.to_map() |> InitializationManifest.from_map()
    end
  end

  describe "digest/1" do
    test "changes when any bound field changes" do
      baseline = InitializationManifest.digest(Fixtures.manifest())

      changes = [
        %{"capability_grant" => "staging_write"},
        %{"agent_ref" => %{"provider_ref" => "other-agent", "model_ref" => "configured-model"}},
        %{"instructions" => %{"kind" => "plan_discovery_turn", "message" => "different turn"}}
      ]

      digests = Enum.map(changes, &InitializationManifest.digest(Fixtures.manifest(&1)))

      refute baseline in digests
      assert length(Enum.uniq(digests)) == length(changes)
    end

    test "stays stable across repeated computation" do
      manifest = Fixtures.manifest()
      digests = Enum.map(1..25, fn _index -> InitializationManifest.digest(manifest) end)

      assert length(Enum.uniq(digests)) == 1
      assert String.match?(hd(digests), ~r/\A[0-9a-f]{64}\z/)
    end
  end

  describe "field validation" do
    test "rejects a missing manifest field" do
      for key <- Map.keys(Fixtures.manifest_attrs()) do
        attrs = Map.delete(Fixtures.manifest_attrs(), key)

        assert {:error, :missing_manifest_field} = InitializationManifest.new(attrs),
               "key: #{key}"
      end
    end

    test "rejects an unknown extra field" do
      attrs = Map.put(Fixtures.manifest_attrs(), "unexpected", "value")
      assert {:error, :unknown_manifest_field} = InitializationManifest.new(attrs)
    end

    test "rejects an unsupported manifest version" do
      assert {:error, :unsupported_manifest_version} =
               InitializationManifest.new(Fixtures.manifest_attrs(%{"manifest_version" => 2}))

      assert {:error, :unsupported_manifest_version} =
               InitializationManifest.from_map(
                 Fixtures.manifest_attrs(%{"manifest_version" => 2})
               )
    end

    test "rejects a device_workspace_id that is not a UUID" do
      assert {:error, :invalid_device_workspace_id} =
               InitializationManifest.new(
                 Fixtures.manifest_attrs(%{"device_workspace_id" => "not-a-uuid"})
               )
    end

    test "rejects a dispatch_id that fails the shared protocol id format" do
      assert {:error, :invalid_dispatch_id} =
               InitializationManifest.new(
                 Fixtures.manifest_attrs(%{"dispatch_id" => "has a space"})
               )

      assert {:error, :invalid_dispatch_id} =
               InitializationManifest.new(Fixtures.manifest_attrs(%{"dispatch_id" => ""}))
    end

    test "rejects a capability_grant outside the known enum" do
      assert {:error, :invalid_capability_grant} =
               InitializationManifest.new(
                 Fixtures.manifest_attrs(%{"capability_grant" => "delete_everything"})
               )
    end

    test "rejects a malformed agent_ref" do
      assert {:error, :invalid_agent_ref} =
               InitializationManifest.new(Fixtures.manifest_attrs(%{"agent_ref" => "not-a-map"}))

      assert {:error, :invalid_agent_ref} =
               InitializationManifest.new(
                 Fixtures.manifest_attrs(%{"agent_ref" => %{"provider_ref" => 1}})
               )
    end

    test "rejects instructions that are not a plain map" do
      assert {:error, :invalid_instructions} =
               InitializationManifest.new(
                 Fixtures.manifest_attrs(%{"instructions" => "not-a-map"})
               )
    end

    test "rejects secret-bearing agent_ref content" do
      attrs = Fixtures.manifest_attrs(%{"agent_ref" => %{"api_key" => "ghp_notreal"}})
      assert {:error, :secret_field_rejected} = InitializationManifest.new(attrs)
    end

    test "rejects secret-bearing instructions content" do
      attrs =
        Fixtures.manifest_attrs(%{
          "instructions" => %{"kind" => "plan_discovery_turn", "password" => "hunter2"}
        })

      assert {:error, :secret_field_rejected} = InitializationManifest.new(attrs)
    end

    test "rejects raw credential material inside instructions" do
      attrs =
        Fixtures.manifest_attrs(%{
          "instructions" => %{"kind" => "plan_discovery_turn", "note" => "-----BEGIN KEY-----"}
        })

      assert {:error, :secret_material_rejected} = InitializationManifest.new(attrs)
    end

    test "rejects a non-map payload entirely" do
      assert {:error, :invalid_manifest} = InitializationManifest.new("not-a-map")
      assert {:error, :invalid_manifest} = InitializationManifest.from_map("not-a-map")
      assert {:error, :invalid_json} = InitializationManifest.decode("not-json")
    end
  end
end
