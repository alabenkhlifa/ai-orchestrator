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
  alias SddOrchestrator.Portability.{BackupSnapshot, PackageEncryption}
  alias SddOrchestrator.Projects

  @download_mime "application/octet-stream"

  @impl true
  def mount(%{"id" => project_id}, _session, socket) do
    case load_project(socket, project_id) do
      {:ok, authority, project, back_path} ->
        {:ok,
         socket
         |> assign(:page_title, "Back up #{project.name}")
         |> assign(:authority, authority)
         |> assign(:project, project)
         |> assign(:back_path, back_path)
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
    with {:ok, package} <-
           BackupSnapshot.build(socket.assigns.authority, socket.assigns.project.id),
         {:ok, encrypted} <- PackageEncryption.encrypt(package, passphrase) do
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
    else
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

      <div data-screen="project-backup">
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
          :if={map_size(@errors) > 0 || @generation_error}
          id="backup-form-error"
          role="alert"
          tabindex="-1"
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

        <form id="project-backup-form" phx-submit="create_backup" class="mt-6">
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
