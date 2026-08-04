defmodule SddOrchestratorWeb.RepositoryAssessmentLive do
  @moduledoc """
  Owner-controlled disclosure and exact-binding review for repository assessment.

  The first submit is the processing-boundary confirmation. Only that event may
  request metadata from a currently reachable paired worker. The returned
  binding is short-lived and contains no repository path or content. A separate
  submit consumes that binding through the authoritative assessment service and
  persists one `pending_scan` record without issuing a scan command.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{Pairing, WorkerDiscovery}
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  @scanner_contract_version "repository-assessment-scanner-contract-v1"
  @scanner_contract_digest :crypto.hash(:sha256, @scanner_contract_version)
                           |> Base.encode16(case: :lower)

  @disclosure_items [
    %{
      key: "surfaces",
      title: "Inspected surfaces",
      icon: "search",
      body:
        "Agent instructions, contribution rules, project manifests, CI definitions, test and build commands, and repository structure."
    },
    %{
      key: "local",
      title: "Stays worker-local",
      icon: "hard-drive",
      body:
        "Raw source, the scan index, absolute paths, Git history, remote URLs, credentials, ignored secrets, dependencies, build output, binaries, and raw diagnostics stay on the authorized worker."
    },
    %{
      key: "transfer",
      title: "Minimized transfer",
      icon: "arrow-right",
      body:
        "Only the structured assessment, relative evidence anchors, outcome metadata, the worker-generated minimized proposal envelope of normalized commands, required checks, allowed scope, gaps, conflicts, and multi-root blockers, the approved profile, and any specifically disclosed bounded and redacted excerpt may enter authoritative project storage. No whole-repository source or hosted index is transferred."
    },
    %{
      key: "processors",
      title: "Processors and models",
      icon: "info",
      body:
        "The selected paired worker processes repository data locally. Authoritative project storage receives only minimized results. A configured model or other processor receives approved content only when that transfer is enabled and shown; this boundary permits no analytics, advertising, training, or unrelated reuse."
    },
    %{
      key: "retention",
      title: "Retention",
      icon: "refresh-cw",
      body:
        "The metadata binding is short-lived and single-use. Minimized assessment records follow the authoritative project lifecycle; raw source and its index are not retained by the hosted control plane, and incomplete results are not reusable as a successful cache entry."
    },
    %{
      key: "purpose",
      title: "Purpose",
      icon: "check",
      body:
        "Build a reliable execution profile for one managed SDD pilot in this project, while keeping existing repository instructions authoritative."
    },
    %{
      key: "limits",
      title: "Configured limits",
      icon: "info",
      body:
        "Read-only inspection stops at the configured file-count, byte, path, and elapsed-time caps and is limited to the approved high-signal surfaces under the selected root."
    },
    %{
      key: "explicit-limits",
      title: "Explicit limits",
      icon: "circle-alert",
      body:
        "This step does not scan or modify the repository, upload source, import backlog items, invent verification commands, resolve instruction conflicts, approve a profile, or create an account-to-device association."
    }
  ]

  @disclosure_digest :crypto.hash(
                       :sha256,
                       :erlang.term_to_binary(@disclosure_items, [:deterministic])
                     )
                     |> Base.encode16(case: :lower)

  @doc false
  def disclosure_items, do: @disclosure_items

  @doc false
  def disclosure_digest, do: @disclosure_digest

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_context(socket.assigns.live_action, project_id, socket) do
      {:ok, context} ->
        {:ok,
         socket
         |> assign(context)
         |> assign(:page_title, "Repository assessment")
         |> assign(:stage, :disclosure)
         |> assign(:preparation, nil)
         |> assign(:assessment, nil)
         |> assign(:disclosure_items, @disclosure_items)
         |> assign(:selected_root, ".")
         |> assign(:error_message, nil)
         |> assign_workers()}

      {:error, destination} ->
        {:ok, push_navigate(socket, to: destination)}
    end
  end

  @impl true
  def handle_event("confirm_boundary", %{"assessment" => params}, socket) do
    socket = assign_workers(socket)

    with true <- socket.assigns.stage == :disclosure,
         true <- params["confirmed"] == "true",
         {:ok, worker} <- selected_worker(socket.assigns.worker_choices, params["worker_ref"]),
         root when is_binary(root) <- params["selected_root"],
         attrs <- binding_attrs(worker, root),
         {:ok, preparation} <-
           RepositoryAssessments.prepare_binding(
             socket.assigns.authority,
             socket.assigns.project.id,
             attrs
           ) do
      {:noreply,
       socket
       |> assign(:stage, :binding)
       |> assign(:preparation, preparation)
       |> assign(:selected_root, preparation.root)
       |> assign(:error_message, nil)}
    else
      false ->
        {:noreply,
         assign(socket, :error_message, "Confirm the processing boundary and choose a worker.")}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: socket.assigns.denied_destination)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_message, preparation_error(reason))}

      _invalid ->
        {:noreply,
         assign(
           socket,
           :error_message,
           "Choose one valid repository-relative root and try again."
         )}
    end
  end

  def handle_event("confirm_boundary", _params, socket) do
    {:noreply,
     assign(socket, :error_message, "Confirm the processing boundary and choose a worker.")}
  end

  def handle_event("start_assessment", _params, %{assigns: %{preparation: nil}} = socket) do
    {:noreply, reset_for_verification(socket, "Verify the repository binding before starting.")}
  end

  def handle_event("start_assessment", _params, socket) do
    case RepositoryAssessments.start_assessment(
           socket.assigns.authority,
           socket.assigns.project.id,
           socket.assigns.preparation
         ) do
      {:ok, assessment} ->
        {:noreply,
         socket
         |> assign(:stage, :pending)
         |> assign(:assessment, assessment)
         |> assign(:preparation, nil)
         |> assign(:error_message, nil)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: socket.assigns.denied_destination)}

      {:error, reason} when reason in [:stale, :expired, :unknown_or_replayed] ->
        {:noreply,
         reset_for_verification(
           socket,
           "The verified binding changed or expired. No assessment was saved. Verify it again."
         )}

      {:error, _safe_failure} ->
        {:noreply,
         assign(
           socket,
           :error_message,
           "The assessment could not be saved. No scan was started. Try again."
         )}
    end
  end

  defp load_context(:hosted, project_id, socket) do
    account_id = acting_account_id(socket)

    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         project <- Repo.preload(project, :repository_connection),
         true <- active_hosted_project?(project) do
      {:ok,
       %{
         project: project,
         authority: {:hosted, account_id},
         authority_kind: :hosted,
         denied_destination: ~p"/projects",
         back_destination: ~p"/projects/#{project.id}/overview",
         repository_display: hosted_repository_display(project)
       }}
    else
      _unauthorized -> {:error, ~p"/projects"}
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
         authority: {:device, workspace},
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

  defp active_hosted_project?(project) do
    project.storage_mode == "hosted" and project.lifecycle_state == "active" and
      match?(%{state: "connected"}, project.repository_connection)
  end

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

  defp assign_workers(socket) do
    assign(socket, :worker_choices, reachable_workers())
  end

  defp reachable_workers do
    with {:ok, %DeviceWorkspace{id: workspace_id}} <- Devices.get_workspace() do
      workspace_id
      |> Pairing.active_workers()
      |> Enum.filter(&(WorkerDiscovery.status([&1]) == :detected))
      |> Enum.sort_by(& &1.inserted_at, DateTime)
      |> Enum.with_index(1)
      |> Enum.map(fn {worker, index} ->
        %{
          id: worker.id,
          device_workspace_id: worker.device_workspace_id,
          label: worker_label(worker, index)
        }
      end)
    else
      _unavailable -> []
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp worker_label(worker, index) do
    platform =
      case {worker.os_family, worker.os_major} do
        {"macos", major} when is_binary(major) -> "macOS #{major}"
        {family, major} when is_binary(family) and is_binary(major) -> "#{family} #{major}"
        _unknown -> "paired device"
      end

    "Available worker #{index} · #{platform}"
  end

  defp selected_worker(choices, worker_ref) when is_binary(worker_ref) do
    case Enum.find(choices, &(&1.id == worker_ref)) do
      nil -> {:error, :worker_unavailable}
      worker -> {:ok, worker}
    end
  end

  defp selected_worker(_choices, _worker_ref), do: {:error, :worker_unavailable}

  defp binding_attrs(worker, root) do
    %{
      device_workspace_id: worker.device_workspace_id,
      worker_ref: worker.id,
      selection_ref: "assessment-root-#{Ecto.UUID.generate()}",
      selected_root: root,
      scanner_contract_digest: @scanner_contract_digest,
      disclosure_digest: @disclosure_digest,
      confirmed_disclosure_digest: @disclosure_digest
    }
  end

  defp reset_for_verification(socket, message) do
    socket
    |> assign(:stage, :disclosure)
    |> assign(:preparation, nil)
    |> assign(:error_message, message)
    |> assign_workers()
  end

  defp preparation_error(:worker_unavailable),
    do: "That worker is no longer available. Start or reconnect it, then try again."

  defp preparation_error(:repository_mismatch),
    do:
      "That worker did not verify this project's connected repository. Reconnect the correct repository and try again."

  defp preparation_error(reason) when reason in [:root_mismatch, :invalid_request],
    do:
      "That repository root could not be verified. Choose one contained relative root and try again."

  defp preparation_error(:processing_boundary_confirmation_required),
    do: "Review and confirm the processing boundary before verifying the repository."

  defp preparation_error(_safe_failure),
    do: "The repository binding could not be verified. No scan was started. Try again."

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

      <div data-screen="repository-assessment" data-assessment-stage={@stage}>
        <.project_nav
          :if={@authority_kind == :hosted}
          project_id={@project.id}
          current={:assessment}
          owner?={true}
          class="mb-6"
        />

        <div class="max-w-2xl">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">Read-only setup</p>
          <h1 class="mt-1 text-2xl font-bold text-ink">Assess this repository</h1>
          <p class="mt-2 text-sm leading-relaxed text-ink-muted">
            Review the processing boundary first. Repository metadata is requested only after
            your confirmation, and starting the assessment is a separate action.
          </p>
        </div>

        <section class="mt-6" aria-labelledby="processing-boundary-heading" data-disclosure>
          <div class="rounded-xl border border-line bg-surface p-4 sm:p-5">
            <div class="flex items-start gap-3">
              <span class="rounded-lg bg-info-bg p-2 text-info-fg">
                <.lucide name="shield" class="size-5" />
              </span>
              <div>
                <h2 id="processing-boundary-heading" class="text-base font-bold text-ink">
                  Processing boundary
                </h2>
                <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                  This confirmation covers one exact repository commit and one selected root.
                </p>
              </div>
            </div>

            <dl class="mt-5 grid gap-4 md:grid-cols-2">
              <.disclosure_item
                :for={item <- @disclosure_items}
                title={item.title}
                icon={item.icon}
                data_field={item.key}
              >
                {item.body}
              </.disclosure_item>
            </dl>
          </div>
        </section>

        <.notice :if={@error_message} variant="warn" icon="triangle-alert" class="mt-4">
          <span data-assessment-error>{@error_message}</span>
        </.notice>

        <section
          :if={@stage == :disclosure}
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="binding-heading"
          data-binding-form
        >
          <h2 id="binding-heading" class="text-base font-bold text-ink">Choose one root</h2>
          <p class="mt-1 text-sm leading-relaxed text-ink-muted">
            The worker verifies this relative root is contained in the connected project
            repository. Only one root is supported for this assessment.
          </p>

          <form id="assessment-binding-form" phx-submit="confirm_boundary" class="mt-5">
            <.text_field
              id="assessment-root"
              name="assessment[selected_root]"
              label="Repository-relative root"
              value={@selected_root}
              hint={"Use \".\" for the repository root, or one contained relative directory."}
              autocomplete="off"
              required
            />

            <div class="mt-5">
              <label for="assessment-worker" class="block text-[13px] font-semibold text-ink">
                Reachable paired worker
              </label>
              <select
                id="assessment-worker"
                name="assessment[worker_ref]"
                required
                class="mt-1.5 h-10 w-full rounded-lg border border-line-strong bg-surface px-3 text-sm text-ink focus:outline focus:outline-2 focus:outline-focus"
              >
                <option value="">Choose a currently available worker</option>
                <option :for={worker <- @worker_choices} value={worker.id}>{worker.label}</option>
              </select>
              <p class="mt-2 text-xs text-ink-muted">
                Choosing this worker is explicit for this assessment and does not link your
                account to its device.
              </p>
              <p
                :if={@worker_choices == []}
                class="mt-2 text-xs font-semibold text-warn-fg"
                data-no-workers
              >
                No reachable paired worker is available. Start or pair one, then return here.
              </p>
            </div>

            <label class="mt-5 flex items-start gap-3 rounded-lg border border-line bg-raised p-3 text-sm text-ink">
              <input
                id="assessment-confirmed"
                type="checkbox"
                name="assessment[confirmed]"
                value="true"
                required
                class="mt-0.5 size-4 rounded border-line-strong text-primary focus:outline focus:outline-2 focus:outline-focus"
              />
              <span>
                I confirm this processing boundary and authorize the selected worker to verify
                repository identity, this one root, and the current full commit.
              </span>
            </label>

            <.button
              type="submit"
              class="mt-5 w-full sm:w-auto"
              disabled={@worker_choices == []}
              data-confirm-boundary
            >
              <.lucide name="shield" class="size-4" /> Confirm and verify repository
            </.button>
          </form>

          <p class="mt-3 text-xs text-ink-muted" data-before-confirmation>
            No repository metadata call or scan command is issued before confirmation.
          </p>
        </section>

        <section
          :if={@stage == :binding}
          class="mt-6 rounded-xl border border-ok-fg/40 bg-ok-bg p-4 sm:p-5"
          aria-labelledby="verified-binding-heading"
          data-verified-binding
        >
          <div class="flex items-start gap-3">
            <.lucide name="circle-check" class="mt-0.5 size-5 flex-none text-ok-fg" />
            <div class="min-w-0">
              <h2 id="verified-binding-heading" class="text-base font-bold text-ink">
                Verified repository binding
              </h2>
              <p class="mt-1 text-sm text-ink-muted">
                Review the exact binding before separately starting the assessment.
              </p>
            </div>
          </div>

          <dl class="mt-5 grid gap-3 sm:grid-cols-2">
            <.binding_field label="Repository" value={@repository_display} field="repository" />
            <.binding_field
              label="Verified identity"
              value={"#{@preparation.repository_provider}:#{@preparation.repository_id}"}
              field="identity"
            />
            <.binding_field label="Normalized root" value={@preparation.root} field="root" />
            <.binding_field
              label="Full exact commit"
              value={@preparation.commit}
              field="commit"
              code?={true}
            />
          </dl>

          <form id="assessment-start-form" phx-submit="start_assessment" class="mt-5">
            <.button type="submit" class="w-full sm:w-auto" data-start-assessment>
              <.lucide name="play" class="size-4" /> Start assessment
            </.button>
          </form>
          <p class="mt-3 text-xs text-ink-muted">
            Starting saves a pending assessment. This task sends no repository scan command.
          </p>
        </section>

        <section
          :if={@stage == :pending}
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="pending-heading"
          data-assessment-pending
        >
          <div class="flex items-start gap-3">
            <span class="rounded-lg bg-info-bg p-2 text-info-fg">
              <.lucide name="refresh-cw" class="size-5" />
            </span>
            <div>
              <h2 id="pending-heading" class="text-base font-bold text-ink">
                Assessment request saved
              </h2>
              <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                State: <span class="font-semibold text-ink" data-assessment-state>Pending scan</span>.
                The exact repository binding is persisted in authoritative project storage.
                No repository scan command has been issued yet.
              </p>
            </div>
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :data_field, :string, required: true
  slot :inner_block, required: true

  defp disclosure_item(assigns) do
    ~H"""
    <div data-disclosure-field={@data_field}>
      <dt class="flex items-center gap-2 text-[13px] font-semibold text-ink">
        <.lucide name={@icon} class="size-4 flex-none text-primary" /> {@title}
      </dt>
      <dd class="mt-1 text-[13px] leading-relaxed text-ink-muted">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :field, :string, required: true
  attr :code?, :boolean, default: false

  defp binding_field(assigns) do
    ~H"""
    <div class="min-w-0 rounded-lg border border-line bg-surface p-3" data-binding-field={@field}>
      <dt class="text-xs font-semibold text-ink-muted">{@label}</dt>
      <dd class={["mt-1 break-all text-sm font-semibold text-ink", @code? && "font-mono text-xs"]}>
        {@value}
      </dd>
    </div>
    """
  end
end
