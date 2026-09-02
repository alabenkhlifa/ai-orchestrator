defmodule SddOrchestratorWeb.ActingIdentity do
  @moduledoc """
  Resolves which account a LiveView mount acts as.

  The GitHub application sign-in and the passwordless hosted sign-in issue
  independent credentials, so a screen served to both must not decide for
  itself which one it trusts. This hook answers that once and assigns the
  acting account and its personal workspace under their own names, leaving
  `:current_account` and the hosted assigns to the screens that already read
  them.

  It assigns nothing else. No email, no hosted identity, and no session record
  reach a screen through it.
  """
  use SddOrchestratorWeb, :verified_routes

  alias SddOrchestrator.Accounts
  alias SddOrchestratorWeb.HostedUserAuth
  alias SddOrchestratorWeb.UserAuth

  @doc """
  `on_mount(:require_acting_identity, ...)` assigns `:acting_account` and
  `:acting_workspace` from whichever sign-in the browser carries:

    * application session — that account, with its personal workspace from
      `Accounts.get_or_create_personal_workspace/1`.
    * hosted session only — the account behind the hosted identity, with the
      personal workspace the session already resolved. The hosted session
      carries that workspace, so re-deriving it would make a second source for
      the same fact.
    * both — the application session wins. It is the GitHub credential's
      session and every GitHub-dependent screen already acts as that account,
      so preferring the hosted one would move a person between accounts
      mid-browsing. Holding two accounts in one browser is the subject of
      `specs/04-github-identity-linking/`, not of this hook.
    * neither — halts to the entry surface with the existing hosted-access
      notice and assigns no account and no workspace.
  """
  def on_mount(:require_acting_identity, _params, session, socket) do
    case acting_identity(session) do
      {account, workspace} ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:acting_account, account)
         |> Phoenix.Component.assign(:acting_workspace, workspace)}

      nil ->
        {:halt,
         Phoenix.LiveView.redirect(socket,
           to: ~p"/?#{[hosted_access: "required"]}"
         )}
    end
  end

  # Both sessions are read from the same LiveView `session` map their own hooks
  # read, so a route needs this hook alone.
  defp acting_identity(session) do
    case UserAuth.account_from_session(session) do
      nil -> hosted_acting_identity(session)
      account -> {account, Accounts.get_or_create_personal_workspace(account)}
    end
  end

  defp hosted_acting_identity(session) do
    case HostedUserAuth.hosted_access_from_session(session) do
      nil -> nil
      access -> {access.account, access.personal_workspace}
    end
  end
end
