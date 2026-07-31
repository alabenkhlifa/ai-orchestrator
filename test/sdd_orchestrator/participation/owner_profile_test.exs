defmodule SddOrchestrator.Participation.OwnerProfileTest do
  @moduledoc """
  The owner's project display profile is created with the hosted project
  (AC-40) and backfilled for projects registered before that rule (AC-41).

  Two properties are proven throughout: the initial label comes from the
  owner's GitHub login and never from an email address, and owner
  authorization never depends on the label existing at all.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Boundary, DisplayName}
  alias SddOrchestrator.Participation.{ProjectMemberProfile, ProjectParticipant}
  alias SddOrchestrator.ParticipationFixtures
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.ProjectsFixtures

  @migration_version 20_260_731_090_000
  @migration_path "priv/repo/migrations/20260731090000_backfill_owner_display_profiles.exs"
  @fallback_label "Project owner"

  describe "registration (AC-40)" do
    test "creates the owner profile from the GitHub login in the same transaction" do
      %{project: project, account: account} = registered(login: "octocat")

      profile = Participation.owner_profile(project.id)

      assert profile.role == "owner"
      assert profile.state == "active"
      assert profile.account_id == account.id
      assert profile.display_name == "octocat"
      assert profile.display_name_key == "octocat"

      # One project, one owner label, created together.
      assert [^profile] = profiles_of(project)
    end

    test "preserves the login's accepted spelling and derives the comparison key" do
      %{project: project} = registered(login: "AdaLovelace")

      profile = Participation.owner_profile(project.id)

      assert profile.display_name == "AdaLovelace"
      assert profile.display_name_key == "adalovelace"
    end

    test "never derives the label from an email address" do
      # A passwordless owner has a verified email and no GitHub login: exactly
      # the case where an email-derived label would be tempting.
      owner = HostedAccessFixtures.hosted_identity_fixture(email: "grace.hopper@example.com")
      project = ProjectsFixtures.registered_project(owner.personal_workspace)

      profile = Participation.owner_profile(project.id)

      assert profile.display_name == @fallback_label
      refute profile.display_name =~ "@"
      refute profile.display_name =~ "grace"
      refute profile.display_name =~ "hopper"
      refute profile.display_name =~ "example"
    end

    test "falls back to the neutral label when the account has no GitHub login" do
      owner = HostedAccessFixtures.hosted_identity_fixture()
      project = ProjectsFixtures.registered_project(owner.personal_workspace)

      profile = Participation.owner_profile(project.id)

      assert profile.display_name == Participation.default_owner_display_name()
      assert profile.display_name_key == "project owner"
      assert profile.account_id == owner.account.id
    end

    test "authorizes the owner immediately, and lets them change the label at any time" do
      %{project: project, account: account} = registered(login: "octocat")
      account_id = account.id

      assert {:ok, %{role: :owner, account_id: ^account_id, display_name: "octocat"}} =
               Boundary.owner(project.id)

      assert {:ok, %{role: :owner}} =
               Boundary.current_member(project.id, %{account_id: account_id})

      assert {:ok, renamed} = Participation.save_owner_profile(project, account_id, "Ada L.")
      assert renamed.display_name == "Ada L."
      assert {:ok, %{display_name: "Ada L."}} = Boundary.owner(project.id)

      # The label moved; ownership did not.
      assert {:ok, %{account_id: ^account_id}} = Participation.owner(project.id)
    end

    test "leaves no project and no owner profile when registration fails" do
      account = AccountsFixtures.account_fixture(%{login: "octocat"})
      workspace = ProjectsFixtures.workspace_fixture(account)

      _first = ProjectsFixtures.registered_project(workspace, name: "shared-name")
      before = Repo.aggregate(ProjectMemberProfile, :count)

      attempt = ProjectsFixtures.attempt_ready(workspace)

      assert {:error, %Ecto.Changeset{}} =
               Projects.register_project(workspace, attempt, name: "shared-name")

      assert Repo.aggregate(ProjectMemberProfile, :count) == before
      assert Repo.aggregate(Project, :count) == 1
    end
  end

  describe "owner authorization without a label (AC-40)" do
    test "resolves the owner of a project that has no profile at all" do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      refute Participation.owner_profile(project.id)

      assert {:ok, owner} = Boundary.owner(project.id)
      assert owner.role == :owner
      assert owner.account_id == account.id
      assert owner.display_name == @fallback_label
      refute owner.display_name =~ "@"

      assert [%{role: :owner}] = Boundary.current_members(project.id)
    end

    test "still fails closed for a project that does not exist" do
      assert {:error, :unavailable} = Boundary.owner(Ecto.UUID.generate())
      assert {:error, :unavailable} = Boundary.owner("not-an-id")
    end
  end

  describe "the backfill (AC-41)" do
    test "gives a project registered before the rule one owner profile" do
      %{project: project, account: account} = bare_project(login: "earlybird")
      account_id = account.id

      refute Participation.owner_profile(project.id)
      assert {:ok, %{display_name: @fallback_label}} = Boundary.owner(project.id)

      backfill()

      profile = Participation.owner_profile(project.id)
      assert profile.display_name == "earlybird"
      assert profile.display_name_key == "earlybird"
      assert profile.role == "owner"
      assert profile.state == "active"
      assert profile.account_id == account_id
      assert is_nil(profile.anonymized_at)

      assert {:ok, %{display_name: "earlybird", account_id: ^account_id}} =
               Boundary.owner(project.id)
    end

    test "uses the neutral label, never the email, when there is no GitHub login" do
      owner = HostedAccessFixtures.hosted_identity_fixture(email: "grace.hopper@example.com")
      project = ProjectsFixtures.project_fixture(owner.personal_workspace)

      backfill()

      profile = Participation.owner_profile(project.id)
      assert profile.display_name == @fallback_label
      refute profile.display_name =~ "@"
      refute profile.display_name =~ "grace"
    end

    test "is idempotent" do
      %{project: project} = bare_project(login: "earlybird")

      backfill()
      created = Participation.owner_profile(project.id)

      backfill()
      backfill()

      assert [again] = profiles_of(project)
      assert again.id == created.id
      assert again.display_name == "earlybird"
      assert again.updated_at == created.updated_at
    end

    test "never overwrites an existing display name" do
      %{project: project, account: account} = bare_project(login: "earlybird")
      {:ok, chosen} = Participation.save_owner_profile(project, account.id, "Grace H.")

      backfill()

      assert [only] = profiles_of(project)
      assert only.id == chosen.id
      assert only.display_name == "Grace H."
    end

    test "changes neither project ownership nor participation" do
      %{project: project, account: account} = bare_project(login: "earlybird")
      account_id = account.id
      identity = ParticipationFixtures.invited_identity_fixture()

      participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)
      project_before = Repo.get!(Project, project.id)

      backfill()

      assert Repo.get!(Project, project.id) == project_before
      assert Repo.get!(ProjectParticipant, participant.id) == participant
      assert {:ok, %{account_id: ^account_id}} = Participation.owner(project.id)
      assert [^participant] = Participation.active_participants(project.id)
    end

    test "skips a project whose owner label is already taken, without a suffix" do
      %{project: project, account: account} = bare_project(login: "earlybird")
      account_id = account.id
      other = ParticipationFixtures.invited_identity_fixture()

      ParticipationFixtures.member_profile_fixture(project, other.account,
        display_name: "EarlyBird"
      )

      backfill()

      # A conflicting label is corrected explicitly, never suffixed, so the
      # owner simply keeps no label here — and stays authorized regardless.
      refute Participation.owner_profile(project.id)
      assert Enum.map(profiles_of(project), & &1.display_name) == ["EarlyBird"]

      assert {:ok, %{display_name: @fallback_label, account_id: ^account_id}} =
               Boundary.owner(project.id)
    end

    test "keeps each project's owner label to that project" do
      %{project: first, account: first_account} = bare_project(login: "first-owner")
      %{project: second, account: second_account} = bare_project(login: "second-owner")

      backfill()

      assert Participation.owner_profile(first.id).display_name == "first-owner"
      assert Participation.owner_profile(first.id).account_id == first_account.id
      assert Participation.owner_profile(second.id).display_name == "second-owner"
      assert Participation.owner_profile(second.id).account_id == second_account.id

      assert Participation.member_profile(first.id, second_account.id) == nil
      assert Participation.member_profile(second.id, first_account.id) == nil
    end

    test "writes no owner label the application would key differently" do
      %{project: project} = bare_project(login: "MiXeD-Case-99")

      backfill()

      profile = Participation.owner_profile(project.id)

      assert profile.display_name == "MiXeD-Case-99"
      assert profile.display_name_key == DisplayName.key(profile.display_name)
    end
  end

  describe "the migration" do
    test "rolls back without destroying backfilled labels and rolls forward again" do
      %{project: project} = bare_project(login: "earlybird")

      opts = [log: false, migration_lock: false]
      module = migration_module()

      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)

      created = Participation.owner_profile(project.id)
      assert created.display_name == "earlybird"

      # `down/0` is a documented no-op: a backfilled label is indistinguishable
      # from one the owner typed, so rolling back preserves it, and rolling
      # forward re-runs the same guarded insert without duplicating anything.
      assert :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
      assert Participation.owner_profile(project.id).id == created.id

      assert :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
      assert [^created] = profiles_of(project)
    end
  end

  # A hosted project created the bare way — `Project.changeset` directly —
  # exactly as every project registered before owner profiles existed was.
  defp bare_project(opts) do
    account = AccountsFixtures.account_fixture(Map.new(opts))
    workspace = ProjectsFixtures.workspace_fixture(account)

    %{
      project: ProjectsFixtures.project_fixture(workspace),
      account: account,
      workspace: workspace
    }
  end

  defp registered(opts) do
    account = AccountsFixtures.account_fixture(Map.new(opts))
    workspace = ProjectsFixtures.workspace_fixture(account)

    %{project: ProjectsFixtures.registered_project(workspace), account: account}
  end

  defp profiles_of(project) do
    Repo.all(
      from p in ProjectMemberProfile,
        where: p.project_id == ^project.id,
        order_by: [asc: p.inserted_at, asc: p.id]
    )
  end

  # Runs the data migration for real, inside this test's transaction.
  defp backfill do
    opts = [log: false, migration_lock: false]
    module = migration_module()

    :ok = Ecto.Migrator.down(Repo, @migration_version, module, opts)
    :ok = Ecto.Migrator.up(Repo, @migration_version, module, opts)
    :ok
  end

  defp migration_module do
    module = SddOrchestrator.Repo.Migrations.BackfillOwnerDisplayProfiles

    if Code.ensure_loaded?(module) do
      module
    else
      [{loaded, _binary} | _rest] = Code.compile_file(Path.join(File.cwd!(), @migration_path))
      loaded
    end
  end
end
