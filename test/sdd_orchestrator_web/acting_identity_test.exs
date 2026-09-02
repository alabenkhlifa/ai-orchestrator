defmodule SddOrchestratorWeb.ActingIdentityTest do
  @moduledoc """
  Proof for the hook that answers which account a mount acts as: an application
  session, a hosted session, both together, neither, and a hosted session that
  is no longer valid.
  """
  use SddOrchestrator.DataCase, async: true

  use SddOrchestratorWeb, :verified_routes

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.HostedSession
  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.HostedAccess.SessionCookie
  alias SddOrchestrator.HostedAccess.Sessions
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestratorWeb.ActingIdentity
  alias SddOrchestratorWeb.UserAuth

  defp entry_with_notice, do: ~p"/?#{[hosted_access: "required"]}"

  defp socket do
    %Phoenix.LiveView.Socket{
      endpoint: SddOrchestratorWeb.Endpoint,
      assigns: %{__changed__: %{}}
    }
  end

  defp application_session(account) do
    {:ok, token} = Accounts.create_session(account)
    %{Atom.to_string(UserAuth.session_token_key()) => token}
  end

  defp hosted_session(cookie_value) do
    %{Atom.to_string(SessionCookie.session_key()) => cookie_value}
  end

  defp mount(session) do
    ActingIdentity.on_mount(:require_acting_identity, %{}, session, socket())
  end

  test "an application session acts as its own account and personal workspace" do
    account = AccountsFixtures.account_fixture()
    workspace = Accounts.get_or_create_personal_workspace(account)

    assert {:cont, socket} = mount(application_session(account))

    assert socket.assigns.acting_account.id == account.id
    assert socket.assigns.acting_workspace.id == workspace.id
    assert socket.assigns.acting_workspace.account_id == account.id
  end

  test "an application session with no workspace yet resolves the one it creates" do
    account = AccountsFixtures.account_fixture()

    assert {:cont, socket} = mount(application_session(account))

    workspace = socket.assigns.acting_workspace
    assert workspace.account_id == account.id
    # The hook must not mint a second workspace on the next mount.
    assert Accounts.get_or_create_personal_workspace(account).id == workspace.id
  end

  test "a hosted session acts as the account behind its hosted identity" do
    hosted =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "acting-hosted@example.com")

    assert {:cont, socket} = mount(hosted_session(hosted.session_cookie.value))

    assert socket.assigns.acting_account.id == hosted.account.id
    # The session already carries the workspace, so the hook reuses it.
    assert socket.assigns.acting_workspace.id == hosted.personal_workspace.id
    assert socket.assigns.acting_workspace.account_id == hosted.account.id
  end

  test "with both sessions the application session's account acts" do
    account = AccountsFixtures.account_fixture()

    hosted =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "acting-both@example.com")

    refute hosted.account.id == account.id

    session =
      Map.merge(
        application_session(account),
        hosted_session(hosted.session_cookie.value)
      )

    assert {:cont, socket} = mount(session)

    assert socket.assigns.acting_account.id == account.id
    refute socket.assigns.acting_workspace.id == hosted.personal_workspace.id
  end

  test "no session halts to the entry surface with nothing assigned" do
    assert {:halt, socket} = mount(%{})

    assert {:redirect, %{to: redirected_to}} = socket.redirected
    assert redirected_to == entry_with_notice()
    refute Map.has_key?(socket.assigns, :acting_account)
    refute Map.has_key?(socket.assigns, :acting_workspace)
  end

  test "an expired hosted session acts as no session" do
    hosted =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "acting-expired@example.com")

    Repo.update_all(
      from(session in HostedSession, where: session.id == ^hosted.session.id),
      set: [expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)]
    )

    assert {:halt, socket} = mount(hosted_session(hosted.session_cookie.value))

    assert {:redirect, %{to: redirected_to}} = socket.redirected
    assert redirected_to == entry_with_notice()
    refute Map.has_key?(socket.assigns, :acting_account)
  end

  test "a revoked hosted session acts as no session" do
    hosted =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "acting-revoked@example.com")

    :ok = Sessions.revoke_current(hosted.session_cookie.value)

    assert {:halt, socket} = mount(hosted_session(hosted.session_cookie.value))

    assert {:redirect, %{to: redirected_to}} = socket.redirected
    assert redirected_to == entry_with_notice()
    refute Map.has_key?(socket.assigns, :acting_workspace)
  end
end
