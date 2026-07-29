defmodule SddOrchestratorWeb.ParticipationLiveTest do
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestrator.Participation
  alias SddOrchestrator.ParticipationFixtures

  describe "owner profile prerequisite" do
    test "blocks invitations until the owner saves a project display name", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "data-owner-profile-required"
      assert html =~ "data-invitations-unavailable"
      refute html =~ "data-invitations-available"
      refute Participation.owner_profile_established?(project.id)

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "  Ada Lovelace  "})
        |> render_submit()

      assert html =~ "data-owner-profile-saved"
      assert html =~ "data-invitations-available"
      refute html =~ "data-invitations-unavailable"
      assert html =~ "Ada Lovelace"

      profile = Participation.owner_profile(project.id)
      assert profile.display_name == "Ada Lovelace"
      assert profile.display_name_key == "ada lovelace"
      assert profile.role == "owner"
      assert profile.account_id == account.id
      assert Participation.owner_profile_established?(project.id)
    end

    test "shows the established label without the owner email", %{conn: conn} do
      %{project: project, account: account, owner: owner} =
        ParticipationFixtures.hosted_project_fixture()

      ParticipationFixtures.member_profile_fixture(project, account, %{
        role: "owner",
        display_name: "Grace Hopper"
      })

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "Grace Hopper"
      refute html =~ "data-owner-profile-required"
      refute html =~ owner.external_identity.display_identifier
      refute html =~ "@example.com"
    end
  end

  describe "owner self-edit" do
    test "corrects the label while preserving identity and ownership", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      profile =
        ParticipationFixtures.member_profile_fixture(project, account, %{
          role: "owner",
          display_name: "First Label"
        })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "Second Label"})
        |> render_submit()

      assert html =~ "Second Label"
      assert html =~ "data-owner-profile-saved"

      updated = Participation.owner_profile(project.id)
      assert updated.id == profile.id
      assert updated.account_id == account.id
      assert updated.display_name == "Second Label"
      assert {:ok, owner} = Participation.owner(project)
      assert owner.account_id == account.id
    end

    test "rejects a conflicting label inline without an automatic suffix", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()
      participant = ParticipationFixtures.invited_identity_fixture()

      ParticipationFixtures.member_profile_fixture(project, participant.account, %{
        role: "participant",
        display_name: "Ada Lovelace"
      })

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "ADA lovelace"})
        |> render_submit()

      assert html =~ "is already used in this project"
      refute html =~ "data-owner-profile-saved"
      refute Participation.owner_profile_established?(project.id)

      # The rejected input is returned for correction, never renamed for the user.
      assert html =~ "ADA lovelace"
      refute html =~ "ADA lovelace 2"
    end

    test "rejects blank and email-shaped labels", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, _html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      for invalid <- ["", "   ", "owner@example.com", String.duplicate("n", 81)] do
        html =
          view
          |> form("#owner-profile-form", owner: %{display_name: invalid})
          |> render_submit()

        assert html =~ ~s(aria-invalid="true")
        refute html =~ "data-owner-profile-saved"
        refute Participation.owner_profile_established?(project.id)
      end

      # An email address is rejected as a project label rather than accepted as
      # an email-derived owner name.
      html =
        view
        |> form("#owner-profile-form", owner: %{display_name: "owner@example.com"})
        |> render_submit()

      assert html =~ "is not an available project label"
    end
  end

  describe "authorization" do
    test "returns another account to the catalog without exposing the project", %{conn: conn} do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()
      %{account: other_account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> log_in_account(other_account)
               |> live(~p"/projects/#{project.id}/participation")
    end

    test "returns an unknown or malformed project to the catalog", %{conn: conn} do
      %{account: account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn
               |> log_in_account(account)
               |> live(~p"/projects/#{Ecto.UUID.generate()}/participation")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               conn |> log_in_account(account) |> live(~p"/projects/not-a-project/participation")
    end

    test "requires an authenticated account" do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               build_conn() |> live(~p"/projects/#{project.id}/participation")
    end

    test "denies a non-owner through the domain action itself" do
      %{project: project} = ParticipationFixtures.hosted_project_fixture()
      %{account: other_account} = ParticipationFixtures.hosted_project_fixture()

      assert {:error, :unauthorized} =
               Participation.save_owner_profile(project, other_account.id, "Intruder Label")

      assert {:error, :unauthorized} = Participation.save_owner_profile(project, nil, "Label")
      refute Participation.owner_profile_established?(project.id)
    end
  end

  describe "accessible form structure" do
    test "labels the control and links its inline error", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ ~s(<label for="owner-display-name")
      assert html =~ ~s(id="owner-display-name")
      assert html =~ ~s(aria-describedby="owner-display-name-hint")

      invalid =
        view |> form("#owner-profile-form", owner: %{display_name: ""}) |> render_submit()

      assert invalid =~ ~s(aria-invalid="true")
      assert invalid =~ ~s(aria-describedby="owner-display-name-error")
      assert invalid =~ ~s(id="owner-display-name-error")
    end

    test "uses full-width mobile actions that grow on wider screens", %{conn: conn} do
      %{project: project, account: account} = ParticipationFixtures.hosted_project_fixture()

      {:ok, _view, html} =
        conn |> log_in_account(account) |> live(~p"/projects/#{project.id}/participation")

      assert html =~ "w-full sm:w-auto"
      assert html =~ "flex flex-col gap-3 sm:flex-row"
    end
  end
end
