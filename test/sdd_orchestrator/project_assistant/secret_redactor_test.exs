defmodule SddOrchestrator.ProjectAssistant.SecretRedactorTest do
  @moduledoc """
  specs/12-project-assistant Task 9 focused proof: content-level credential,
  token, private-key, and minimal personal-data redaction (AC-19).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.SecretRedactor

  describe "redact/1" do
    test "passes nil and non-binary values through unchanged" do
      assert SecretRedactor.redact(nil) == nil
      assert SecretRedactor.redact(42) == 42
    end

    test "leaves ordinary text unchanged" do
      text = "The current specification is Read-only project assistant."
      assert SecretRedactor.redact(text) == text
    end

    test "redacts a PEM-shaped private key block" do
      text = """
      before
      -----BEGIN RSA PRIVATE KEY-----
      MIIBogIBAAJBAK...
      -----END RSA PRIVATE KEY-----
      after
      """

      redacted = SecretRedactor.redact(text)
      refute redacted =~ "MIIBogIBAAJBAK"
      assert redacted =~ "[redacted]"
      assert redacted =~ "before"
      assert redacted =~ "after"
    end

    test "redacts a GitHub-shaped personal access token" do
      redacted = SecretRedactor.redact("token: ghp_abcdefghijklmnopqrstuvwxyz0123456789")
      refute redacted =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
      assert redacted =~ "[redacted]"
    end

    test "redacts an OpenAI-shaped secret key" do
      redacted = SecretRedactor.redact("key sk-aaaaaaaaaaaaaaaaaaaaaaaa here")
      refute redacted =~ "sk-aaaaaaaaaaaaaaaaaaaaaaaa"
      assert redacted =~ "[redacted]"
    end

    test "redacts an AWS-shaped access key id" do
      redacted = SecretRedactor.redact("AKIAABCDEFGHIJKLMNOP")
      assert redacted == "[redacted]"
    end

    test "redacts a bearer token" do
      redacted = SecretRedactor.redact("Authorization: Bearer abcDEF123.456~789")
      refute redacted =~ "abcDEF123.456~789"
      assert redacted =~ "[redacted]"
    end

    test "redacts generic token and password assignments" do
      assert SecretRedactor.redact("access_token: abc123xyz") =~ "[redacted]"
      assert SecretRedactor.redact("password=hunter2hunter2") =~ "[redacted]"
      assert SecretRedactor.redact("client_secret=verysecretvalue123") =~ "[redacted]"
    end

    test "redacts an email address" do
      redacted = SecretRedactor.redact("Contact ada@example.com for access")
      refute redacted =~ "ada@example.com"
      assert redacted =~ "[redacted]"
      assert redacted =~ "Contact"
      assert redacted =~ "for access"
    end

    test "redacts every occurrence, not just the first" do
      redacted =
        SecretRedactor.redact("sk-aaaaaaaaaaaaaaaaaaaaaaaa and sk-bbbbbbbbbbbbbbbbbbbbbbbb")

      refute redacted =~ "sk-aaaaaaaaaaaaaaaaaaaaaaaa"
      refute redacted =~ "sk-bbbbbbbbbbbbbbbbbbbbbbbb"
      assert redacted |> String.split("[redacted]") |> length() == 3
    end
  end

  describe "secret?/1" do
    test "reports true for a detected secret" do
      assert SecretRedactor.secret?("sk-aaaaaaaaaaaaaaaaaaaaaaaa")
      assert SecretRedactor.secret?("someone@example.com")
    end

    test "reports false for ordinary text and non-binary input" do
      refute SecretRedactor.secret?("just an ordinary sentence")
      refute SecretRedactor.secret?(nil)
    end
  end
end
