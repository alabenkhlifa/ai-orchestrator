defmodule SddOrchestratorWeb.RepositoryPilotLive do
  @moduledoc """
  Owner selection of one authoritative pilot specification revision.

  The owner chooses among the project's current specifications; committing binds
  the pilot to that exact revision under the current approved execution profile
  version. The screen shows and stores identifiers and one content digest only —
  never a specification document — so the specification store stays the single
  authority. Selecting writes nothing to the repository and imports no backlog
  item. A participant sees the stored pilot read-only.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Participation
  alias SddOrchestrator.RepositoryPilots

  @owner_only_message "Only the project owner can select the pilot specification."

  @stale_message "That revision is no longer the current one for this specification. " <>
                   "No pilot was selected. Review the current revision, then select it again."

  @no_profile_message "This repository has no approved execution profile yet, so no pilot can " <>
                        "be selected. Approve an execution profile first."

  @failed_message "The pilot could not be selected. Nothing was stored and the repository is " <>
                    "unchanged. Try again."

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_context(socket.assigns.live_action, project_id, socket) do
      {:ok, context} ->
        {:ok,
         socket
         |> assign(context)
         |> assign(:page_title, "Pilot specification")
         |> assign(:message, nil)
         |> assign(:selectable, [])
         |> assign(:pilot, nil)
         |> assign(:stage, :unavailable)
         |> load_pilot()}

      {:error, destination} ->
        {:ok, push_navigate(socket, to: destination)}
    end
  end

  @impl true
  def handle_event("select_pilot", params, socket) do
    if selectable?(socket) do
      commit(socket, params)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  defp selectable?(%{assigns: assigns}),
    do: assigns.owner? and assigns.stage in [:select, :selected]

  defp commit(socket, params) do
    socket.assigns.viewer
    |> RepositoryPilots.select(socket.assigns.project.id, %{
      specification_id: params["specification_id"],
      revision_id: params["revision_id"]
    })
    |> case do
      {:ok, pilot} ->
        {:noreply,
         socket
         |> load_pilot()
         |> assign(
           :message,
           {:ok,
            "Pilot set to this specification revision under profile version " <>
              "#{pilot.profile_version}. No repository file or backlog item was changed."}
         )}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: socket.assigns.denied_destination)}

      {:error, :stale_revision} ->
        {:noreply, socket |> load_pilot() |> assign(:message, {:warn, @stale_message})}

      {:error, :no_approved_profile} ->
        {:noreply, socket |> load_pilot() |> assign(:message, {:warn, @no_profile_message})}

      {:error, _safe_failure} ->
        {:noreply, socket |> load_pilot() |> assign(:message, {:warn, @failed_message})}
    end
  end

  # A participant never reaches the specification store: only the stored pointer
  # is read for them, so the selectable list stays empty.
  defp load_pilot(socket) do
    pilot = stored_pilot(socket)
    selectable = if socket.assigns.owner?, do: selectable_specifications(socket), else: []

    socket
    |> assign(:pilot, pilot)
    |> assign(:selectable, selectable)
    |> assign(:stage, stage(socket.assigns.owner?, pilot, selectable))
  end

  defp stage(_owner?, %{} = _pilot, _selectable), do: :selected
  defp stage(true, nil, [_first | _rest]), do: :select
  defp stage(_owner?, nil, _selectable), do: :unavailable

  defp stored_pilot(socket) do
    case RepositoryPilots.current(socket.assigns.viewer, socket.assigns.project.id) do
      {:ok, pilot} -> pilot
      {:error, :not_found} -> nil
    end
  end

  defp selectable_specifications(socket) do
    case RepositoryPilots.selectable_specifications(
           socket.assigns.viewer,
           socket.assigns.project.id
         ) do
      {:ok, specifications} -> specifications
      {:error, _unavailable} -> []
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
         denied_destination: ~p"/onboarding/local",
         back_destination: ~p"/local/projects/#{project.id}"
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

  # Ownership is resolved first because the owner's authority is what a
  # selection needs; participation only widens the read.
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
    %{
      project: project,
      viewer: viewer,
      owner?: owner?,
      denied_destination: ~p"/projects",
      back_destination:
        if(owner?,
          do: ~p"/projects/#{project.id}/overview",
          else: ~p"/projects/#{project.id}/features"
        )
    }
  end

  defp active_hosted_project?(project),
    do: project.storage_mode == "hosted" and project.lifecycle_state == "active"

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

  defp message_variant({:ok, _text}), do: "info"
  defp message_variant({:warn, _text}), do: "err"

  defp message_icon({:ok, _text}), do: "circle-check"
  defp message_icon({:warn, _text}), do: "circle-alert"

  defp selected_at(%DateTime{} = selected_at),
    do: Calendar.strftime(selected_at, "%Y-%m-%d %H:%M UTC")

  defp current_pilot?(nil, _specification), do: false

  defp current_pilot?(pilot, specification),
    do:
      pilot.specification_id == specification.id and
        pilot.revision_id == specification.revision_id

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
        data-screen="repository-pilot"
        data-pilot-stage={@stage}
        data-pilot-role={if @owner?, do: "owner", else: "participant"}
      >
        <div class="max-w-2xl">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Owner decision</p>
          <h1 class="mt-1 text-2xl font-bold text-ink">Select the pilot specification</h1>
          <p class="mt-2 text-sm leading-relaxed text-ink-muted">
            A pilot bounds adoption to one current Orchestrator feature. It references the
            specification you choose; it never copies it and it imports no repository backlog item.
          </p>
        </div>

        <section
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="pilot-boundary-heading"
        >
          <div class="flex items-start gap-3">
            <span class="rounded-lg bg-info-bg p-2 text-info-fg">
              <.lucide name="shield" class="size-5" />
            </span>
            <div class="min-w-0">
              <h2 id="pilot-boundary-heading" class="text-base font-bold text-ink">
                Selecting a pilot changes nothing in your repository
              </h2>
              <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                Only a reference is stored: the specification, its exact revision, that revision's
                content digest, and the approved execution profile version. No specification text is
                copied and no repository issue, ticket, or backlog item is imported or changed.
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
          <span data-pilot-message>{elem(@message, 1)}</span>
        </.notice>

        <.notice
          :if={@stage == :unavailable and @owner?}
          variant="err"
          icon="circle-alert"
          class="mt-6"
        >
          <span data-pilot-unavailable>
            No current specification is available for this project, so there is nothing to pilot.
            Create a specification, then select it here.
          </span>
        </.notice>

        <section
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="current-pilot-heading"
        >
          <h2 id="current-pilot-heading" class="text-base font-bold text-ink">Current pilot</h2>

          <dl :if={@pilot} class="mt-5 grid gap-3 sm:grid-cols-2">
            <.pilot_field label="Specification" value={@pilot.specification_id} field="specification" />
            <.pilot_field label="Revision" value={@pilot.revision_id} field="revision" />
            <.pilot_field
              label="Revision digest"
              value={@pilot.revision_digest}
              field="revision-digest"
            />
            <.pilot_field
              label="Execution profile version"
              value={@pilot.profile_version}
              field="profile-version"
            />
          </dl>

          <p :if={@pilot} class="mt-4 text-sm text-ink-muted">
            Selected {selected_at(@pilot.selected_at)}.
          </p>

          <p :if={is_nil(@pilot)} class="mt-4 text-sm text-ink-muted" data-no-pilot>
            No pilot specification has been selected yet.
          </p>
        </section>

        <section
          :if={@owner? and @selectable != []}
          class="mt-4 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="selectable-heading"
        >
          <h2 id="selectable-heading" class="text-base font-bold text-ink">
            Current authoritative specifications
          </h2>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted">
            Each entry is the current revision at this moment. If it changes before you commit, the
            selection is refused rather than bound to an older revision.
          </p>

          <ul class="mt-4 space-y-2">
            <li
              :for={specification <- @selectable}
              class="flex flex-col gap-3 rounded-lg border border-line bg-raised px-3 py-3 sm:flex-row sm:items-center sm:justify-between"
              data-selectable-specification={specification.id}
            >
              <div class="min-w-0">
                <p class="text-[13px] font-semibold text-ink">{specification.title}</p>
                <p class="mt-1 break-all font-mono text-xs text-ink-muted">
                  {specification.revision_id}
                </p>
              </div>
              <.button
                :if={not current_pilot?(@pilot, specification)}
                size="sm"
                class="w-full sm:w-auto"
                phx-click="select_pilot"
                phx-value-specification_id={specification.id}
                phx-value-revision_id={specification.revision_id}
                data-select-pilot={specification.id}
              >
                <.lucide name="check" class="size-4" /> Select as pilot
              </.button>
              <span
                :if={current_pilot?(@pilot, specification)}
                class="text-xs font-semibold text-ink-muted"
                data-current-pilot
              >
                Current pilot
              </span>
            </li>
          </ul>
        </section>

        <.notice :if={not @owner?} variant="info" icon="info" class="mt-6">
          <span data-read-only>
            You are viewing this pilot read-only. Only the project owner can select it, and the
            specification itself stays in the specification store.
          </span>
        </.notice>
      </div>
    </.app_shell>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :field, :string, required: true

  defp pilot_field(assigns) do
    ~H"""
    <div class="min-w-0 rounded-lg border border-line bg-surface p-3" data-pilot-field={@field}>
      <dt class="text-xs font-semibold text-ink-muted">{@label}</dt>
      <dd class="mt-1 break-all font-mono text-xs font-semibold text-ink">{@value}</dd>
    </div>
    """
  end
end
