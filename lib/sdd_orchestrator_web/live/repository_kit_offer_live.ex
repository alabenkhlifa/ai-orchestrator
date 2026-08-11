defmodule SddOrchestratorWeb.RepositoryKitOfferLive do
  @moduledoc """
  Post-pilot optional permanent-kit offer: eligibility, decline, and the
  exact reviewable diff.

  Hosted only for now: `RepositoryKits.plan_change/4` persists a
  `RepositoryKitChangePlan` only for a `{:hosted, account_id}` authority (see
  that schema's moduledoc and Task 2's progress log) — device dual-authority
  support is explicitly a later task's job, so there is no
  `/local/projects/:id/kit` route here.

  This view presents the offer, lets the owner decline it, renders Task 2's
  exact plan read-only, and — new in Task 4 — lets the owner apply a
  conflict-free plan on a new isolated branch through
  `RepositoryKits.apply_plan/4`. It still owns AC-01 alone (the kit is
  clearly optional, and declining leaves managed runtime SDD available); the
  apply control itself is Task 4's AC-06/AC-07/AC-08 surface. The "Apply this
  plan" action only ever appears for the owner and only when the current
  plan has no safety or ordinary conflict — a conflicting plan stays exactly
  as read-only as before, and `apply_plan/4` itself refuses defensively even
  if this screen's button were somehow reached anyway (stale DOM, event
  replay).

  Task 5 adds a persistent `:installed` stage, derived from
  `RepositoryKits.current_installation/3` every time `load_offer/1` runs, so
  "just applied" and "reload the page after installing" render through the
  exact same code path — the transient `:applied` stage Task 4 introduced is
  gone. `:installed` takes precedence over the original offer/plan flow:
  once a project has an installation, an old install-type plan no longer
  applies to it. From `:installed`, the owner may see an informational "a
  newer version is available" notice (AC-10 — never selected or applied
  automatically) and build an update plan (`RepositoryKits.plan_update/4`),
  reviewed read-only on the `:update_plan` stage exactly like an install
  plan — and, like `:plan`, re-derived from the persisted plan row on every
  reload until it is applied, so a mid-review reload never loses it — then
  applied through the same `apply_plan/4` call and `apply_plan` event.

  Task 6 adds the symmetric removal workflow (AC-11). From `:installed`, the
  owner may also start a "Remove this kit" action — independent of and
  coexisting with the update notice above, not mutually exclusive with it —
  building a removal plan (`RepositoryKits.plan_removal/3`) reviewed
  read-only on the `:removal_plan` stage, re-derived from the persisted plan
  row exactly like `:plan` and `:update_plan` are, then applied through the
  same `apply_plan/4` call and `apply_plan` event. Once a removal plan is
  applied, the installation's `state` becomes `"removed"` and every reload
  renders the terminal `:removed` stage instead — checked first, ahead of
  every other stage rule, since a removed installation is never "installed"
  again regardless of what plan row happens to be current.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Participation
  alias SddOrchestrator.RepositoryKits

  alias SddOrchestrator.RepositoryKits.{
    RepositoryKitChangePlan,
    RepositoryKitInstallation,
    RepositoryKitPackage
  }

  alias SddOrchestrator.RepositoryPilots

  @max_preview_bytes 20_000

  @owner_only_message "Only the project owner can build a plan or decline this offer."

  @no_worker_message "Building this plan needs a connected worker with this repository " <>
                       "checked out. That connection is not available from this screen yet " <>
                       "— nothing was changed."

  @not_yet_eligible_message "This offer is no longer available right now. Managed runtime " <>
                              "SDD is unaffected."

  @plan_failed_message "The plan could not be built. Nothing was stored. Try again."

  @plan_expired_message "This plan expired. Review the plan again before applying."

  @conflict_blocks_apply_message "This plan has a conflict that blocks application. Resolve " <>
                                   "it before it can be applied."

  @already_installed_message "This plan was already applied."

  @apply_failed_message "The plan could not be applied. Nothing was changed. Try again."

  @update_plan_failed_message "The update plan could not be built. Nothing was stored. Try again."

  @removal_plan_failed_message "The removal plan could not be built. Nothing was stored. " <>
                                 "Try again."

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_context(project_id, socket) do
      {:ok, context} ->
        {:ok,
         socket
         |> assign(context)
         |> assign(:page_title, "Repository SDD kit")
         |> assign(:message, nil)
         |> assign(:declined?, false)
         |> load_offer()}

      {:error, destination} ->
        {:ok, push_navigate(socket, to: destination)}
    end
  end

  @impl true
  def handle_event("build_plan", _params, socket) do
    if actionable?(socket) do
      build_plan(socket)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  def handle_event("decline", _params, socket) do
    if actionable?(socket) do
      # No persistence exists for "declined" — Task 2 built no such field, and
      # the business rule only requires that declining leaves managed runtime
      # SDD available, not that a decline be recorded anywhere. This is
      # UI-only: it flips a local, non-persisted assign back to a calm state
      # and calls no RepositoryKits function. Reloading the page re-offers
      # the kit exactly as before.
      {:noreply,
       socket
       |> assign(:declined?, true)
       |> assign(:stage, :declined)
       |> assign(:message, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("apply_plan", _params, socket) do
    if plan_actionable?(socket) do
      apply_plan(socket)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  def handle_event("build_update_plan", _params, socket) do
    if installed_actionable?(socket) do
      build_update_plan(socket)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  def handle_event("build_removal_plan", _params, socket) do
    if installed_actionable?(socket) do
      build_removal_plan(socket)
    else
      {:noreply, assign(socket, :message, {:warn, @owner_only_message})}
    end
  end

  defp actionable?(%{assigns: assigns}), do: assigns.owner? and assigns.stage == :offer

  defp plan_actionable?(%{assigns: assigns}),
    do: assigns.owner? and assigns.stage in [:plan, :update_plan, :removal_plan]

  defp installed_actionable?(%{assigns: assigns}),
    do: assigns.owner? and assigns.stage == :installed

  defp apply_plan(socket) do
    # `opts[:repository_path]` is deliberately not supplied, for the exact
    # same reason `build_plan/1` above omits it: no code path in this
    # codebase resolves a worker-local repository checkout directory
    # synchronously inside a hosted LiveView process yet. This calls
    # `apply_plan/4` for real and lets its own `fetch_repository_path/1`
    # step refuse with the atom it already defines for "no path was given"
    # — the same already-declared release-gate gap `build_plan/1` surfaces,
    # not a new one invented here.
    socket.assigns.viewer
    |> RepositoryKits.apply_plan(socket.assigns.project.id, socket.assigns.plan.id)
    |> case do
      {:ok, _installation} ->
        {:noreply, socket |> load_offer() |> assign(:message, nil)}

      {:error, :repository_path_required} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @no_worker_message})}

      {:error, :plan_expired} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @plan_expired_message})}

      {:error, reason} when reason in [:safety_conflict_present, :ordinary_conflicts_present] ->
        {:noreply,
         socket |> load_offer() |> assign(:message, {:warn, @conflict_blocks_apply_message})}

      {:error, :already_installed} ->
        {:noreply,
         socket |> load_offer() |> assign(:message, {:warn, @already_installed_message})}

      {:error, _reason} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @apply_failed_message})}
    end
  end

  defp build_plan(socket) do
    # `opts[:repository_path]` is deliberately not supplied. No code path in
    # this codebase resolves a worker-local repository checkout directory
    # synchronously inside a hosted LiveView process — every worker-facing
    # precedent (RepositoryAssessmentLive's disclosure items, this project's
    # design.md data boundary: "Repository credentials and worker credentials
    # never enter package content or project-visible diffs") keeps raw
    # repository content and absolute paths strictly worker-local, reached
    # only through an asynchronous paired-worker protocol that never hands a
    # filesystem path back to the control plane. Inventing one here would
    # fabricate a path that points at no real, authorized checkout, which is
    # worse than surfacing the gap. So this calls `plan_change/4` for real,
    # and lets its own `fetch_repository_path/1` step refuse with the exact
    # atom it already defines for "no path was given" — a genuine, reported
    # gap for a later task to close, not a silently invented workaround.
    socket.assigns.viewer
    |> RepositoryKits.plan_change(socket.assigns.project.id, socket.assigns.package.id)
    |> case do
      {:ok, plan} ->
        {:noreply,
         socket
         |> assign(:plan, plan)
         |> assign(:stage, :plan)
         |> assign(:message, nil)}

      {:error, :repository_path_required} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @no_worker_message})}

      {:error, :not_yet_eligible} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @not_yet_eligible_message})}

      {:error, _safe_failure} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @plan_failed_message})}
    end
  end

  defp build_update_plan(socket) do
    case newer_package(socket.assigns.installation) do
      nil ->
        {:noreply,
         socket |> load_offer() |> assign(:message, {:warn, @update_plan_failed_message})}

      package ->
        # `opts[:repository_path]` is deliberately not supplied, for the exact
        # same already-documented reason `build_plan/1` and `apply_plan/1`
        # above omit it — the same accepted release-gate gap, not a new one.
        socket.assigns.viewer
        |> RepositoryKits.plan_update(socket.assigns.project.id, package.id)
        |> case do
          {:ok, plan} ->
            {:noreply,
             socket
             |> assign(:plan, plan)
             |> assign(:stage, :update_plan)
             |> assign(:message, nil)}

          {:error, :repository_path_required} ->
            {:noreply, socket |> load_offer() |> assign(:message, {:warn, @no_worker_message})}

          {:error, _reason} ->
            {:noreply,
             socket |> load_offer() |> assign(:message, {:warn, @update_plan_failed_message})}
        end
    end
  end

  defp build_removal_plan(socket) do
    # `opts[:repository_path]` is deliberately not supplied, for the exact
    # same already-documented reason `build_plan/1`, `apply_plan/1`, and
    # `build_update_plan/1` above omit it — the same accepted release-gate
    # gap, not a new one.
    socket.assigns.viewer
    |> RepositoryKits.plan_removal(socket.assigns.project.id)
    |> case do
      {:ok, plan} ->
        {:noreply,
         socket
         |> assign(:plan, plan)
         |> assign(:stage, :removal_plan)
         |> assign(:message, nil)}

      {:error, :repository_path_required} ->
        {:noreply, socket |> load_offer() |> assign(:message, {:warn, @no_worker_message})}

      {:error, _reason} ->
        {:noreply,
         socket |> load_offer() |> assign(:message, {:warn, @removal_plan_failed_message})}
    end
  end

  ## Offer state loading

  defp load_offer(socket) do
    project_id = socket.assigns.project.id
    viewer = socket.assigns.viewer
    declined? = Map.get(socket.assigns, :declined?, false)

    pilot = stored_pilot(viewer, project_id)
    eligible? = eligible?(pilot, project_id)
    package = current_package()
    plan = stored_plan(viewer, project_id)
    installation = stored_installation(viewer, project_id)

    socket
    |> assign(:pilot, pilot)
    |> assign(:package, package)
    |> assign(:eligible?, eligible?)
    |> assign(:plan, plan)
    |> assign(:installation, installation)
    |> assign(:stage, stage(installation, eligible?, package, plan, declined?))
  end

  defp stored_pilot(viewer, project_id) do
    case RepositoryPilots.current(viewer, project_id) do
      {:ok, pilot} -> pilot
      {:error, :not_found} -> nil
    end
  end

  # No pilot selected yet means the offer is simply never eligible — not an
  # error (see `RepositoryKits.eligible_for_kit_offer?/2`'s own moduledoc).
  defp eligible?(nil, _project_id), do: false

  defp eligible?(pilot, project_id),
    do: RepositoryKits.eligible_for_kit_offer?(project_id, pilot.specification_id)

  # "One current kit package": from the catalog, the one entry not superseded
  # by anything newer. "Multiple kit families" is out of scope for this slice
  # (design.md's deferred work), so an empty catalog or — defensively, should
  # it ever happen — more than one non-superseded entry both read as "no kit
  # currently offered" rather than guessing which one to present.
  defp current_package do
    packages = RepositoryKits.list_packages()

    case Enum.reject(packages, &(RepositoryKits.superseded_by(&1, packages) != nil)) do
      [package] -> package
      _zero_or_many -> nil
    end
  end

  defp stored_plan(viewer, project_id) do
    case RepositoryKits.current_plan(viewer, project_id) do
      {:ok, plan} -> plan
      {:error, :not_found} -> nil
    end
  end

  defp stored_installation(viewer, project_id) do
    case RepositoryKits.current_installation(viewer, project_id) do
      {:ok, installation} -> installation
      {:error, :not_found} -> nil
    end
  end

  # A `"removed"` installation always resolves to the terminal `:removed`
  # stage, checked first (highest precedence) regardless of what plan row
  # happens to be current — once removal is applied there is no plan-type
  # clause below that should ever take over again (AC-11).
  defp stage(
         %RepositoryKitInstallation{state: "removed"},
         _eligible?,
         _package,
         _plan,
         _declined?
       ),
       do: :removed

  # `:installed` takes precedence over the original offer/plan flow — once a
  # project has an installation, an old install-type plan no longer applies
  # to it (AC-10). A still-open *update* plan (built but not yet applied —
  # its `id` has not yet become this installation's own `plan_id`) is the one
  # exception: it is the more specific, more relevant thing to show, and
  # showing it here — re-derived from the persisted plan row on every
  # `load_offer/1`, exactly like `:plan` already is — is what makes it safe
  # to reload the page mid-review without losing the reviewed update plan.
  defp stage(
         %RepositoryKitInstallation{plan_id: installed_plan_id},
         _eligible?,
         _package,
         %RepositoryKitChangePlan{plan_type: "update", id: installed_plan_id},
         _declined?
       ),
       do: :installed

  defp stage(
         %RepositoryKitInstallation{},
         _eligible?,
         _package,
         %RepositoryKitChangePlan{plan_type: "update"},
         _declined?
       ),
       do: :update_plan

  # A still-open *removal* plan (AC-11) is shown the same way: no
  # already-applied counterpart clause is needed here (unlike `:update`'s
  # pair above) because once a removal plan is applied, `state` becomes
  # `"removed"` and the very first clause above already catches it before
  # this pattern would ever be reached.
  defp stage(
         %RepositoryKitInstallation{},
         _eligible?,
         _package,
         %RepositoryKitChangePlan{plan_type: "removal"},
         _declined?
       ),
       do: :removal_plan

  defp stage(%RepositoryKitInstallation{}, _eligible?, _package, _plan, _declined?),
    do: :installed

  defp stage(nil, _eligible?, _package, %RepositoryKitChangePlan{}, _declined?), do: :plan
  defp stage(nil, false, _package, nil, _declined?), do: :not_yet_eligible
  defp stage(nil, true, nil, nil, _declined?), do: :not_yet_eligible
  defp stage(nil, true, %RepositoryKitPackage{}, nil, true), do: :declined
  defp stage(nil, true, %RepositoryKitPackage{}, nil, false), do: :offer

  # The one non-superseded newer package for this installation's own package,
  # or `nil`. Informational only (AC-10) — computing it never mutates
  # anything; only an explicit `build_update_plan` click does.
  defp newer_package(%RepositoryKitInstallation{} = installation) do
    case RepositoryKits.get_package(installation.package_id) do
      {:ok, current_package} ->
        RepositoryKits.superseded_by(current_package, RepositoryKits.list_packages())

      {:error, :not_found} ->
        nil
    end
  end

  ## Context loading — mirrors `RepositoryPilotLive`'s hosted branch exactly.
  ## This route is hosted-only (see moduledoc), so there is no action to
  ## dispatch on and no device branch to copy.

  defp load_context(project_id, socket) do
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

  # Ownership is resolved first because the owner's authority is what a
  # triggered plan needs; participation only widens the read.
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

  ## Plan rendering helpers

  defp plan_review_copy(%{safety_blocked: true}),
    do:
      "This is a read-only review. This plan is blocked by a safety conflict and cannot be " <>
        "applied."

  defp plan_review_copy(%{has_ordinary_conflicts: true}),
    do:
      "This is a read-only review. This plan has conflicts that need manual resolution and " <>
        "cannot be applied automatically."

  defp plan_review_copy(_plan),
    do:
      "Review the exact plan below, then apply it on a new isolated branch when you're ready " <>
        "— nothing is applied automatically."

  defp operations(plan, group), do: Enum.filter(plan.operations, &(group_key(&1) == group))

  # The `:plan` stage's own "New files" group folds `:create` and `:update`
  # back together: at install time (`WorkerKitComparison`) a "create" whose
  # `existing_sha256` happens to be present only ever means "identical
  # content already present" (a harmless no-op), never "will be updated" —
  # that distinction only exists for an update plan's kit-owned comparison.
  # Combining here keeps every install-time create operation visible in the
  # exact reviewable diff rather than silently dropped because it now
  # group-keys as `:update`.
  defp plan_create_operations(plan), do: operations(plan, :create) ++ operations(plan, :update)

  defp group_key(%{"kind" => "create", "existing_sha256" => nil}), do: :create
  defp group_key(%{"kind" => "create"}), do: :update
  defp group_key(%{"kind" => "delete"}), do: :delete
  defp group_key(%{"kind" => "omit"}), do: :omit
  defp group_key(%{"kind" => "conflict", "conflict_severity" => "ordinary"}), do: :ordinary
  defp group_key(%{"kind" => "conflict", "conflict_severity" => "safety"}), do: :safety
  defp group_key(%{"kind" => "conflict", "conflict_severity" => "drifted"}), do: :drifted

  defp show_content?(%{"kind" => "omit"}), do: false
  defp show_content?(_operation), do: true

  defp proposed_content(operation) do
    case Base.decode64(operation["proposed_content_base64"] || "") do
      {:ok, content} -> bounded_preview(content)
      :error -> "(unable to decode proposed content)"
    end
  end

  # Bounded so a large vendored file cannot make this screen unresponsive.
  # Validity is checked on the *whole* decoded content first so truncation
  # always slices on a codepoint boundary (`String.slice/2`) rather than a
  # raw byte offset that could split a multi-byte character; content that
  # is not valid UTF-8 to begin with (a script or binary asset) is never
  # rendered as if it were text.
  defp bounded_preview(content) do
    size = byte_size(content)

    cond do
      not String.valid?(content) ->
        "(binary content — preview unavailable, #{size} bytes)"

      size > @max_preview_bytes ->
        preview = String.slice(content, 0, @max_preview_bytes)

        preview <>
          "\n\n… truncated (#{size} bytes total; showing the first #{byte_size(preview)} bytes)"

      true ->
        content
    end
  end

  defp message_variant({:ok, _text}), do: "info"
  defp message_variant({:warn, _text}), do: "err"

  defp message_icon({:ok, _text}), do: "circle-check"
  defp message_icon({:warn, _text}), do: "circle-alert"

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
        data-screen="repository-kit-offer"
        data-kit-stage={@stage}
        data-kit-role={if @owner?, do: "owner", else: "participant"}
      >
        <div class="max-w-2xl">
          <p class="text-xs font-semibold uppercase tracking-wide text-primary">
            Optional, after your pilot
          </p>
          <h1 class="mt-1 text-2xl font-bold text-ink">Repository SDD kit</h1>
          <p class="mt-2 text-sm leading-relaxed text-ink-muted">
            A permanent kit vendors inspectable workflow files into your repository so
            independently launched agents can discover the SDD contract. Managed runtime SDD
            works fully whether or not you ever install one.
          </p>
        </div>

        <.notice
          :if={@message}
          variant={message_variant(@message)}
          icon={message_icon(@message)}
          class="mt-4"
        >
          <span data-kit-message>{elem(@message, 1)}</span>
        </.notice>

        <section :if={@stage == :not_yet_eligible} class="mt-6" data-kit-not-yet-eligible>
          <.empty_state title="Not offered yet">
            <:description>
              This optional offer appears once your pilot specification reaches
              <span class="font-semibold text-ink">Ready for review</span>
              or <span class="font-semibold text-ink">Done</span>.
              Managed runtime SDD already works fully without it — nothing here is required.
            </:description>
          </.empty_state>
        </section>

        <section :if={@stage == :declined} class="mt-6" data-kit-declined>
          <.empty_state icon="circle-check" title="Declined for now">
            <:description>
              Managed runtime SDD continues to work fully. Nothing was recorded — come back to
              this offer any time.
            </:description>
          </.empty_state>
        </section>

        <section
          :if={@stage == :offer}
          class="mt-6 rounded-xl border border-line bg-surface p-4 sm:p-5"
          aria-labelledby="kit-offer-heading"
          data-kit-offer
        >
          <div class="flex items-start gap-3">
            <span class="rounded-lg bg-info-bg p-2 text-info-fg">
              <.lucide name="download" class="size-5" />
            </span>
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 id="kit-offer-heading" class="text-base font-bold text-ink">
                  Make this repository SDD-aware
                </h2>
                <.badge variant="info">Optional</.badge>
              </div>
              <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                <span class="font-semibold text-ink" data-kit-publisher>{@package.publisher}</span>
                kit <span class="font-mono text-xs" data-kit-version>v{@package.version}</span>.
                Declining leaves managed runtime SDD fully available.
              </p>
            </div>
          </div>

          <div :if={@owner?} class="mt-5 flex flex-wrap gap-2.5">
            <.button phx-click="build_plan" data-build-plan>
              <.lucide name="search" class="size-4" /> Review the exact plan
            </.button>
            <.button variant="secondary" phx-click="decline" data-decline-offer>
              <.lucide name="x" class="size-4" /> Not now
            </.button>
          </div>
        </section>

        <section :if={@stage == :plan} class="mt-6 space-y-4" data-kit-plan>
          <div class="rounded-xl border border-line bg-surface p-4 sm:p-5">
            <h2 class="text-base font-bold text-ink">Exact reviewable plan</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Base commit <code class="font-mono text-xs" data-plan-base-commit>{String.slice(
                @plan.base_commit,
                0,
                12
              )}</code>, target branch <code
                class="font-mono text-xs"
                data-plan-target-branch
              >{@plan.target_branch}</code>. {plan_review_copy(@plan)}
            </p>
          </div>

          <.notice :if={@plan.safety_blocked} variant="err" icon="lock">
            <span data-kit-safety-blocked>
              This plan is blocked. It conflicts with a fixed safety, least-privilege,
              secret-protection, or verification requirement, and that cannot be overridden in
              the product.
            </span>
          </.notice>

          <.notice :if={@plan.has_ordinary_conflicts} variant="warn" icon="triangle-alert">
            <span data-kit-ordinary-blocked>
              This plan has conflicts that need manual resolution before it could ever be
              applied.
            </span>
          </.notice>

          <div
            :if={@owner? and not @plan.safety_blocked and not @plan.has_ordinary_conflicts}
            class="rounded-xl border border-line bg-surface p-4 sm:p-5"
            data-kit-apply-action
          >
            <h2 class="text-base font-bold text-ink">Apply this plan</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Applying creates one new isolated branch from the base commit above, writes only
              the confirmed operations, and makes one commit. It never writes to or merges into
              your default branch — your repository's normal review process still applies
              afterward.
            </p>
            <div class="mt-4">
              <.button phx-click="apply_plan" data-apply-plan>
                <.lucide name="folder-git-2" class="size-4" /> Apply this plan
              </.button>
            </div>
          </div>

          <.operation_group
            :if={plan_create_operations(@plan) != []}
            title="New files"
            tone="ok"
            operations={plan_create_operations(@plan)}
            data_group="create"
          />

          <.operation_group
            :if={operations(@plan, :omit) != []}
            title="Left alone"
            tone="neutral"
            note="Protected by your existing repository instructions."
            operations={operations(@plan, :omit)}
            data_group="omit"
          />

          <.operation_group
            :if={operations(@plan, :ordinary) != []}
            title="Needs manual resolution"
            tone="warn"
            note="These exist with different content already. Nothing is applied automatically."
            operations={operations(@plan, :ordinary)}
            data_group="ordinary-conflict"
          />

          <.operation_group
            :if={operations(@plan, :safety) != []}
            title="Blocked — cannot be overridden"
            tone="err"
            note="These paths match a protected safety, secret, or credential pattern."
            operations={operations(@plan, :safety)}
            data_group="safety-conflict"
          />
        </section>

        <section :if={@stage == :installed} class="mt-6 space-y-4" data-kit-installed>
          <.empty_state icon="circle-check" title="Installed">
            <:description>
              Branch
              <code
                class="font-mono text-xs"
                data-installation-branch
              >{@installation.branch}</code>
              has one commit <code class="font-mono text-xs" data-installation-commit>{String.slice(
                @installation.result_commit,
                0,
                12
              )}</code>. Nothing was merged — your repository's normal review process still
              applies.
            </:description>
          </.empty_state>

          <div class="rounded-xl border border-line bg-surface p-4 sm:p-5">
            <h3 class="text-sm font-bold text-ink">Installed files</h3>
            <ul class="mt-2 space-y-1">
              <li
                :for={file <- @installation.installed_files}
                class="break-all font-mono text-xs text-ink-muted"
                data-installation-file
              >
                {file["path"]}
              </li>
            </ul>
          </div>

          <% newer_package = newer_package(@installation) %>
          <div
            :if={@owner? and newer_package}
            class="rounded-xl border border-line bg-surface p-4 sm:p-5"
            data-kit-update-available
          >
            <div class="flex items-start gap-3">
              <span class="rounded-lg bg-info-bg p-2 text-info-fg">
                <.lucide name="refresh-cw" class="size-5" />
              </span>
              <div class="min-w-0">
                <h2 class="text-base font-bold text-ink">A newer version is available</h2>
                <p class="mt-1 text-sm leading-relaxed text-ink-muted">
                  <span class="font-mono text-xs" data-kit-update-version>v{newer_package.version}</span>
                  is available. Nothing changes until you review and apply an update plan.
                </p>
              </div>
            </div>
            <div class="mt-4">
              <.button phx-click="build_update_plan" data-build-update-plan>
                <.lucide name="search" class="size-4" /> Review update
              </.button>
            </div>
          </div>

          <div
            :if={@owner?}
            class="rounded-xl border border-err-fg/40 bg-err-bg p-4 sm:p-5"
            data-kit-remove-available
          >
            <h2 class="text-base font-bold text-err-fg">Remove this kit</h2>
            <p class="mt-1 text-sm leading-relaxed text-err-fg">
              Builds a reviewable removal plan on a new isolated branch. Only kit-owned files
              still proven unchanged since installation are ever removed — anything modified
              stays exactly where it is until you review it.
            </p>
            <div class="mt-4">
              <.button variant="secondary" phx-click="build_removal_plan" data-build-removal-plan>
                <.lucide name="unplug" class="size-4" /> Remove this kit
              </.button>
            </div>
          </div>
        </section>

        <section :if={@stage == :update_plan} class="mt-6 space-y-4" data-kit-update-plan>
          <div class="rounded-xl border border-line bg-surface p-4 sm:p-5">
            <h2 class="text-base font-bold text-ink">Exact reviewable update plan</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Base commit <code class="font-mono text-xs" data-plan-base-commit>{String.slice(
                @plan.base_commit,
                0,
                12
              )}</code>, target branch <code
                class="font-mono text-xs"
                data-plan-target-branch
              >{@plan.target_branch}</code>. {plan_review_copy(@plan)}
            </p>
          </div>

          <.notice :if={@plan.safety_blocked} variant="err" icon="lock">
            <span data-kit-safety-blocked>
              This plan is blocked. It conflicts with a fixed safety, least-privilege,
              secret-protection, or verification requirement, and that cannot be overridden in
              the product.
            </span>
          </.notice>

          <.notice :if={@plan.has_ordinary_conflicts} variant="warn" icon="triangle-alert">
            <span data-kit-ordinary-blocked>
              This plan has conflicts that need manual resolution before it could ever be
              applied.
            </span>
          </.notice>

          <div
            :if={@owner? and not @plan.safety_blocked and not @plan.has_ordinary_conflicts}
            class="rounded-xl border border-line bg-surface p-4 sm:p-5"
            data-kit-apply-action
          >
            <h2 class="text-base font-bold text-ink">Apply this update</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Applying creates one new isolated branch from the base commit above, writes only
              the confirmed operations, and makes one commit. It never writes to or merges into
              your default branch — your repository's normal review process still applies
              afterward.
            </p>
            <div class="mt-4">
              <.button phx-click="apply_plan" data-apply-plan>
                <.lucide name="folder-git-2" class="size-4" /> Apply this update
              </.button>
            </div>
          </div>

          <.operation_group
            :if={operations(@plan, :create) != []}
            title="New files"
            tone="ok"
            operations={operations(@plan, :create)}
            data_group="create"
          />

          <.operation_group
            :if={operations(@plan, :update) != []}
            title="Will be updated"
            tone="ok"
            note="Kit-owned and unchanged since installation; content will be updated to the new version."
            operations={operations(@plan, :update)}
            data_group="update"
          />

          <.operation_group
            :if={operations(@plan, :omit) != []}
            title="Left alone"
            tone="neutral"
            note="Protected by your existing repository instructions."
            operations={operations(@plan, :omit)}
            data_group="omit"
          />

          <.operation_group
            :if={operations(@plan, :ordinary) != []}
            title="Needs manual resolution"
            tone="warn"
            note="These exist with different content already. Nothing is applied automatically."
            operations={operations(@plan, :ordinary)}
            data_group="ordinary-conflict"
          />

          <.operation_group
            :if={operations(@plan, :drifted) != []}
            title="Blocked — file was changed since installation"
            tone="err"
            note="This kit-owned file no longer matches what was recorded at installation. Reconcile it manually, then build a fresh update plan."
            operations={operations(@plan, :drifted)}
            data_group="drifted-conflict"
          />

          <.operation_group
            :if={operations(@plan, :safety) != []}
            title="Blocked — cannot be overridden"
            tone="err"
            note="These paths match a protected safety, secret, or credential pattern."
            operations={operations(@plan, :safety)}
            data_group="safety-conflict"
          />
        </section>

        <section :if={@stage == :removal_plan} class="mt-6 space-y-4" data-kit-removal-plan>
          <div class="rounded-xl border border-line bg-surface p-4 sm:p-5">
            <h2 class="text-base font-bold text-ink">Exact reviewable removal plan</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Base commit <code class="font-mono text-xs" data-plan-base-commit>{String.slice(
                @plan.base_commit,
                0,
                12
              )}</code>, target branch <code
                class="font-mono text-xs"
                data-plan-target-branch
              >{@plan.target_branch}</code>. {plan_review_copy(@plan)}
            </p>
          </div>

          <.notice :if={@plan.safety_blocked} variant="err" icon="lock">
            <span data-kit-safety-blocked>
              This plan is blocked. It conflicts with a fixed safety, least-privilege,
              secret-protection, or verification requirement, and that cannot be overridden in
              the product.
            </span>
          </.notice>

          <.notice :if={@plan.has_ordinary_conflicts} variant="warn" icon="triangle-alert">
            <span data-kit-ordinary-blocked>
              This plan has conflicts that need manual resolution before it could ever be
              applied.
            </span>
          </.notice>

          <div
            :if={@owner? and not @plan.safety_blocked and not @plan.has_ordinary_conflicts}
            class="rounded-xl border border-line bg-surface p-4 sm:p-5"
            data-kit-apply-action
          >
            <h2 class="text-base font-bold text-ink">Apply this removal</h2>
            <p class="mt-1 text-sm leading-relaxed text-ink-muted">
              Applying creates one new isolated branch from the base commit above, removes only
              the confirmed files, and makes one commit. It never writes to or merges into your
              default branch — your repository's normal review process still applies afterward.
            </p>
            <div class="mt-4">
              <.button phx-click="apply_plan" data-apply-plan>
                <.lucide name="folder-git-2" class="size-4" /> Apply this removal
              </.button>
            </div>
          </div>

          <.operation_group
            :if={operations(@plan, :delete) != []}
            title="Will be removed"
            tone="err"
            note="Kit-owned and unchanged since installation; safe to remove."
            operations={operations(@plan, :delete)}
            data_group="delete"
          />

          <.operation_group
            :if={operations(@plan, :omit) != []}
            title="Left alone"
            tone="neutral"
            note="Already absent from the repository; nothing to remove."
            operations={operations(@plan, :omit)}
            data_group="omit"
          />

          <.operation_group
            :if={operations(@plan, :drifted) != []}
            title="Blocked — file was changed since installation"
            tone="err"
            note="This kit-owned file no longer matches what was recorded at installation. Reconcile it manually, then build a fresh update plan."
            operations={operations(@plan, :drifted)}
            data_group="drifted-conflict"
          />
        </section>

        <section :if={@stage == :removed} class="mt-6 space-y-4" data-kit-removed>
          <.empty_state icon="circle-check" title="Removed">
            <:description>
              Branch
              <code
                class="font-mono text-xs"
                data-installation-branch
              >{@installation.branch}</code>
              has one commit <code class="font-mono text-xs" data-installation-commit>{String.slice(
                @installation.result_commit,
                0,
                12
              )}</code>. Nothing was merged — your repository's normal review process still
              applies. Managed runtime SDD continues to work fully.
            </:description>
          </.empty_state>
        </section>

        <.notice :if={not @owner?} variant="info" icon="info" class="mt-6">
          <span data-read-only>
            You are viewing this repository kit read-only. Only the project owner can build a
            plan or decline the offer.
          </span>
        </.notice>
      </div>
    </.app_shell>
    """
  end

  attr :title, :string, required: true
  attr :tone, :string, required: true
  attr :note, :string, default: nil
  attr :operations, :list, required: true
  attr :data_group, :string, required: true

  defp operation_group(assigns) do
    ~H"""
    <div
      class="rounded-xl border border-line bg-surface p-4 sm:p-5"
      data-operation-group={@data_group}
    >
      <div class="flex items-center gap-2">
        <h3 class="text-sm font-bold text-ink">{@title}</h3>
        <.badge variant={@tone}>{length(@operations)}</.badge>
      </div>
      <p :if={@note} class="mt-1 text-xs text-ink-muted">{@note}</p>

      <ul class="mt-4 space-y-3">
        <li
          :for={operation <- @operations}
          class="rounded-lg border border-line bg-raised p-3"
          data-operation-path={operation["path"]}
        >
          <span class="break-all font-mono text-xs font-semibold text-ink">
            {operation["path"]}
          </span>
          <p class="mt-1 text-xs text-ink-muted">{operation["reason"]}</p>
          <details :if={show_content?(operation)} class="mt-2">
            <summary class="cursor-pointer text-xs font-semibold text-primary">
              Proposed content
            </summary>
            <pre
              class="mt-2 max-h-64 overflow-auto rounded-md bg-surface p-2 text-xs"
              data-operation-content
            ><code>{proposed_content(operation)}</code></pre>
          </details>
        </li>
      </ul>
    </div>
    """
  end
end
