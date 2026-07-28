defmodule SddOrchestrator.Portability.PackageCodecTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.Portability.{PackageCodec, PackageSection, ProjectPackage}

  @fixtures Path.expand("../../fixtures/portability", __DIR__)

  test "encodes the exact byte-stable payload and package fixtures" do
    package = fixture_package()

    assert {:ok, payload} = PackageCodec.encode_payload(package)

    expected_payload =
      @fixtures
      |> Path.join("project_package_v1.json")
      |> File.read!()
      |> String.trim_trailing()

    assert payload == expected_payload

    assert {:ok, encoded_once} = PackageCodec.encode(package)
    assert {:ok, encoded_twice} = PackageCodec.encode(package)
    assert encoded_once == encoded_twice

    expected =
      @fixtures
      |> Path.join("project_package_v1.sddpkg.b64")
      |> File.read!()
      |> String.trim()
      |> Base.decode64!()

    assert encoded_once == expected
  end

  test "sorts object keys while preserving the fixed logical section order" do
    package = fixture_package()

    reordered =
      put_in(package.repository.content, Map.new(Enum.reverse(package.repository.content)))

    assert {:ok, original} = PackageCodec.encode_payload(package)
    assert {:ok, deterministic} = PackageCodec.encode_payload(reordered)
    assert original == deterministic

    assert {:ok, decoded} = Jason.decode(original)

    assert Enum.map(decoded["sections"], & &1["name"]) == [
             "project",
             "repository",
             "specifications"
           ]

    assert Enum.map(decoded["sections"], & &1["version"]) == [1, 1, 1]
    assert decoded["payload_schema_version"] == 1
  end

  test "round trips the package without consulting project persistence" do
    package = fixture_package()

    assert {:ok, encoded} = PackageCodec.encode(package)
    assert {:ok, decoded} = PackageCodec.decode(encoded)
    assert decoded == package

    assert {:ok, envelope, body} = PackageCodec.unframe(encoded)

    assert envelope == %{
             "body_length" => byte_size(body),
             "compression" => "deflate",
             "format" => "sdd-orchestrator-project-package",
             "format_version" => 1,
             "payload_schema_version" => 1
           }
  end

  test "rejects malformed and inconsistent single-file frames" do
    assert {:error, :malformed_frame} = PackageCodec.unframe("not-a-package")
    assert {:error, :malformed_frame} = PackageCodec.unframe(<<"SDDPKG\r\n", 100::32, "{}">>)

    assert {:ok, encoded} = PackageCodec.encode(fixture_package())

    <<prefix::binary-size(8), header_size::32, header::binary-size(header_size), body::binary>> =
      encoded

    shortened =
      <<prefix::binary, header_size::32, header::binary,
        binary_part(body, 1, byte_size(body) - 1)::binary>>

    assert {:error, :body_length_mismatch} = PackageCodec.unframe(shortened)

    assert {:error, :body_length_mismatch} = PackageCodec.unframe(encoded <> "trailing")
  end

  test "enforces the decompressed byte ceiling before returning payload data" do
    payload = String.duplicate("bounded-payload-", 1_000)

    assert {:ok, compressed} = PackageCodec.compress(payload)
    assert {:ok, ^payload} = PackageCodec.decompress(compressed, byte_size(payload))

    assert {:error, :decompressed_size_exceeded} =
             PackageCodec.decompress(compressed, byte_size(payload) - 1)
  end

  test "rejects invalid section order and versions" do
    project = section(:project, %{"id" => "project-1", "name" => "Payments"})
    repository = section(:repository, %{"provider" => "github", "repository_id" => "42"})
    specifications = section(:specifications, [])

    assert {:error, :invalid_section_order} =
             ProjectPackage.new(repository, project, specifications)

    invalid = %{fixture_package() | project: %{project | version: 2}}
    assert {:error, :invalid_package} = PackageCodec.encode_payload(invalid)
  end

  defp fixture_package do
    project =
      section(:project, %{
        "name" => "Payments",
        "id" => "018f4f36-8a11-7d44-9d65-6f0f565f4be1"
      })

    repository =
      section(:repository, %{
        "repository_id" => "847201",
        "provider" => "github"
      })

    specifications =
      section(:specifications, [
        %{
          "title" => "Refund approval",
          "tasks" => "# Tasks\n\n- [ ] Implement approval",
          "requirements" => "# Requirements\n\nApprove refunds safely.",
          "id" => "refund-approval",
          "design" => "# Design\n\nUse one transaction."
        }
      ])

    {:ok, package} = ProjectPackage.new(project, repository, specifications)
    package
  end

  defp section(name, content) do
    {:ok, section} = PackageSection.new(name, 1, content)
    section
  end
end
