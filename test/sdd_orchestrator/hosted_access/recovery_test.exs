defmodule SddOrchestrator.HostedAccess.RecoveryTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts.{ExternalIdentity, HostedSession}
  alias SddOrchestrator.HostedAccess
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.HostedAccessFixtures

  test "a verified pre-linked method restores the same identity and workspace" do
    original =
      HostedAccessFixtures.hosted_identity_fixture(email: "owner@example.com")

    linked_method =
      %ExternalIdentity{}
      |> ExternalIdentity.changeset(%{
        provider: "github",
        subject_key: "github:12345",
        display_identifier: "owner-handle",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        hosted_identity_id: original.hosted_identity.id
      })
      |> Repo.insert!()

    assert {:ok, restored} =
             HostedAccess.restore_prelinked_identity(linked_method, %{
               user_agent_family: "Firefox",
               os_family: "Linux"
             })

    assert restored.account.id == original.account.id
    assert restored.hosted_identity.id == original.hosted_identity.id
    assert restored.personal_workspace.id == original.personal_workspace.id
    assert restored.session.hosted_identity_id == original.hosted_identity.id
    assert {:ok, access} = Sessions.authenticate(restored.session_cookie.value)
    assert access.hosted_identity.id == original.hosted_identity.id

    assert {:ok, after_recovery} =
             HostedAccess.get_identity_by_email("owner@example.com")

    assert after_recovery.external_identity.id == original.external_identity.id
    assert after_recovery.external_identity.display_identifier == "owner@example.com"
  end

  test "email itself, a missing method, and an unpersisted assertion cannot bypass recovery" do
    original =
      HostedAccessFixtures.hosted_identity_fixture(email: "only-email@example.com")

    unpersisted = %ExternalIdentity{
      id: Ecto.UUID.generate(),
      provider: "github",
      subject_key: "github:untrusted",
      display_identifier: "untrusted",
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
      hosted_identity_id: original.hosted_identity.id
    }

    failures = [
      HostedAccess.restore_prelinked_identity(nil),
      HostedAccess.restore_prelinked_identity(original.external_identity),
      HostedAccess.restore_prelinked_identity(unpersisted)
    ]

    assert Enum.uniq(failures) == [{:error, :access_unavailable}]
    assert Repo.aggregate(HostedSession, :count) == 0
  end

  test "an existing session or linked method cannot replace the verified email" do
    original =
      HostedAccessFixtures.hosted_identity_fixture(email: "immutable@example.com")

    linked_method =
      %ExternalIdentity{}
      |> ExternalIdentity.changeset(%{
        provider: "github",
        subject_key: "github:immutable",
        display_identifier: "immutable-handle",
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
        hosted_identity_id: original.hosted_identity.id
      })
      |> Repo.insert!()

    assert {:ok, recovered} =
             HostedAccess.restore_prelinked_identity(linked_method)

    assert {:error, :fresh_email_proofs_required} =
             HostedAccess.change_verified_email(recovered.session, "replacement@example.com")

    assert {:error, :fresh_email_proofs_required} =
             HostedAccess.change_verified_email(linked_method, "replacement@example.com")

    assert {:ok, unchanged} =
             HostedAccess.get_identity_by_email("immutable@example.com")

    assert unchanged.external_identity.id == original.external_identity.id
    assert unchanged.external_identity.display_identifier == "immutable@example.com"
    assert :error = HostedAccess.get_identity_by_email("replacement@example.com")
  end
end
