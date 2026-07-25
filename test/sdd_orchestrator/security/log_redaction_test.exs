defmodule SddOrchestrator.Security.LogRedactionTest do
  @moduledoc """
  Security proof that provider credentials never reach diagnostics (Task 11): the
  encrypted GitHub access and refresh tokens are redacted from struct inspection and
  therefore from any structured log line that inspects the record.
  """
  use SddOrchestrator.DataCase, async: true

  import ExUnit.CaptureLog

  require Logger

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.AccountsFixtures

  test "GitHub credentials are redacted from inspection and logs" do
    account = AccountsFixtures.account_fixture(login: "octo")
    credential = Accounts.get_github_credential(account.id)

    token = credential.access_token
    refresh = credential.refresh_token
    assert is_binary(token) and token != ""

    dump = inspect(credential)
    refute dump =~ token
    refute dump =~ refresh
    # `redact: true` omits the encrypted token fields from inspection entirely.
    refute dump =~ "access_token"
    refute dump =~ "refresh_token"

    # Logging the struct (a realistic diagnostic slip) stays redacted.
    log = capture_log(fn -> Logger.error("credential dump: #{inspect(credential)}") end)
    refute log =~ token
    refute log =~ refresh
  end
end
