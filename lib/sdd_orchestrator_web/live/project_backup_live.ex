defmodule SddOrchestratorWeb.ProjectBackupLive do
  @moduledoc """
  Authorized backup creation for hosted and device-authoritative projects.

  The recovery passphrase is accepted only in the submit event and is never put
  in socket assigns, logs, persistence, or the download envelope. Successful
  encrypted bytes are pushed once to the browser and then leave server state.
  """

  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Portability.{BackupSnapshot, PackageEncryption, SecurityLog}
  alias SddOrchestrator.Projects

  @download_mime "application/octet-stream"

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_project(socket, project_id) do
      {:ok, authority, project, back_path} ->
        backup_readiness = backup_readiness(project)

        {:ok,
         socket
         |> assign(:page_title, "Back up #{project.name}")
         |> assign(:authority, authority)
         |> assign(:project, project)
         |> assign(:back_path, back_path)
         |> assign(:backup_readiness, backup_readiness)
         |> assign(:upgrade_path, upgrade_path(socket.assigns.live_action, project))
         |> assign(:errors, %{})
         |> assign(:generation_error, nil)
         |> assign(:download_ready?, false)}

      {:error, redirect_path} ->
        {:ok, push_navigate(socket, to: redirect_path)}
    end
  end

  @impl true
  def handle_event("create_backup", %{"backup" => params}, socket) do
    passphrase = Map.get(params, "passphrase", "")
    confirmation = Map.get(params, "passphrase_confirmation", "")
    acknowledged? = Map.get(params, "loss_acknowledged") in ["true", "on"]

    case validate(passphrase, confirmation, acknowledged?) do
      :ok -> create_backup(socket, passphrase)
      {:error, errors} -> {:noreply, validation_error(socket, errors)}
    end
  end

  def handle_event("create_backup", _params, socket) do
    {:noreply,
     validation_error(socket, %{
       passphrase: "Enter a recovery passphrase.",
       acknowledgement: "Confirm that a lost passphrase cannot be recovered."
     })}
  end

  defp create_backup(socket, passphrase) do
    result =
      case BackupSnapshot.build(socket.assigns.authority, socket.assigns.project.id) do
        {:ok, package} -> PackageEncryption.encrypt(package, passphrase)
        {:error, _reason} = error -> error
      end
      |> SecurityLog.audit(:backup_generation)

    case result do
      {:ok, encrypted} ->
        download = %{
          contents: Base.encode64(encrypted),
          filename: "sdd-project-#{socket.assigns.project.id}.sddbackup",
          mime_type: @download_mime
        }

        {:noreply,
         socket
         |> assign(:errors, %{})
         |> assign(:generation_error, nil)
         |> assign(:download_ready?, true)
         |> push_event("backup-download", download)}

      {:error, :repository_identity_upgrade_required} ->
        {:noreply,
         socket
         |> assign(:errors, %{})
         |> assign(:generation_error, nil)
         |> assign(:backup_readiness, :upgrade_required)
         |> assign(:download_ready?, false)
         |> push_event("backup-form-error", %{})}

      {:error, :invalid_repository_identity} ->
        {:noreply,
         socket
         |> assign(:errors, %{})
         |> assign(:generation_error, nil)
         |> assign(:backup_readiness, :invalid)
         |> assign(:download_ready?, false)
         |> push_event("backup-form-error", %{})}

      _reason ->
        {:noreply,
         socket
         |> assign(:errors, %{})
         |> assign(
           :generation_error,
           "We couldn't create this backup. Check that the project is still available and that its current specifications don't contain credentials, then try again."
         )
         |> assign(:download_ready?, false)
         |> push_event("backup-form-error", %{})}
    end
  end

  defp validate(passphrase, confirmation, acknowledged?) do
    errors =
      %{}
      |> maybe_error(
        :passphrase,
        passphrase == "",
        "Enter a recovery passphrase."
      )
      |> maybe_error(
        :confirmation,
        confirmation == "",
        "Confirm the recovery passphrase."
      )
      |> maybe_error(
        :confirmation,
        passphrase != "" and confirmation != "" and
          not Plug.Crypto.secure_compare(passphrase, confirmation),
        "The recovery passphrases don't match."
      )
      |> maybe_error(
        :acknowledgement,
        not acknowledged?,
        "Confirm that a lost passphrase cannot be recovered."
      )

    if map_size(errors) == 0, do: :ok, else: {:error, errors}
  end

  defp maybe_error(errors, key, true, message), do: Map.put(errors, key, message)
  defp maybe_error(errors, _key, false, _message), do: errors

  defp validation_error(socket, errors) do
    socket
    |> assign(:errors, errors)
    |> assign(:generation_error, nil)
    |> assign(:download_ready?, false)
    |> push_event("backup-form-error", %{})
  end

  defp load_project(%{assigns: %{live_action: :hosted, current_account: account}}, project_id) do
    workspace = Accounts.get_or_create_personal_workspace(account)

    case Projects.get_project(workspace, project_id) do
      nil -> {:error, ~p"/projects"}
      project -> {:ok, workspace, project, ~p"/projects/#{project.id}"}
    end
  end

  defp load_project(%{assigns: %{live_action: :device}}, project_id) do
    with {:ok, workspace} <- Devices.establish_workspace(),
         {:ok, %{storage_mode: "device"} = project} <- Devices.get_project(project_id) do
      {:ok, workspace, project, ~p"/local/projects/#{project.id}"}
    else
      _reason -> {:error, ~p"/onboarding/local"}
    end
  end

  defp backup_readiness(project) do
    if Map.get(project, :repository_provider) == "local" do
      project
      |> local_repository_identity()
      |> PortableRepositoryIdentity.parse()
      |> case do
        {:ok, _portable} -> :ready
        {:error, :legacy_identifier} -> :upgrade_required
        {:error, :invalid_identifier} -> :invalid
      end
    else
      :ready
    end
  end

  defp local_repository_identity(project) do
    Map.get(project, :canonical_repository_id) ||
      Map.get(project, :repository_id) ||
      Map.get(project, :repository_fingerprint)
  end

  defp upgrade_path(:device, project), do: ~p"/onboarding/local?#{[locate: project.id]}"
  defp upgrade_path(_live_action, _project), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" navigate={@back_path} data-cancel-backup>
          <.lucide name="arrow-left" class="size-4" /> Cancel
        </.button>
      </:actions>

      <div data-screen="project-backup" data-backup-readiness={@backup_readiness}>
        <h1 class="text-xl font-bold text-ink">Back up {@project.name}</h1>
        <p class="mt-1.5 text-sm leading-relaxed text-ink-muted text-pretty">
          Create one encrypted backup of this project. You will need its recovery passphrase every
          time you restore it.
        </p>

        <section class="mt-6" aria-labelledby="backup-includes">
          <h2 id="backup-includes" class="text-sm font-bold text-ink">Included in this backup</h2>
          <ul class="mt-3 grid gap-2 sm:grid-cols-3" data-included-categories>
            <.scope_item icon="folder">
              Project identity and display name
            </.scope_item>
            <.scope_item icon="folder-git-2">
              Canonical repository identity
            </.scope_item>
            <.scope_item icon="info">
              Current specifications
            </.scope_item>
          </ul>
          <p class="mt-2 text-xs leading-relaxed text-ink-muted">
            Current specifications include each specification's requirements.md, design.md, and
            tasks.md content.
          </p>
        </section>

        <section
          class="mt-5 rounded-lg border border-line bg-surface p-4"
          aria-labelledby="backup-excludes"
          data-excluded-categories
        >
          <h2 id="backup-excludes" class="text-sm font-bold text-ink">Not included</h2>
          <p class="mt-2 text-[13px] leading-relaxed text-ink-muted">
            History, agent runs, generated artifacts, comments, attachments, audit or security
            logs, analytics, credentials, and repository source are excluded.
          </p>
        </section>

        <div
          :if={@backup_readiness == :upgrade_required}
          class="mt-5"
          role="alert"
          data-repository-identity-upgrade-required
        >
          <.notice variant="warn" icon="triangle-alert">
            <p class="font-semibold">Upgrade the local repository identity before backup.</p>
            <p class="mt-1">
              This project still uses an identity tied to its original device workspace. Locate
              the source repository and complete exact worker validation before creating a
              replacement-environment backup.
            </p>
            <.button
              :if={@upgrade_path}
              variant="secondary"
              size="sm"
              navigate={@upgrade_path}
              data-upgrade-repository-identity
              class="mt-3 w-full sm:w-auto"
            >
              <.lucide name="search" class="size-4" /> Locate the source repository
            </.button>
          </.notice>
        </div>

        <div
          :if={@backup_readiness == :invalid}
          class="mt-5"
          role="alert"
          data-repository-identity-invalid
        >
          <.notice variant="err" icon="triangle-alert">
            <p class="font-semibold">This local repository identity cannot be backed up.</p>
            <p class="mt-1">
              Return to the project and reconnect its repository through the normal worker flow.
              No backup package was created.
            </p>
          </.notice>
        </div>

        <div
          :if={map_size(@errors) > 0 || @generation_error}
          id="backup-form-error"
          role="alert"
          tabindex="-1"
          phx-hook="FocusOnMount"
          class="mt-5"
          data-backup-error
        >
          <.notice variant="err" icon="triangle-alert">
            <p class="font-semibold">The backup wasn't created.</p>
            <ul :if={map_size(@errors) > 0} class="mt-1 list-disc pl-5">
              <li :for={{_field, message} <- @errors}>{message}</li>
            </ul>
            <p :if={@generation_error} class="mt-1">{@generation_error}</p>
          </.notice>
        </div>

        <.notice :if={@download_ready?} variant="info" icon="circle-check" class="mt-5">
          Your encrypted backup was downloaded. Keep the package and its recovery passphrase in
          separate safe places.
        </.notice>

        <form
          :if={@backup_readiness == :ready}
          id="project-backup-form"
          phx-submit="create_backup"
          class="mt-6"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <.text_field
              id="backup-passphrase"
              name="backup[passphrase]"
              type="password"
              label="Recovery passphrase"
              value=""
              error={@errors[:passphrase]}
              hint="Use a long passphrase that you can store safely."
              autocomplete="new-password"
              required
            />
            <.text_field
              id="backup-passphrase-confirmation"
              name="backup[passphrase_confirmation]"
              type="password"
              label="Confirm recovery passphrase"
              value=""
              error={@errors[:confirmation]}
              autocomplete="new-password"
              required
            />
          </div>

          <label
            class={[
              "mt-5 flex items-start gap-2.5 rounded-lg border bg-surface p-4 text-[13px] text-ink",
              @errors[:acknowledgement] && "border-err-fg",
              !@errors[:acknowledgement] && "border-line"
            ]}
            data-loss-acknowledgement
          >
            <input
              type="checkbox"
              name="backup[loss_acknowledged]"
              value="true"
              required
              aria-describedby="loss-acknowledgement-detail"
              class="mt-0.5 size-4 flex-none rounded border-line-strong"
            />
            <span id="loss-acknowledgement-detail">
              I understand that SDD Orchestrator cannot retrieve, reset, bypass, or recover this
              passphrase. Losing it makes this backup permanently unrestorable.
            </span>
          </label>
          <p :if={@errors[:acknowledgement]} class="mt-2 text-xs text-err-fg">
            {@errors[:acknowledgement]}
          </p>

          <div class="mt-6 flex flex-col-reverse gap-2.5 sm:flex-row sm:justify-end">
            <.button
              type="button"
              variant="secondary"
              navigate={@back_path}
              data-cancel-backup
              class="w-full sm:w-auto"
            >
              Cancel
            </.button>
            <.button type="submit" data-create-backup class="w-full sm:w-auto">
              <.lucide name="download" class="size-4" /> Create and download backup
            </.button>
          </div>
        </form>
      </div>
    </.app_shell>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp scope_item(assigns) do
    ~H"""
    <li class="flex items-start gap-2 rounded-lg border border-line bg-surface p-3 text-[13px] font-semibold text-ink">
      <.lucide name={@icon} class="mt-0.5 size-4 flex-none text-primary" />
      <span>{render_slot(@inner_block)}</span>
    </li>
    """
  end
end
