defmodule SddOrchestratorWeb.RepositoryExecutionProfileLive do
  @moduledoc """
  Owner review and approval of the current proposed repository execution profile.

  Every value shown is rebuilt from the completed assessment and its verified
  minimized proposal envelope. The screen carries no editable proposal input and
  its decision events ignore their parameters, so no review caller can replace a
  proposal field or approve against an earlier assessment binding. Approving
  appends one immutable version; it changes no repository file, instruction, CI
  rule, or branch policy.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  @cache_sources %{
    "fresh_scan" => "Freshly scanned",
    "complete_cache" => "Reused complete cache"
  }

  @precedence_categories %{
    "instruction" => "Agent instructions",
    "contribution" => "Contribution rules"
  }

  @blocker_labels %{
    "missing_project_commands" => "No project command was found in the assessed evidence.",
    "missing_repository_instructions" =>
      "No repository instruction or contribution file was found.",
    "missing_required_checks" => "No required verification check was found.",
    "ambiguous_command_evidence" =>
      "The assessed evidence described commands that could not be resolved to one meaning."
  }

  @owner_only_message "Only the project owner can approve or reject this proposal."

  @stale_message "This assessment is no longer the current one for this repository. " <>
                   "No profile version was created. Run a new assessment, then review it again."

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_context(socket.assigns.live_action, project_id, socket) do
      {:ok, context} ->
        {:ok,
         socket
         |> assign(context)
         |> assign(:page_title, "Execution profile")
         |> assign(:message, nil)
         |> assign(:review, nil)
         |> assign(:profiles, [])
         |> assign(:stage, :unavailable)
         |> load_review(:review)}

      {:error, destination} ->
        {:ok, push_navigate(socket, to: destination)}
    end
  end

  @impl true
  def handle_event("approve_profile", _params, socket), do: decide(socket, :approve)

  def handle_event("reject_profile", _params, socket), do: decide(socket, :reject)

  # Decision parameters are deliberately dropped: the only proposal a decision
  # may carry is the one this screen rebuilt from the verified envelope.
  defp decide(socket, decision) do
    if decidable?(socket) do
      apply_decision(socket, decision)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  defp decidable?(%{assigns: assigns}),
    do: assigns.owner? and assigns.stage != :unavailable and not is_nil(assigns.review)

  defp apply_decision(socket, :approve) do
    socket.assigns.viewer
    |> RepositoryAssessments.approve_profile(
      socket.assigns.project.id,
      socket.assigns.review.proposal
    )
    |> case do
      {:ok, profile} ->
        {:noreply,
         socket
         |> load_review(:decided)
         |> assign(
           :message,
           {:ok,
            "Approved profile version #{profile.version}. It governs Orchestrator-managed runs only."}
         )}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: socket.assigns.denied_destination)}

      {:error, :stale_assessment} ->
        {:noreply, socket |> load_review(:review) |> assign(:message, {:warn, @stale_message})}

      {:error, _safe_failure} ->
        {:noreply,
         socket
         |> load_review(:review)
         |> assign(
           :message,
           {:warn,
            "The profile could not be approved. No profile version was created. Try again."}
         )}
    end
  end

  defp apply_decision(socket, :reject) do
    socket.assigns.viewer
    |> RepositoryAssessments.reject_profile(
      socket.assigns.project.id,
      socket.assigns.review.proposal
    )
    |> case do
      :ok ->
        {:noreply,
         socket
         |> load_review(:decided)
         |> assign(
           :message,
           {:ok,
            "Proposal rejected. No profile version was created and the repository is unchanged."}
         )}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: socket.assigns.denied_destination)}

      {:error, :stale_assessment} ->
        {:noreply, socket |> load_review(:review) |> assign(:message, {:warn, @stale_message})}

      {:error, _safe_failure} ->
        {:noreply,
         socket
         |> load_review(:review)
         |> assign(
           :message,
           {:warn, "The proposal could not be rejected. Nothing was changed. Try again."}
         )}
    end
  end

  defp load_review(socket, stage) do
    case RepositoryAssessments.profile_review(socket.assigns.viewer, socket.assigns.project.id) do
      {:ok, review} ->
        socket
        |> assign(:review, review)
        |> assign(:profiles, review.profiles)
        |> assign(:stage, stage)

      {:error, _unavailable} ->
        socket
        |> assign(:review, nil)
        |> assign(:profiles, [])
        |> assign(:stage, :unavailable)
    end
  end

  defp load_context(:hosted, project_id, socket) do
    account_id = acting_account_id(socket)
    hosted_identity_id = acting_identity_id(socket)

    case hosted_project(account_id, hosted_identity_id, project_id) do
      {:ok, project, :owner} ->
        {:ok, hosted_context(project, {:hosted, account_id}, true)}

      {:ok, project, :participant} ->
        {:ok, hosted_context(project, {:participant, account_id, hosted_identity_id}, false)}

      :error ->
        {:error, ~p"/projects"}
    end
  rescue
    _error -> {:error, ~p"/projects"}
  end

  defp load_context(:device, project_id, _socket) do
    with {:ok, %DeviceWorkspace{} = workspace} <- Devices.get_workspace(),
         {:ok, %{status: "connected"} = project} <- Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(workspace, project) do
      {:ok,
       %{
         project: project,
         viewer: {:device, workspace},
         owner?: true,
         authority_kind: :device,
         denied_destination: ~p"/onboarding/local",
         back_destination: ~p"/local/projects/#{project.id}",
         repository_display: "Local repository for #{project.name}"
       }}
    else
      _unauthorized -> {:error, ~p"/onboarding/local"}
    end
  rescue
    _error -> {:error, ~p"/onboarding/local"}
  catch
    :exit, _reason -> {:error, ~p"/onboarding/local"}
  end

  defp load_context(_action, _project_id, _socket), do: {:error, ~p"/projects"}

  # Ownership is resolved first because the owner's authority is what the
  # decision path needs; participation only widens the read.
  defp hosted_project(account_id, hosted_identity_id, project_id) do
    case Participation.owned_project(account_id, project_id) do
      {:ok, project} ->
        if active_hosted_project?(project),
          do: {:ok, project, :owner},
          else: visible_hosted_project(account_id, hosted_identity_id, project_id)

      {:error, :unauthorized} ->
        visible_hosted_project(account_id, hosted_identity_id, project_id)
    end
  end

  defp visible_hosted_project(account_id, hosted_identity_id, project_id) do
    with {:ok, project, role} <-
           Participation.visible_project(project_id, account_id, hosted_identity_id),
         true <- role in [:owner, :participant],
         true <- active_hosted_project?(project) do
      {:ok, project, :participant}
    else
      _unauthorized -> :error
    end
  end

  defp hosted_context(project, viewer, owner?) do
    project = Repo.preload(project, :repository_connection)

    %{
      project: project,
      viewer: viewer,
      owner?: owner?,
      authority_kind: :hosted,
      denied_destination: ~p"/projects",
      back_destination:
        if(owner?,
          do: ~p"/projects/#{project.id}/overview",
          else: ~p"/projects/#{project.id}/features"
        ),
      repository_display: hosted_repository_display(project)
    }
  end

  defp active_hosted_project?(project),
    do: project.storage_mode == "hosted" and project.lifecycle_state == "active"

  defp hosted_repository_display(project) do
    case project.repository_connection do
      %{full_name: full_name} when is_binary(full_name) and full_name != "" -> full_name
      %{name: name} when is_binary(name) and name != "" -> name
      _connection -> "Connected repository"
    end
  end

  defp acting_account_id(socket) do
    cond do
      account = socket.assigns[:current_account] -> account.id
      identity = socket.assigns[:current_hosted_identity] -> identity.account_id
      true -> nil
    end
  end

  defp acting_identity_id(socket) do
    identity = socket.assigns[:current_hosted_identity]
    identity && identity.id
  end

  defp cache_source_label(source), do: Map.get(@cache_sources, source, "Unknown")

  defp precedence_label(category),
    do: Map.get(@precedence_categories, category, "Repository instructions")

  defp blocker_label(code) do
    Map.get_lazy(@blocker_labels, code, fn ->
      code |> String.replace("_", " ") |> String.capitalize()
    end)
  end

  defp message_variant({:ok, _text}), do: "info"
  defp message_variant({:warn, _text}), do: "err"

  defp message_icon({:ok, _text}), do: "circle-check"
  defp message_icon({:warn, _text}), do: "circle-alert"

  defp approved_at(%DateTime{} = approved_at),
    do: Calendar.strftime(approved_at, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-4xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={@back_destination}>
          <.lucide name="arrow-left" class="size-4" /> Back to project
        </.button>
      </:actions>

      <div
        data-screen="repository-execution-profile"
        data-profile-stage={@stage}
        data-profile-role={if @owner?, do: "owner", else: "participant"}
      >
        <div class="max-w-2xl">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Owner decision</p>
          <h1 class="mt-1 text-2xl font-bold text-ink">Review the proposed execution profile</h1>
          <p class="mt-2 text-sm leading-relaxed text-ink-muted">
            Every value below is derived from the completed assessment and its stored proposal.
            Nothing here can be edited, and approving appends one immutable version.
          </p>
        </div>

        <section
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="managed-runtime-heading"
          data-managed-runtime-only
        >
          <div class="flex items-start gap-3">
            <span class="rounded-lg bg-info-bg p-2 text-info-fg">
              <.lucide name="shield" class="size-5" />
            </span>
            <div class="min-w-0">
              <h2 id="managed-runtime-heading" class="text-base font-bold text-ink">
                This profile governs Orchestrator-managed runs only
              </h2>
              <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                Approving it changes no repository file, instruction, CI rule, or branch policy.
                Existing repository instructions stay authoritative, and nothing here is written
                back to the repository.
              </p>
            </div>
          </div>
        </section>

        <.notice
          :if={@message}
          variant={message_variant(@message)}
          icon={message_icon(@message)}
          class="mt-4"
        >
          <span data-profile-message>{elem(@message, 1)}</span>
        </.notice>

        <.notice :if={@stage == :unavailable} variant="err" icon="circle-alert" class="mt-6">
          <span data-profile-unavailable>
            No completed assessment with a verifiable minimized proposal envelope is available for
            this repository, so there is nothing to approve. An assessment created before the
            current proposal contract can never be approved. Run a new assessment, then review it
            here.
          </span>
        </.notice>

        <div :if={@review}>
          <section
            class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
            aria-labelledby="assessment-summary-heading"
            data-assessment-summary
          >
            <h2 id="assessment-summary-heading" class="text-base font-bold text-ink">
              Completed assessment and cache provenance
            </h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              The proposal is bound to exactly this assessment. If any of it changes, the proposal
              can no longer be approved.
            </p>

            <dl class="mt-5 grid gap-3 sm:grid-cols-2">
              <.profile_field label="Repository" value={@repository_display} field="repository" />
              <.profile_field label="Assessed root" value={@review.assessment.root} field="root" />
              <.profile_field
                label="Base revision"
                value={@review.assessment.commit}
                field="base-revision"
                code?={true}
              />
              <.profile_field
                label="Evidence source"
                value={cache_source_label(@review.assessment.cache_source)}
                field="cache-source"
              />
              <.profile_field
                label="Stored as a reusable cache entry"
                value={if @review.assessment.cache_stored, do: "Yes", else: "No"}
                field="cache-stored"
              />
              <.profile_field
                label="Cache key digest"
                value={@review.assessment.cache_key_sha256}
                field="cache-key-digest"
                code?={true}
              />
              <.profile_field
                label="Evidence digest"
                value={@review.assessment.evidence_sha256}
                field="evidence-digest"
                code?={true}
              />
            </dl>
          </section>

          <section
            class="mt-4 rounded-xl border border-line bg-surface p-4 sm:p-5"
            aria-labelledby="precedence-heading"
            data-instruction-precedence
          >
            <h2 id="precedence-heading" class="text-base font-bold text-ink">
              Instruction precedence
            </h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              These repository instructions remain authoritative. The approved profile never
              overrides them and never edits them.
            </p>

            <ul
              :if={@review.proposal.instruction_precedence != []}
              class="mt-4 space-y-2"
            >
              <li
                :for={entry <- @review.proposal.instruction_precedence}
                class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-line bg-raised px-3 py-2"
                data-precedence-entry
              >
                <span class="text-[13px] font-semibold text-ink">
                  {precedence_label(entry["category"])}
                </span>
                <span class="break-all font-mono text-xs text-ink-muted">{entry["path"]}</span>
              </li>
            </ul>

            <p
              :if={@review.proposal.instruction_precedence == []}
              class="mt-4 text-sm text-ink-muted"
              data-precedence-empty
            >
              No existing repository instruction or contribution file was detected.
            </p>
          </section>

          <.proposal_section
            field="commands"
            title="Project commands"
            description="The managed runtime may run only these commands."
            items={@review.proposal.commands}
            empty="No project command was proposed."
            code?={true}
          />

          <.proposal_section
            field="required-checks"
            title="Required checks"
            description="A managed run must pass these before it reports success."
            items={@review.proposal.required_checks}
            empty="No required check was proposed."
            code?={true}
          />

          <.proposal_section
            field="allowed-scope"
            title="Allowed scope"
            description="Managed runs stay inside these repository-relative paths."
            items={@review.proposal.allowed_scope}
            empty="No allowed scope was proposed."
            code?={true}
          />

          <.proposal_section
            field="gaps"
            title="Gaps"
            description="The assessment could not establish these, so a managed run may be limited."
            items={@review.proposal.gaps}
            empty="No gap was reported."
            blocker?={true}
            coded?={true}
          />

          <.proposal_section
            field="conflicts"
            title="Conflicts"
            description="The assessed evidence disagreed with itself here. Resolve it in the repository."
            items={@review.proposal.conflicts}
            empty="No conflict was reported."
            blocker?={true}
            coded?={true}
          />

          <.proposal_section
            field="multi-root-blockers"
            title="Multi-root blockers"
            description="These additional project roots are outside this profile's single assessed root."
            items={@review.proposal.multi_root_blockers}
            empty="No multi-root blocker was reported."
            blocker?={true}
            code?={true}
          />

          <div
            :if={@owner? and @stage == :review}
            id="profile-decision-form"
            role="group"
            aria-labelledby="decision-heading"
            class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          >
            <h2 id="decision-heading" class="text-base font-bold text-ink">Your decision</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Approving appends version {length(@profiles) + 1} exactly as shown. Rejecting creates
              no version and leaves the repository unchanged.
            </p>

            <div class="mt-5 flex flex-col gap-3 sm:flex-row">
              <.button class="w-full sm:w-auto" phx-click="approve_profile" data-approve-profile>
                <.lucide name="check" class="size-4" /> Approve profile
              </.button>
              <.button
                variant="secondary"
                class="w-full sm:w-auto"
                phx-click="reject_profile"
                data-reject-profile
              >
                <.lucide name="x" class="size-4" /> Reject proposal
              </.button>
            </div>
          </div>

          <.notice :if={not @owner?} variant="info" icon="info" class="mt-6">
            <span data-read-only>
              You are reviewing this proposal read-only. Only the project owner can approve or
              reject it.
            </span>
          </.notice>

          <section
            class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
            aria-labelledby="versions-heading"
            data-profile-versions
          >
            <h2 id="versions-heading" class="text-base font-bold text-ink">
              Approved profile versions
            </h2>

            <ul :if={@profiles != []} class="mt-4 space-y-2">
              <li
                :for={profile <- @profiles}
                class="rounded-lg border border-line bg-raised px-3 py-2"
                data-profile-version={profile.version}
              >
                <p class="text-[13px] font-semibold text-ink">Version {profile.version}</p>
                <p class="mt-1 break-all font-mono text-xs text-ink-muted">
                  {profile.base_revision}
                </p>
                <p class="mt-1 text-xs text-ink-muted">
                  Approved {approved_at(profile.approved_at)} · {length(profile.commands)} commands
                </p>
              </li>
            </ul>

            <p :if={@profiles == []} class="mt-4 text-sm text-ink-muted" data-no-profile-versions>
              No profile version has been approved yet.
            </p>
          </section>
        </div>
      </div>
    </.app_shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :field, :string, required: true
  attr :code?, :boolean, default: false

  defp profile_field(assigns) do
    ~H"""
    <div class="min-w-0 rounded-lg border border-line bg-surface p-3" data-profile-field={@field}>
      <dt class="text-xs font-semibold text-ink-muted">{@label}</dt>
      <dd class={["mt-1 break-all text-sm font-semibold text-ink", @code? && "font-mono text-xs"]}>
        {@value}
      </dd>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :items, :list, required: true
  attr :empty, :string, required: true
  attr :code?, :boolean, default: false
  attr :coded?, :boolean, default: false
  attr :blocker?, :boolean, default: false

  defp proposal_section(assigns) do
    assigns = assign(assigns, :flagged?, assigns.blocker? and assigns.items != [])

    ~H"""
    <section
      class={[
        "mt-4 rounded-xl border p-4 sm:p-5",
        (@flagged? && "border-err-fg/40 bg-err-bg") || "border-line bg-surface"
      ]}
      aria-labelledby={"proposal-#{@field}-heading"}
      data-proposal-field={@field}
    >
      <h2
        id={"proposal-#{@field}-heading"}
        class="flex items-center gap-2 text-base font-bold text-ink"
      >
        <.lucide
          name={(@flagged? && "circle-alert") || "check"}
          class={["size-4 flex-none", (@flagged? && "text-err-fg") || "text-primary"]}
        />
        {@title}
      </h2>
      <p class="mt-1 text-sm leading-relaxed text-ink-muted">{@description}</p>

      <ul :if={@items != []} class="mt-4 space-y-2">
        <li
          :for={item <- @items}
          class="rounded-lg border border-line bg-raised px-3 py-2"
          data-proposal-item
        >
          <span class={[
            "block break-all text-sm text-ink",
            @code? && "font-mono text-xs",
            @coded? && "font-mono text-xs font-semibold"
          ]}>
            {item}
          </span>
          <span :if={@coded?} class="mt-1 block text-[13px] text-ink-muted">
            {blocker_label(item)}
          </span>
        </li>
      </ul>

      <p :if={@items == []} class="mt-4 text-sm text-ink-muted" data-proposal-empty>{@empty}</p>
    </section>
    """
  end
end
