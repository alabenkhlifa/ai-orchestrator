defmodule SddOrchestrator.HostedAccessTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts.{
    Account,
    ExternalIdentity,
    HostedIdentity,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.HostedAccess

  describe "restore_or_create_identity/1" do
    test "creates one stable hosted identity and personal workspace atomically" do
      assert {:ok, result} = HostedAccess.restore_or_create_identity("person@example.com")

      assert result.account.state == :active
      assert result.hosted_identity.account_id == result.account.id
      assert result.external_identity.hosted_identity_id == result.hosted_identity.id
      assert result.external_identity.provider == "email"
      assert result.external_identity.subject_key == "person@example.com"
      assert result.external_identity.display_identifier == "person@example.com"
      assert result.personal_workspace.account_id == result.account.id
      assert result.personal_workspace.workspace.kind == "hosted"

      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Repo.aggregate(Workspace, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
    end

    test "case and boundary-whitespace variants restore the same stable identity" do
      assert {:ok, first} =
               HostedAccess.restore_or_create_identity(" Person@Example.COM ")

      assert {:ok, second} =
               HostedAccess.restore_or_create_identity("person@example.com")

      assert second.account.id == first.account.id
      assert second.hosted_identity.id == first.hosted_identity.id
      assert second.personal_workspace.id == first.personal_workspace.id
      assert second.external_identity.id == first.external_identity.id
      assert second.external_identity.subject_key == "person@example.com"
      assert second.external_identity.display_identifier == "person@example.com"

      assert Repo.aggregate(Account, :count) == 1
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(ExternalIdentity, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
    end

    test "retries restore the existing rows without duplication" do
      assert {:ok, first} = HostedAccess.restore_or_create_identity("retry@example.com")
      assert {:ok, second} = HostedAccess.restore_or_create_identity("retry@example.com")

      assert second.hosted_identity.id == first.hosted_identity.id
      assert second.personal_workspace.id == first.personal_workspace.id
      assert Repo.aggregate(HostedIdentity, :count) == 1
      assert Repo.aggregate(PersonalWorkspace, :count) == 1
    end

    test "database uniqueness makes a competing case-variant identity impossible" do
      assert {:ok, first} = HostedAccess.restore_or_create_identity("owner@example.com")
      assert {:ok, other} = HostedAccess.restore_or_create_identity("other@example.com")

      assert {:error, changeset} =
               other.external_identity
               |> ExternalIdentity.changeset(%{
                 provider: "email",
                 subject_key: first.external_identity.subject_key,
                 display_identifier: "OWNER@example.com",
                 verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
                 hosted_identity_id: other.hosted_identity.id
               })
               |> Repo.update()

      assert %{provider: ["has already been taken"]} = errors_on(changeset)
      assert Repo.aggregate(ExternalIdentity, :count) == 2
    end

    test "keeps independently verified users and workspaces isolated" do
      assert {:ok, one} = HostedAccess.restore_or_create_identity("one@example.com")
      assert {:ok, two} = HostedAccess.restore_or_create_identity("two@example.com")

      refute one.account.id == two.account.id
      refute one.hosted_identity.id == two.hosted_identity.id
      refute one.personal_workspace.id == two.personal_workspace.id

      assert {:ok, restored_one} = HostedAccess.get_identity_by_email("ONE@example.com")
      assert restored_one.account.id == one.account.id
      refute restored_one.account.id == two.account.id
    end

    test "rejects invalid email values without creating partial state" do
      for invalid <- ["", "not-an-email", "two words@example.com", nil] do
        assert {:error, :invalid_email} = HostedAccess.restore_or_create_identity(invalid)
      end

      assert Repo.aggregate(Account, :count) == 0
      assert Repo.aggregate(HostedIdentity, :count) == 0
      assert Repo.aggregate(ExternalIdentity, :count) == 0
      assert Repo.aggregate(Workspace, :count) == 0
      assert Repo.aggregate(PersonalWorkspace, :count) == 0
    end

    test "excludes verified email and comparison keys from struct inspection" do
      assert {:ok, result} =
               HostedAccess.restore_or_create_identity("private@example.com")

      inspected = inspect(result.external_identity)
      refute inspected =~ "private@example.com"
      refute inspected =~ result.external_identity.subject_key
    end
  end
end
