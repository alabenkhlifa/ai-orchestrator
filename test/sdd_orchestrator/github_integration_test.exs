defmodule SddOrchestrator.GitHubIntegrationTest do
  @moduledoc """
  Domain proofs for the repository-access discovery surface, using the
  deterministic fake provider: the access-check outcomes (granted, pending
  matched to the requester, none, and normalized errors), repository aggregation
  with deduplication by numeric id and stable ordering, and the approved
  read-only permission scope (AC-12).
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.GitHubIntegration
  alias SddOrchestrator.GitHubIntegration.FakeProvider

  defp token(login), do: "fake-access:" <> login

  describe "approved_repository_permissions/0 (AC-12)" do
    test "is metadata read-only with no repository write permission" do
      permissions = GitHubIntegration.approved_repository_permissions()

      assert permissions == %{"metadata" => "read"}
      refute Map.has_key?(permissions, "contents")
      refute Enum.any?(Map.values(permissions), &(&1 == "write"))
    end
  end

  describe "approved_email_permission/0" do
    test "is email read-only with no repository write permission" do
      permission = GitHubIntegration.approved_email_permission()

      assert permission == %{"email" => "read"}
      refute Map.has_key?(permission, "contents")
      refute Enum.any?(Map.values(permission), &(&1 == "write"))
    end
  end

  describe "verified_primary_email/1" do
    test "returns the single verified primary address" do
      assert {:ok, "octocat@example.com"} =
               GitHubIntegration.verified_primary_email(token("octocat"))
    end

    test "returns only the primary and never a secondary address (non-retention)" do
      assert {:ok, email} = GitHubIntegration.verified_primary_email(token("octocat"))

      # A single verified-primary string is surfaced; no list/map of addresses
      # through which a secondary could be retained or disclosed.
      assert is_binary(email)
      assert email == "octocat@example.com"
    end

    test "skips account-neutrally when no primary is returned" do
      assert {:ok, :none} = GitHubIntegration.verified_primary_email(token("email-none-1"))
    end

    test "skips when the primary is unverified" do
      assert {:ok, :none} = GitHubIntegration.verified_primary_email(token("email-unverified-1"))
    end

    test "skips when more than one address is primary" do
      assert {:ok, :none} = GitHubIntegration.verified_primary_email(token("email-multi-1"))
    end

    test "skips when only a verified secondary exists" do
      assert {:ok, :none} = GitHubIntegration.verified_primary_email(token("email-secondary-1"))
    end

    test "skips when the email permission is unavailable" do
      assert {:ok, :none} = GitHubIntegration.verified_primary_email(token("email-noperm-1"))
    end

    test "normalizes a provider read failure to :provider_failure" do
      assert {:error, :provider_failure} =
               GitHubIntegration.verified_primary_email(token("email-fail-1"))
    end
  end

  describe "check_repository_access/2" do
    test "grants access when the user has an accessible installation" do
      assert {:ok, :granted, installations} =
               GitHubIntegration.check_repository_access(token("octo"), 7)

      assert Enum.map(installations, & &1.id) == [1, 2]
      # Every accessible installation grants only metadata:read.
      assert Enum.all?(installations, &(&1.permissions == %{"metadata" => "read"}))
    end

    test "returns pending only for the matching requester (AC-18)" do
      pending_id = FakeProvider.pending_requester_github_id()

      assert {:ok, :pending, "acme-inc"} =
               GitHubIntegration.check_repository_access(token("pending-org"), pending_id)
    end

    test "returns none when a pending request belongs to a different user" do
      # No installation, and the pending request is addressed to another user.
      assert {:ok, :none} =
               GitHubIntegration.check_repository_access(token("noinstall-here"), 999)
    end

    test "never treats a pending request for another user as granted" do
      other = FakeProvider.pending_requester_github_id() + 1

      assert {:ok, :none} =
               GitHubIntegration.check_repository_access(token("pending-org"), other)
    end

    test "normalizes provider errors" do
      assert {:error, :unauthorized} =
               GitHubIntegration.check_repository_access(token("unauthorized-x"), 1)

      assert {:error, :rate_limited} =
               GitHubIntegration.check_repository_access(token("ratelimit-x"), 1)

      assert {:error, :provider_failure} =
               GitHubIntegration.check_repository_access(token("providerfail-x"), 1)
    end
  end

  describe "list_accessible_repositories/2" do
    setup do
      {:ok, :granted, installations} =
        GitHubIntegration.check_repository_access(token("octo"), 7)

      %{installations: installations}
    end

    test "deduplicates by numeric repository id and orders by owner/name", %{
      installations: installations
    } do
      assert {:ok, repos} =
               GitHubIntegration.list_accessible_repositories(token("octo"), installations)

      # The shared repo (id 301) appears in both installations but only once here.
      assert Enum.map(repos, & &1.id) == [202, 301, 101, 102]
      assert Enum.count(repos, &(&1.id == 301)) == 1
    end

    test "exposes owner, visibility, and organization metadata (AC-20)", %{
      installations: installations
    } do
      {:ok, repos} = GitHubIntegration.list_accessible_repositories(token("octo"), installations)

      by_id = Map.new(repos, &{&1.id, &1})

      # Personal public repo.
      assert %{owner: "octo", private: false, visibility: "public", organization: nil} =
               by_id[101]

      # Personal private repo.
      assert %{private: true, visibility: "private"} = by_id[102]

      # Organization repo carries the organization label.
      assert %{owner: "acme", organization: "acme", owner_type: "Organization"} = by_id[301]
    end

    test "returns empty when installations expose no repositories" do
      {:ok, :granted, installations} =
        GitHubIntegration.check_repository_access(token("norepos-x"), 1)

      assert {:ok, []} =
               GitHubIntegration.list_accessible_repositories(token("norepos-x"), installations)
    end

    test "surfaces an organization restriction distinctly (AC-22)" do
      {:ok, :granted, installations} =
        GitHubIntegration.check_repository_access(token("restricted-x"), 1)

      assert {:error, :org_restricted} =
               GitHubIntegration.list_accessible_repositories(
                 token("restricted-x"),
                 installations
               )
    end
  end

  describe "installation_url/1" do
    test "targets the public app installation page with a one-time state" do
      url = GitHubIntegration.installation_url("abc123")

      assert url =~ "https://github.com/apps/orchestra-workflow/installations/new"
      assert url =~ "state=abc123"
    end
  end
end
