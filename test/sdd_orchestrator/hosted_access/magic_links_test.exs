defmodule SddOrchestrator.HostedAccess.MagicLinksTest do
  use SddOrchestrator.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias SddOrchestrator.Accounts.{
    Account,
    ExternalIdentity,
    HostedIdentity,
    MagicLinkAttempt,
    PersonalWorkspace
  }

  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.RateLimiter

  setup :set_swoosh_global

  setup do
    RateLimiter.reset()
    :ok
  end

  describe "request_magic_link/2" do
    test "returns a neutral acknowledgement and persists only a salted digest" do
      requested_at = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, %{status: :accepted}} =
               HostedAccess.request_magic_link(" Person@Example.COM ",
                 ip_address: {192, 0, 2, 1}
               )

      assert_receive {:email, email}
      assert email.to == [{"", "Person@Example.COM"}]

      query = delivered_query(email)
      attempt = Repo.one!(MagicLinkAttempt)

      assert query["attempt"] == attempt.id
      assert byte_size(Base.url_decode64!(query["token"], padding: false)) == 32
      assert attempt.email_key == "person@example.com"
      assert attempt.delivery_email == "Person@Example.COM"
      assert attempt.delivery_status == "sent"
      assert attempt.consumed_at == nil
      assert attempt.invalidated_at == nil

      assert attempt.token_digest ==
               :crypto.hash(:sha256, attempt.token_salt <> query["token"])

      refute attempt.token_digest == query["token"]
      refute attempt.token_salt == query["token"]

      assert DateTime.diff(attempt.expires_at, requested_at, :second) in 900..901

      inspected = inspect(attempt)
      refute inspected =~ "person@example.com"
      refute inspected =~ Base.encode64(attempt.token_digest)
      refute inspected =~ Base.encode64(attempt.token_salt)

      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(ExternalIdentity, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
    end

    test "uses the same response for new and existing identities without disclosing state" do
      assert {:ok, _identity} =
               HostedAccess.restore_or_create_identity("existing@example.com")

      existing_response =
        HostedAccess.request_magic_link("existing@example.com",
          ip_address: {192, 0, 2, 2}
        )

      new_response =
        HostedAccess.request_magic_link("new@example.com",
          ip_address: {192, 0, 2, 3}
        )

      assert existing_response == new_response
      assert existing_response == {:ok, %{status: :accepted}}
      assert_receive {:email, existing_email}
      assert_receive {:email, new_email}
      assert existing_email.to == [{"", "existing@example.com"}]
      assert new_email.to == [{"", "new@example.com"}]

      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Repo.aggregate(MagicLinkAttempt, :count) == 2
    end

    test "invalid input receives the same response without an attempt or delivery" do
      assert HostedAccess.request_magic_link("not an email",
               ip_address: {192, 0, 2, 4}
             ) ==
               HostedAccess.request_magic_link(nil, ip_address: {192, 0, 2, 4})

      assert {:ok, %{status: :accepted}} =
               HostedAccess.request_magic_link("not an email",
                 ip_address: {192, 0, 2, 4}
               )

      assert Repo.aggregate(MagicLinkAttempt, :count) == 0
      refute_email_sent()
    end

    test "resend invalidates every older case-variant attempt and keeps only the newest active" do
      assert {:ok, %{status: :accepted}} =
               HostedAccess.request_magic_link("Resend@Example.com",
                 ip_address: {192, 0, 2, 5}
               )

      assert_receive {:email, first_email}

      assert {:ok, %{status: :accepted}} =
               HostedAccess.request_magic_link("resend@example.COM",
                 ip_address: {192, 0, 2, 5}
               )

      assert_receive {:email, second_email}

      first_query = delivered_query(first_email)
      second_query = delivered_query(second_email)
      attempts = Repo.all(MagicLinkAttempt)

      assert first_query["token"] != second_query["token"]
      assert first_query["attempt"] != second_query["attempt"]
      assert length(attempts) == 2

      first = Repo.get!(MagicLinkAttempt, first_query["attempt"])
      second = Repo.get!(MagicLinkAttempt, second_query["attempt"])
      assert first.invalidated_at != nil
      assert second.invalidated_at == nil
      assert second.delivery_email == "resend@example.COM"

      assert Repo.aggregate(
               from(attempt in MagicLinkAttempt,
                 where: is_nil(attempt.consumed_at) and is_nil(attempt.invalidated_at)
               ),
               :count
             ) == 1
    end

    test "concurrent requests remain neutral and leave one newest active credential" do
      responses =
        1..5
        |> Task.async_stream(
          fn _request ->
            HostedAccess.request_magic_link("concurrent@example.com",
              ip_address: {192, 0, 2, 6}
            )
          end,
          max_concurrency: 5,
          ordered: false
        )
        |> Enum.map(fn {:ok, response} -> response end)

      assert Enum.uniq(responses) == [{:ok, %{status: :accepted}}]
      assert Repo.aggregate(MagicLinkAttempt, :count) == 5

      assert Repo.aggregate(
               from(attempt in MagicLinkAttempt,
                 where: is_nil(attempt.consumed_at) and is_nil(attempt.invalidated_at)
               ),
               :count
             ) == 1

      assert_received {:email, _email}
    end

    test "throttling preserves the acknowledgement and does not create another attempt" do
      responses =
        for _request <- 1..6 do
          HostedAccess.request_magic_link("limited@example.com",
            ip_address: {192, 0, 2, 7}
          )
        end

      assert Enum.uniq(responses) == [{:ok, %{status: :accepted}}]
      assert Repo.aggregate(MagicLinkAttempt, :count) == 5

      for _delivery <- 1..5 do
        assert_receive {:email, _email}
      end

      refute_email_sent()
    end

    test "provider failure is neutral, redacted, retriable, and creates no identity" do
      original_delivery =
        Application.fetch_env!(:sdd_orchestrator, :magic_link_delivery)

      Application.put_env(
        :sdd_orchestrator,
        :magic_link_delivery,
        SddOrchestrator.FailingMagicLinkDelivery
      )

      on_exit(fn ->
        Application.put_env(:sdd_orchestrator, :magic_link_delivery, original_delivery)
      end)

      log =
        capture_log(fn ->
          assert {:ok, %{status: :accepted}} =
                   HostedAccess.request_magic_link("failure@example.com",
                     ip_address: {192, 0, 2, 8}
                   )
        end)

      failed = Repo.one!(MagicLinkAttempt)
      assert failed.delivery_status == "failed"
      assert failed.failure_code == "delivery_failed"
      assert log =~ "magic_link_delivery_failed"
      refute log =~ failed.id
      refute log =~ "failure@example.com"
      refute log =~ "provider_unavailable"
      refute_email_sent()

      Application.put_env(
        :sdd_orchestrator,
        :magic_link_delivery,
        SddOrchestrator.HostedAccess.SwooshDelivery
      )

      assert {:ok, %{status: :accepted}} =
               HostedAccess.request_magic_link("failure@example.com",
                 ip_address: {192, 0, 2, 8}
               )

      assert_receive {:email, _email}

      first = Repo.get!(MagicLinkAttempt, failed.id)

      retry =
        Repo.one!(
          from attempt in MagicLinkAttempt,
            where: is_nil(attempt.invalidated_at)
        )

      assert first.invalidated_at != nil
      assert retry.invalidated_at == nil
      assert retry.delivery_status == "sent"
      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(ExternalIdentity, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
    end
  end

  defp delivered_query(email) do
    [url] = Regex.run(~r{https?://\S+}, email.text_body)
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
  end
end
