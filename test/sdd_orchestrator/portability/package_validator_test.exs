defmodule SddOrchestrator.Portability.PackageValidatorTest do
  use SddOrchestrator.DataCase, async: false
  use ExUnitProperties

  alias SddOrchestrator.Portability.{
    PackageCodec,
    PackageEncryption,
    PackageSection,
    PackageValidator,
    ProjectPackage
  }

  alias SddOrchestrator.{ProjectsFixtures, Repo}

  test "accepts a compatible encrypted package without creating project state" do
    package = valid_package()
    {:ok, encrypted} = PackageEncryption.encrypt(package, "validation phrase")

    assert :ok = PackageValidator.validate_encrypted_container(encrypted)

    assert {:ok, ^package} =
             PackageValidator.decrypt_and_validate(encrypted, "validation phrase")

    assert Repo.aggregate(SddOrchestrator.Portability.ImportAttempt, :count) == 0
    assert Repo.aggregate(SddOrchestrator.Projects.Project, :count) == 0
  end

  test "rejects an unsupported format or payload major before decryption" do
    {:ok, encrypted} = PackageEncryption.encrypt(valid_package(), "version phrase")
    {:ok, envelope, body} = PackageCodec.unframe(encrypted)

    {:ok, unsupported_format} =
      envelope |> Map.put("format_version", 2) |> PackageCodec.frame(body)

    assert {:error, :unsupported_version} =
             PackageValidator.validate_encrypted_container(unsupported_format)

    {:ok, unsupported_payload} =
      envelope |> Map.put("payload_schema_version", 2) |> PackageCodec.frame(body)

    assert {:error, :unsupported_version} =
             PackageValidator.validate_encrypted_container(unsupported_payload)
  end

  test "rejects missing, invalid, or resource-exhausting encryption parameters" do
    {:ok, encrypted} = PackageEncryption.encrypt(valid_package(), "parameter phrase")
    {:ok, envelope, body} = PackageCodec.unframe(encrypted)

    for invalid_envelope <- [
          Map.delete(envelope, "salt"),
          Map.put(envelope, "salt", "not-base64"),
          Map.put(envelope, "nonce", Base.encode64("short")),
          Map.put(envelope, "kdf_time_cost", 11),
          Map.put(envelope, "kdf_memory_kib", 524_288),
          Map.put(envelope, "kdf_parallelism", 5)
        ] do
      {:ok, invalid} = PackageCodec.frame(invalid_envelope, body)

      assert {:error, :malformed_package} =
               PackageValidator.validate_encrypted_container(invalid)
    end
  end

  test "ignores unknown additive fields inside the supported major" do
    package = valid_package()
    payload = payload_map(package)

    [project, repository, specifications] = payload["sections"]

    additive =
      payload
      |> Map.put("future_top_level", %{"enabled" => true})
      |> Map.put("sections", [
        project
        |> Map.put("future_section_field", "ignored")
        |> update_in(["content"], &Map.put(&1, "future_project_field", "ignored")),
        repository,
        update_in(specifications, ["content"], fn [specification] ->
          [Map.put(specification, "future_specification_field", "ignored")]
        end)
      ])

    assert {:ok, decoded} = additive |> Jason.encode!() |> PackageCodec.decode_payload()
    assert decoded == package
  end

  test "rejects duplicate keys, non-finite numbers, and malformed sections" do
    duplicate =
      ~s({"payload_schema_version":1,"payload_schema_version":1,"sections":[]})

    assert {:error, :duplicate_json_key} = PackageCodec.decode_payload(duplicate)

    assert {:error, :invalid_json} =
             PackageCodec.decode_payload(~s({"payload_schema_version":1e999,"sections":[]}))

    malformed =
      payload_map(valid_package())
      |> put_in(["sections", Access.at(0), "version"], 2)
      |> Jason.encode!()

    assert {:error, :invalid_section} = PackageCodec.decode_payload(malformed)
  end

  test "rejects attachment, filesystem, repository-source, and executable shapes" do
    for forbidden <- ["attachments", "path", "repository_source", "executable"] do
      payload =
        payload_map(valid_package())
        |> update_in(["sections", Access.at(2), "content", Access.at(0)], fn specification ->
          Map.put(specification, forbidden, "forbidden")
        end)
        |> Jason.encode!()

      assert {:error, :prohibited_payload_content} = PackageCodec.decode_payload(payload)
    end
  end

  test "enforces encrypted, decompressed, and expansion-ratio ceilings" do
    with_limit(:max_encrypted_package_bytes, 32, fn ->
      assert {:error, :package_too_large} =
               PackageValidator.validate_encrypted_container(String.duplicate("x", 33))
    end)

    payload = String.duplicate("highly-compressible-", 5_000)
    {:ok, compressed} = PackageCodec.compress(payload)

    assert {:error, :decompressed_size_exceeded} =
             PackageCodec.decompress(compressed, byte_size(payload) - 1)

    assert {:error, :expansion_ratio_exceeded} =
             PackageCodec.decompress(compressed, byte_size(payload), 2)
  end

  test "enforces specification count, document, and field-length limits" do
    too_many =
      package_with_specifications(for _index <- 1..101, do: valid_specification())

    assert {:error, :unsafe_package} = PackageValidator.validate(too_many)

    oversized_document =
      valid_package()
      |> put_in(
        [
          Access.key!(:specifications),
          Access.key!(:content),
          Access.at(0),
          "requirements"
        ],
        String.duplicate("r", 256 * 1_024 + 1)
      )

    assert {:error, :unsafe_package} = PackageValidator.validate(oversized_document)

    oversized_name =
      valid_package()
      |> put_in(
        [Access.key!(:project), Access.key!(:content), "name"],
        String.duplicate("n", 201)
      )

    assert {:error, :unsafe_package} = PackageValidator.validate(oversized_name)
  end

  test "rejects duplicate or malformed stable identities and unsupported providers" do
    duplicate_id = Ecto.UUID.generate()

    duplicate_specs =
      package_with_specifications([
        valid_specification(%{"id" => duplicate_id}),
        valid_specification(%{"id" => duplicate_id})
      ])

    assert {:error, :unsafe_package} = PackageValidator.validate(duplicate_specs)

    malformed_id =
      valid_package()
      |> put_in([Access.key!(:project), Access.key!(:content), "id"], "not-a-uuid")

    assert {:error, :unsafe_package} = PackageValidator.validate(malformed_id)

    unsupported_provider =
      valid_package()
      |> put_in(
        [Access.key!(:repository), Access.key!(:content), "provider"],
        "unapproved"
      )

    assert {:error, :unsafe_package} = PackageValidator.validate(unsupported_provider)
  end

  test "accepts only the versioned portable identity for local repositories" do
    portable_identity = ProjectsFixtures.local_repository_metadata().fingerprint

    portable =
      valid_package()
      |> put_in([Access.key!(:repository), Access.key!(:content)], %{
        "provider" => "local",
        "repository_id" => portable_identity
      })

    assert :ok = PackageValidator.validate(portable)

    for rejected_identity <- [
          Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          "local-repo:v1:not-canonical",
          "not-a-repository-identity"
        ] do
      rejected =
        put_in(
          portable,
          [Access.key!(:repository), Access.key!(:content), "repository_id"],
          rejected_identity
        )

      assert {:error, :unsafe_package} = PackageValidator.validate(rejected)
    end
  end

  property "arbitrary untrusted bytes never crash encrypted-container validation" do
    check all(bytes <- binary(max_length: 512), max_runs: 75) do
      assert PackageValidator.validate_encrypted_container(bytes) in [
               :ok,
               {:error, :malformed_package},
               {:error, :unsupported_version}
             ]
    end
  end

  defp valid_package do
    package_with_specifications([valid_specification()])
  end

  defp package_with_specifications(specifications) do
    project =
      section(:project, %{
        "id" => "018f4f36-8a11-7d44-9d65-6f0f565f4be1",
        "name" => "Payments"
      })

    repository =
      section(:repository, %{
        "provider" => "github",
        "repository_id" => "847201"
      })

    specification_section = section(:specifications, specifications)
    {:ok, package} = ProjectPackage.new(project, repository, specification_section)
    package
  end

  defp valid_specification(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => Ecto.UUID.generate(),
        "title" => "Refund approval",
        "requirements" => "# Requirements",
        "design" => "# Design",
        "tasks" => "# Tasks"
      },
      overrides
    )
  end

  defp payload_map(package) do
    {:ok, payload} = PackageCodec.encode_payload(package)
    Jason.decode!(payload)
  end

  defp section(name, content) do
    {:ok, section} = PackageSection.new(name, 1, content)
    section
  end

  defp with_limit(name, value, fun) do
    original = Application.fetch_env!(:sdd_orchestrator, :portability_limits)

    Application.put_env(
      :sdd_orchestrator,
      :portability_limits,
      Keyword.put(original, name, value)
    )

    try do
      fun.()
    after
      Application.put_env(:sdd_orchestrator, :portability_limits, original)
    end
  end
end
