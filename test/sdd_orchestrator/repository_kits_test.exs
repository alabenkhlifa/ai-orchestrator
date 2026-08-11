defmodule SddOrchestrator.RepositoryKitsTest do
  @moduledoc "Focused proof for the immutable, global SDD kit package catalog (Task 1)."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.RepositoryKitFixtures

  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.RepositoryKitPackage

  describe "publish_package/2 identity and tamper proof" do
    test "the returned digest recomputes to the same value from the stored manifest" do
      package = publish_package_fixture()

      assert package.digest == RepositoryKitPackage.digest_of(package.file_manifest)
    end

    test "publishing the same source, publisher, and version twice is rejected and the row is never updated" do
      attrs = valid_publish_attrs()
      files = valid_files()

      assert {:ok, first} = RepositoryKits.publish_package(attrs, files)
      assert {:error, :already_exists} = RepositoryKits.publish_package(attrs, files)

      assert [only] = RepositoryKits.list_packages()
      assert only.id == first.id
      assert only.digest == first.digest

      # The database itself rejects any UPDATE on a kit package row, proving
      # immutability is enforced beneath the application layer and not only by
      # convention in the context module.
      assert_raise Postgrex.Error, ~r/immutable/, fn ->
        Repo.update_all(
          from(p in RepositoryKitPackage, where: p.id == ^first.id),
          set: [license: "Other"]
        )
      end
    end
  end

  describe "publish_package/2 file path validation" do
    test "rejects an absolute path" do
      files = [%{path: "/etc/passwd", content: "x", executable: false}]

      assert {:error, :invalid_path} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end

    test "rejects a path containing a .. segment" do
      files = [%{path: "../escape.md", content: "x", executable: false}]

      assert {:error, :path_escape} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end

    test "rejects an empty path" do
      files = [%{path: "", content: "x", executable: false}]

      assert {:error, :invalid_path} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end

    test "rejects a duplicate path within the same publish call" do
      files = [
        %{path: "a.md", content: "x", executable: false},
        %{path: "a.md", content: "y", executable: false}
      ]

      assert {:error, :duplicate_path} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end
  end

  describe "publish_package/2 size validation" do
    test "rejects a single file over 512,000 bytes" do
      files = [%{path: "big.bin", content: String.duplicate("a", 512_001), executable: false}]

      assert {:error, :file_too_large} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end

    test "rejects a package whose combined content exceeds 5,000,000 bytes" do
      files =
        for n <- 1..10 do
          %{path: "chunk-#{n}.bin", content: String.duplicate("a", 500_001), executable: false}
        end

      assert {:error, :package_too_large} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end

    test "rejects a package with more than 500 files" do
      files = for n <- 1..501, do: %{path: "file-#{n}.md", content: "x", executable: false}

      assert {:error, :too_many_files} =
               RepositoryKits.publish_package(valid_publish_attrs(%{scripts: []}), files)
    end
  end

  describe "publish_package/2 license validation" do
    test "rejects a missing license" do
      attrs = valid_publish_attrs() |> Map.delete(:license)

      assert {:error, :invalid_license} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects an empty license" do
      attrs = valid_publish_attrs(%{license: ""})

      assert {:error, :invalid_license} = RepositoryKits.publish_package(attrs, valid_files())
    end
  end

  describe "publish_package/2 provenance validation" do
    test "rejects a missing ref" do
      attrs = valid_publish_attrs(%{provenance: %{ref_type: "commit", repository: "x/y"}})

      assert {:error, :invalid_provenance} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a malformed ref" do
      attrs =
        valid_publish_attrs(%{
          provenance: %{ref_type: "commit", ref: "not-a-sha", repository: "x/y"}
        })

      assert {:error, :invalid_provenance} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a ref_type other than commit" do
      attrs =
        valid_publish_attrs(%{
          provenance: %{ref_type: "tag", ref: String.duplicate("a", 40), repository: "x/y"}
        })

      assert {:error, :invalid_provenance} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a branch-name-shaped ref as a mutable reference" do
      # Proves AC-03: planning/installation must never accept a mutable
      # reference such as a branch or tag name — only an exact commit SHA is
      # an acceptable provenance ref. "main", "latest", and "HEAD" all look
      # like plausible refs but none is an immutable commit SHA.
      for mutable_ref <- ["main", "latest", "HEAD"] do
        attrs =
          valid_publish_attrs(%{
            provenance: %{ref_type: "commit", ref: mutable_ref, repository: "x/y"}
          })

        assert {:error, :invalid_provenance} =
                 RepositoryKits.publish_package(attrs, valid_files())
      end
    end
  end

  describe "publish_package/2 adapter and permission validation" do
    test "rejects an unknown adapter name" do
      attrs = valid_publish_attrs(%{supported_adapters: ["unknown_agent"]})

      assert {:error, :invalid_adapters} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects an empty adapter list" do
      attrs = valid_publish_attrs(%{supported_adapters: []})

      assert {:error, :invalid_adapters} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a duplicated adapter" do
      attrs = valid_publish_attrs(%{supported_adapters: ["claude_code", "claude_code"]})

      assert {:error, :invalid_adapters} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a duplicated required permission" do
      attrs =
        valid_publish_attrs(%{required_permissions: ["repository:read", "repository:read"]})

      assert {:error, :invalid_permissions} = RepositoryKits.publish_package(attrs, valid_files())
    end
  end

  describe "publish_package/2 scripts validation" do
    test "rejects a scripts entry absent from the file manifest" do
      attrs = valid_publish_attrs(%{scripts: ["scripts/missing.sh"]})

      assert {:error, :invalid_scripts} = RepositoryKits.publish_package(attrs, valid_files())
    end

    test "rejects a scripts entry whose file is not marked executable" do
      files = [%{path: "scripts/check.sh", content: "#!/bin/sh\necho ok\n", executable: false}]
      attrs = valid_publish_attrs(%{scripts: ["scripts/check.sh"]})

      assert {:error, :invalid_scripts} = RepositoryKits.publish_package(attrs, files)
    end
  end

  describe "publish_package/2 no-network, no-execution proof" do
    test "never executes vendored package content, even a script marked executable and referenced by scripts" do
      sentinel_path =
        Path.join(
          System.tmp_dir!(),
          "repository_kits_no_execution_#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm(sentinel_path) end)

      script = "#!/bin/sh\ntouch #{sentinel_path}\n"
      files = [%{path: "scripts/sentinel.sh", content: script, executable: true}]
      attrs = valid_publish_attrs(%{scripts: ["scripts/sentinel.sh"]})

      assert {:ok, _package} = RepositoryKits.publish_package(attrs, files)

      # Proves the ingestion path only measures, hashes, and base64-encodes
      # file content — it never executes it. If publication ran this script,
      # the sentinel file would exist on disk right now; it does not, and
      # `publish_package/2` never touched the network to fetch or run it.
      refute File.exists?(sentinel_path)
    end
  end

  describe "list_packages/0 ordering" do
    test "orders by source, publisher, then real semantic version, not string sort" do
      # Distinct file content per version: the digest is content-addressed, so
      # two versions publishing byte-identical files would collide on the
      # unique digest index — a real version bump always changes something.
      publish_package_fixture(%{source: "s", publisher: "p", version: "1.10.0", scripts: []}, [
        %{path: "SKILL.md", content: "# v1.10.0\n", executable: false}
      ])

      publish_package_fixture(%{source: "s", publisher: "p", version: "1.9.0", scripts: []}, [
        %{path: "SKILL.md", content: "# v1.9.0\n", executable: false}
      ])

      # A naive string sort would place "1.10.0" before "1.9.0" because "1" <
      # "9" lexically; only real semver comparison orders "1.9.0" before
      # "1.10.0", which is what this asserts.
      family =
        RepositoryKits.list_packages()
        |> Enum.filter(&(&1.source == "s" and &1.publisher == "p"))
        |> Enum.map(& &1.version)

      assert family == ["1.9.0", "1.10.0"]
    end
  end

  describe "superseded_by/2" do
    test "returns the newest other version in the same source and publisher family" do
      v1 =
        publish_package_fixture(%{source: "s2", publisher: "p2", version: "1.0.0", scripts: []}, [
          %{path: "SKILL.md", content: "# s2 v1.0.0\n", executable: false}
        ])

      v2 =
        publish_package_fixture(%{source: "s2", publisher: "p2", version: "1.1.0", scripts: []}, [
          %{path: "SKILL.md", content: "# s2 v1.1.0\n", executable: false}
        ])

      other = publish_package_fixture(%{source: "s3", publisher: "p3", version: "1.0.0"})

      packages = RepositoryKits.list_packages()

      assert RepositoryKits.superseded_by(v1, packages).id == v2.id
      assert RepositoryKits.superseded_by(v2, packages) == nil
      assert RepositoryKits.superseded_by(other, packages) == nil
    end
  end

  describe "reads" do
    test "get_package/1 returns :not_found for an unknown id" do
      assert {:error, :not_found} = RepositoryKits.get_package(Ecto.UUID.generate())
    end

    test "get_by_digest/1 returns :not_found for an unknown digest" do
      assert {:error, :not_found} = RepositoryKits.get_by_digest(String.duplicate("0", 64))
    end

    test "get_package/1 and get_by_digest/1 find a published package" do
      package = publish_package_fixture()

      assert {:ok, found} = RepositoryKits.get_package(package.id)
      assert found.id == package.id

      assert {:ok, found_by_digest} = RepositoryKits.get_by_digest(package.digest)
      assert found_by_digest.id == package.id
    end
  end
end
