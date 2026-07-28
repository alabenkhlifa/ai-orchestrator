defmodule SddOrchestrator.Portability.PackageEncryptionTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Portability.{
    PackageCodec,
    PackageEncryption,
    PackageSection,
    ProjectPackage
  }

  @fast [time_cost: 1, memory_kib: 1_024, parallelism: 1]

  test "derives an Argon2id key and round trips one authenticated package" do
    package = package()

    assert {:ok, encrypted} =
             PackageEncryption.encrypt(package, "correct horse battery staple", @fast)

    refute encrypted =~ "correct horse battery staple"
    refute encrypted =~ "private requirements"

    assert {:ok, decrypted} =
             PackageEncryption.decrypt(
               encrypted,
               "correct horse battery staple",
               max_decompressed_bytes: 1_000_000
             )

    assert decrypted == package

    assert {:ok, envelope, body} = PackageCodec.unframe(encrypted)
    assert envelope["kdf"] == "argon2id"
    assert envelope["kdf_time_cost"] == 1
    assert envelope["kdf_memory_kib"] == 1_024
    assert envelope["kdf_parallelism"] == 1
    assert envelope["encryption"] == "aes-256-gcm"
    assert envelope["tag_length"] == 16
    assert envelope["body_length"] == byte_size(body)
  end

  test "returns one opaque failure for missing, incorrect, or corrupt package control" do
    assert {:ok, encrypted} =
             PackageEncryption.encrypt(package(), "valid passphrase", @fast)

    assert {:error, :invalid_package_or_passphrase} =
             PackageEncryption.decrypt(encrypted, "")

    assert {:error, :invalid_package_or_passphrase} =
             PackageEncryption.decrypt(encrypted, "incorrect")

    corrupted = flip_last_byte(encrypted)

    assert {:error, :invalid_package_or_passphrase} =
             PackageEncryption.decrypt(corrupted, "valid passphrase")
  end

  test "authenticates every cleartext envelope field as additional data" do
    assert {:ok, encrypted} =
             PackageEncryption.encrypt(package(), "valid passphrase", @fast)

    assert {:ok, envelope, body} = PackageCodec.unframe(encrypted)

    for {field, value} <- [
          {"format_version", 2},
          {"payload_schema_version", 2},
          {"kdf_time_cost", 2},
          {"kdf_memory_kib", 2_048},
          {"nonce", Base.encode64(:crypto.strong_rand_bytes(12))},
          {"salt", Base.encode64(:crypto.strong_rand_bytes(16))}
        ] do
      assert {:ok, tampered} = PackageCodec.frame(Map.put(envelope, field, value), body)

      assert {:error, :invalid_package_or_passphrase} =
               PackageEncryption.decrypt(tampered, "valid passphrase")
    end
  end

  test "uses unique random salt and nonce for every encryption" do
    assert {:ok, first} =
             PackageEncryption.encrypt(package(), "valid passphrase", @fast)

    assert {:ok, second} =
             PackageEncryption.encrypt(package(), "valid passphrase", @fast)

    assert first != second
    assert {:ok, first_envelope, _body} = PackageCodec.unframe(first)
    assert {:ok, second_envelope, _body} = PackageCodec.unframe(second)
    assert first_envelope["salt"] != second_envelope["salt"]
    assert first_envelope["nonce"] != second_envelope["nonce"]
  end

  test "keeps passphrases and derived keys out of persistence and failure logs" do
    passphrase = "not-persisted-passphrase"

    assert {:ok, encrypted} =
             PackageEncryption.encrypt(package(), passphrase, @fast)

    log =
      capture_log(fn ->
        assert {:error, :invalid_package_or_passphrase} =
                 PackageEncryption.decrypt(encrypted, "wrong-passphrase")
      end)

    refute log =~ passphrase
    refute log =~ "wrong-passphrase"
    refute inspect(encrypted) =~ passphrase

    {:ok, %{rows: rows}} =
      Repo.query("""
      SELECT table_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND column_name IN ('passphrase', 'derived_key', 'encryption_key')
      """)

    assert rows == []
  end

  test "reproduces the committed encrypted golden fixture with fixed test material" do
    opts =
      @fast ++
        [
          salt: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>,
          nonce: <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27>>
        ]

    assert {:ok, encrypted} =
             PackageEncryption.encrypt(package(), "golden passphrase", opts)

    expected =
      Path.expand("../../fixtures/portability/project_package_v1.encrypted.b64", __DIR__)
      |> File.read!()
      |> String.trim()
      |> Base.decode64!()

    assert encrypted == expected

    assert {:ok, decrypted} =
             PackageEncryption.decrypt(encrypted, "golden passphrase")

    assert decrypted == package()
  end

  defp package do
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

    specifications =
      section(:specifications, [
        %{
          "id" => "018f4f36-8a11-7d44-9d65-6f0f565f4be2",
          "title" => "Refund approval",
          "requirements" => "private requirements",
          "design" => "private design",
          "tasks" => "private tasks"
        }
      ])

    {:ok, package} = ProjectPackage.new(project, repository, specifications)
    package
  end

  defp section(name, content) do
    {:ok, section} = PackageSection.new(name, 1, content)
    section
  end

  defp flip_last_byte(binary) do
    size = byte_size(binary) - 1
    <<prefix::binary-size(^size), last>> = binary
    prefix <> <<Bitwise.bxor(last, 1)>>
  end
end
