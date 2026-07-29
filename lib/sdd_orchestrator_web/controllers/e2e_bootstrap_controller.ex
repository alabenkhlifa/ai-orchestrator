# The whole module is compile-time gated, not just its route. A production
# build sets no `:e2e_bootstrap` flag, so this file compiles to nothing and the
# release contains no such module — there is no session-minting code to reach,
# reference, or re-enable. This goes further than the `/_ui` preview next to it
# in the router, which only gates its route, because this endpoint establishes
# authenticated sessions.
if Application.compile_env(:sdd_orchestrator, :e2e_bootstrap, false) do
  defmodule SddOrchestratorWeb.E2EBootstrapController do
    @moduledoc """
    Dev and test-only session and fixture bootstrap for the browser suite.

    A browser test cannot reach an authenticated product screen on its own: an
    application session is only issued by a live GitHub round trip, and a
    hosted session is only issued by a delivered passwordless credential.
    Neither is available to the local end-to-end server, which is why the
    authenticated participation and feature-delivery matrices were previously
    unprovable in a real browser.

    This endpoint establishes those two sessions directly and seeds the minimum
    project graph one scenario needs. The seeding itself runs the real domain
    commands — invitation creation, explicit acceptance, and the feature
    lifecycle transition table — so every seeded state is a state the product
    can actually produce, and the delivered invitation credential is read back
    out of the delivered message rather than reconstructed here.

    ## Why this cannot reach production

    Exclusion is by construction, in three layers. The module definition itself
    is wrapped in `Application.compile_env(:sdd_orchestrator, :e2e_bootstrap,
    false)`, and no production configuration sets that key, so a production
    build contains no such module at all. The router gates its route on the
    same flag, so there is also no route to dispatch. `create/2` then re-checks
    the flag at runtime and answers `404`, which keeps a build whose
    configuration is changed after compilation from serving anything.
    """
    use SddOrchestratorWeb, :controller

    alias SddOrchestrator.Accounts
    alias SddOrchestrator.Delivery.Features
    alias SddOrchestrator.HostedAccess
    alias SddOrchestrator.HostedAccess.Sessions
    alias SddOrchestrator.Participation
    alias SddOrchestrator.Participation.{Acceptance, Invitations}
    alias SddOrchestrator.Projects.Project
    alias SddOrchestrator.Repo
    alias SddOrchestratorWeb.{HostedUserAuth, UserAuth}

    @columns ~w(draft ready_for_development in_development ready_for_review done)
    @owner_name "Robin Owner"
    @participant_name "Sam Member"
    @project_name "Delivery Pilot"
    @device_context %{user_agent_family: "E2E Browser", os_family: "E2E OS"}

    @doc """
    Seeds one scenario, establishes its sessions, and returns its identifiers.

    Answers `404` unless the harness flag is set, so the action is inert even if
    it is somehow compiled into a build that should not serve it.
    """
    def create(conn, params) do
      if enabled?() do
        run(conn, params["scenario"], params)
      else
        send_resp(conn, :not_found, "")
      end
    end

    defp enabled?, do: Application.get_env(:sdd_orchestrator, :e2e_bootstrap, false) == true

    # One hosted project whose owner is signed in through the application
    # session. `owner_profile=false` leaves the owner label unset so the browser
    # can drive the "choose your name before inviting anyone" prerequisite.
    defp run(conn, "project_owner", params) do
      owner = new_owner()
      project = new_project(owner)
      profile? = params["owner_profile"] != "false"

      if profile?, do: save_owner_profile(project, owner)

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: (profile? && @owner_name) || nil
      })
    end

    # One hosted project with an established owner, one participant who joined
    # through the real acceptance flow, and one still-pending invitation.
    defp run(conn, "project_member", params) do
      %{project: project, owner: owner, participant: participant, pending: pending} =
        member_graph()

      conn
      |> sign_in(params["as"] || "owner", owner, participant)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        owner_email: email_of(owner),
        participant_name: @participant_name,
        participant_email: email_of(participant),
        pending_email: pending
      })
    end

    # One pending invitation, reachable through the credential that was actually
    # delivered. `as` decides which identity holds the browser: nobody, the
    # invited address, or an unrelated signed-in identity.
    defp run(conn, "invitation", params) do
      owner = new_owner()
      project = new_project(owner)
      save_owner_profile(project, owner)

      invited_email = unique_email("invited")

      {:ok, %{invitation: invitation}} =
        Invitations.create(project, owner.account.id, invited_email)

      conn
      |> sign_in_invitee(params["as"] || "none", invited_email)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        invited_email: invited_email,
        invitation_id: invitation.id,
        invitation_path: delivered_invitation_path(invitation.id),
        acceptance_path: "/projects/invitations/#{invitation.id}/accept"
      })
    end

    # One hosted project whose board is either empty or holds one feature in each
    # of the five columns, with a visible status on the in-development card.
    defp run(conn, "features", params) do
      owner = new_owner()
      project = new_project(owner)
      save_owner_profile(project, owner)
      actor = %{account_id: owner.account.id, hosted_identity_id: nil}

      features = if params["populated"] == "true", do: seed_features(project, actor), else: %{}

      conn
      |> sign_in_account(owner.account)
      |> json(%{
        project_id: project.id,
        project_name: project.name,
        owner_name: @owner_name,
        features: features
      })
    end

    defp run(conn, _unknown_scenario, _params),
      do: conn |> put_status(:bad_request) |> json(%{error: "unknown scenario"})

    ## Scenario building blocks

    defp member_graph do
      owner = new_owner()
      project = new_project(owner)
      save_owner_profile(project, owner)

      participant = join_project(project, owner, unique_email("member"))
      pending = unique_email("pending")
      {:ok, _invitation} = Invitations.create(project, owner.account.id, pending)

      %{project: project, owner: owner, participant: participant, pending: pending}
    end

    # The participant joins the way a real one does: the owner invites the
    # address, that address becomes a verified hosted identity, and acceptance is
    # explicit.
    defp join_project(project, owner, email) do
      {:ok, %{invitation: invitation}} = Invitations.create(project, owner.account.id, email)
      invitee = hosted_identity!(email)

      {:ok, _accepted} =
        Acceptance.accept(invitation.id, invitee.hosted_identity, @participant_name)

      invitee
    end

    defp new_owner, do: hosted_identity!(unique_email("owner"))

    defp new_project(owner) do
      %Project{}
      |> Project.changeset(%{name: @project_name, workspace_id: owner.personal_workspace.id})
      |> Repo.insert!()
    end

    defp save_owner_profile(project, owner) do
      {:ok, _profile} = Participation.save_owner_profile(project, owner.account.id, @owner_name)
      :ok
    end

    defp hosted_identity!(email) do
      {:ok, identity} = HostedAccess.restore_or_create_identity(email)
      identity
    end

    defp seed_features(project, actor) do
      Map.new(@columns, fn column ->
        {:ok, feature} =
          Features.create(project.id, actor, %{title: "#{column_title(column)} feature"})

        {column, advance(project.id, actor, feature, column).id}
      end)
    end

    # Every column is reached by walking the legal transition table from `Draft`,
    # so the seeded board could have been produced by the product itself.
    defp advance(project_id, actor, feature, target) do
      target_index = Enum.find_index(@columns, &(&1 == target))

      @columns
      |> Enum.slice(1..target_index//1)
      |> Enum.reduce(feature, fn column, current ->
        {:ok, moved} = Features.transition(project_id, actor, current, column, status(column))
        moved
      end)
    end

    defp status("in_development"), do: [status: "blocked"]
    defp status(_column), do: []

    defp column_title(column),
      do: column |> String.replace("_", " ") |> String.capitalize()

    ## Sessions

    defp sign_in(conn, "participant", _owner, participant),
      do: sign_in_hosted(conn, participant.hosted_identity)

    defp sign_in(conn, _as, owner, _participant), do: sign_in_account(conn, owner.account)

    defp sign_in_invitee(conn, "invited", email),
      do: sign_in_hosted(conn, hosted_identity!(email).hosted_identity)

    defp sign_in_invitee(conn, "other", _email),
      do: sign_in_hosted(conn, new_owner().hosted_identity)

    defp sign_in_invitee(conn, _as, _email), do: conn

    defp sign_in_account(conn, account) do
      {:ok, token} = Accounts.create_session(account)
      UserAuth.put_session_token(conn, token)
    end

    defp sign_in_hosted(conn, hosted_identity) do
      {:ok, _session, session_cookie} = Sessions.create(hosted_identity, @device_context)
      HostedUserAuth.put_session_cookie(conn, session_cookie)
    end

    ## Delivered credential

    # The invitation credential is never stored in a readable form, so the
    # harness recovers the acceptance link the same way the invited person does:
    # out of the message that was delivered to them.
    defp delivered_invitation_path(invitation_id) do
      pattern = Regex.compile!("/projects/invitations/#{invitation_id}/accept\\?\\S+")

      Swoosh.Adapters.Local.Storage.Memory.all()
      |> Enum.find_value(fn email ->
        case Regex.run(pattern, email.text_body || "") do
          [path] -> path
          nil -> nil
        end
      end)
    end

    ## Unique values

    defp email_of(identity) do
      identity.hosted_identity
      |> Repo.preload(:external_identities)
      |> Map.fetch!(:external_identities)
      |> Enum.find_value(&(&1.provider == "email" && &1.display_identifier))
    end

    defp unique_email(prefix), do: "#{prefix}-#{unique_suffix()}@example.com"

    defp unique_suffix do
      8 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    end
  end
end
