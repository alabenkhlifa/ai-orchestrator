defmodule SddOrchestratorWeb.ProjectRestoreLive do
  @moduledoc """
  Encrypted package upload, destination authorization, and validation surface.

  Passphrases are handed directly from submit params into an asynchronous
  validation task and never assigned to the socket. The decrypted package is
  discarded in `handle_async/3`; only a content-free compatibility result and
  the encrypted attempt id remain for later conflict work.
  """

  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.RestoreIntake

  @impl true
  def mount(_params, _session, socket) do
    device_authority = device_authority()
    hosted_authority = hosted_authority(socket)

    {:ok,
     socket
     |> assign(:page_title, "Restore project backup")
     |> assign(:hosted_authority, hosted_authority)
     |> assign(:device_authority, device_authority)
     |> assign(:selected_destination, nil)
     |> assign(:attempt_id, nil)
     |> assign(:validating?, false)
     |> assign(:validation_result, nil)
     |> assign(:error, nil)
     |> assign(:return_path, return_path(socket))
     |> allow_upload(:package,
       accept: [".sddbackup"],
       max_entries: 1,
       max_file_size: limit(:max_encrypted_package_bytes),
       auto_upload: true
     )}
  end

  @impl true
  def handle_event("select_destination", %{"destination" => destination}, socket) do
    if destination_available?(socket, destination) do
      {:noreply,
       socket
       |> assign(:selected_destination, destination)
       |> assign(:error, nil)
       |> assign(:validation_result, nil)}
    else
      {:noreply, assign(socket, :error, authorization_message(destination))}
    end
  end

  def handle_event("upload_changed", _params, socket) do
    {:noreply, assign(socket, :error, upload_error(socket))}
  end

  def handle_event("validate_package", %{"restore" => params}, socket) do
    passphrase = Map.get(params, "passphrase", "")

    with :ok <- validate_submission(socket, passphrase),
         {:ok, encrypted_package} <- consume_package(socket),
         {:ok, authority} <- selected_authority(socket),
         {:ok, attempt} <-
           RestoreIntake.start(
             authority,
             socket.assigns.selected_destination,
             encrypted_package
           ) do
      {:noreply,
       socket
       |> assign(:attempt_id, attempt.id)
       |> assign(:validating?, true)
       |> assign(:validation_result, nil)
       |> assign(:error, nil)
       |> start_async(:validate_package, fn ->
         RestoreIntake.begin_validation(authority, attempt.id, passphrase)
       end)}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, form_error(socket, message)}

      _reason ->
        {:noreply,
         form_error(
           socket,
           "The selected destination couldn't be authorized. Choose an available destination and try again."
         )}
    end
  end

  def handle_event("validate_package", _params, socket) do
    {:noreply, form_error(socket, "Enter the recovery passphrase and choose a package.")}
  end

  def handle_event("cancel", _params, socket) do
    socket = cancel_async(socket, :validate_package)

    with {:ok, authority} <- selected_authority(socket),
         attempt_id when is_binary(attempt_id) <- socket.assigns.attempt_id do
      _ = RestoreIntake.cancel(authority, attempt_id)
    end

    {:noreply, push_navigate(socket, to: socket.assigns.return_path)}
  end

  @impl true
  def handle_async(:validate_package, {:ok, {:ok, _attempt, _package}}, socket) do
    {:noreply,
     socket
     |> assign(:validating?, false)
     |> assign(:validation_result, :compatible)
     |> assign(:error, nil)}
  end

  def handle_async(:validate_package, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:validating?, false)
     |> assign(:attempt_id, nil)
     |> assign(:validation_result, nil)
     |> assign(:error, validation_message(reason))
     |> push_event("restore-form-error", %{})}
  end

  def handle_async(:validate_package, {:exit, _reason}, socket) do
    cleanup_attempt(socket)

    {:noreply,
     socket
     |> assign(:validating?, false)
     |> assign(:attempt_id, nil)
     |> assign(:validation_result, nil)
     |> assign(:error, "Validation stopped unexpectedly. Choose the package and try again.")
     |> push_event("restore-form-error", %{})}
  end

  defp validate_submission(socket, passphrase) do
    cond do
      socket.assigns.selected_destination == nil ->
        {:error, "Choose where the restored project should be saved."}

      not destination_available?(socket, socket.assigns.selected_destination) ->
        {:error, authorization_message(socket.assigns.selected_destination)}

      passphrase == "" ->
        {:error, "Enter the recovery passphrase."}

      upload_error(socket) != nil ->
        {:error, upload_error(socket)}

      socket.assigns.uploads.package.entries == [] ->
        {:error, "Choose a .sddbackup package."}

      true ->
        :ok
    end
  end

  defp consume_package(socket) do
    case consume_uploaded_entries(socket, :package, &read_uploaded_package/2) do
      [encrypted_package] when is_binary(encrypted_package) -> {:ok, encrypted_package}
      _other -> {:error, "The package couldn't be read. Choose it again and retry."}
    end
  end

  # The upload path is generated by LiveView's configured upload writer and is
  # never accepted from a request parameter. This is not a traversal boundary.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_uploaded_package(%{path: path}, _entry) do
    case File.read(path) do
      {:ok, encrypted_package} -> {:ok, encrypted_package}
      {:error, _reason} -> {:postpone, nil}
    end
  end

  defp form_error(socket, message) do
    socket
    |> assign(:error, message)
    |> assign(:validation_result, nil)
    |> push_event("restore-form-error", %{})
  end

  defp upload_error(socket) do
    socket.assigns.uploads.package.entries
    |> Enum.flat_map(&upload_errors(socket.assigns.uploads.package, &1))
    |> List.first()
    |> case do
      :too_large -> "The package is larger than the allowed 32 MiB."
      :not_accepted -> "Choose a file ending in .sddbackup."
      :too_many_files -> "Choose one backup package."
      nil -> nil
      _other -> "The package couldn't be uploaded. Choose it again and retry."
    end
  end

  defp selected_authority(%{assigns: %{selected_destination: "hosted"}} = socket) do
    case socket.assigns.hosted_authority do
      nil -> {:error, :unauthorized}
      authority -> {:ok, authority}
    end
  end

  defp selected_authority(%{assigns: %{selected_destination: "device"}} = socket) do
    case socket.assigns.device_authority do
      nil -> {:error, :unauthorized}
      authority -> {:ok, authority}
    end
  end

  defp selected_authority(_socket), do: {:error, :unauthorized}

  defp destination_available?(socket, "hosted"),
    do: socket.assigns.hosted_authority != nil

  defp destination_available?(socket, "device"),
    do: socket.assigns.device_authority != nil

  defp destination_available?(_socket, _destination), do: false

  defp hosted_authority(%{assigns: %{current_hosted_workspace: workspace}})
       when not is_nil(workspace),
       do: workspace

  defp hosted_authority(%{assigns: %{current_account: account}}) when not is_nil(account),
    do: Accounts.get_or_create_personal_workspace(account)

  defp hosted_authority(_socket), do: nil

  defp device_authority do
    with {:ok, workspace} <- Devices.establish_workspace(),
         :detected <- Devices.worker_status(workspace.id) do
      workspace
    else
      _reason -> nil
    end
  end

  defp return_path(%{assigns: %{current_account: account}}) when not is_nil(account),
    do: ~p"/projects"

  defp return_path(_socket), do: ~p"/onboarding/local"

  defp cleanup_attempt(socket) do
    with {:ok, authority} <- selected_authority(socket),
         attempt_id when is_binary(attempt_id) <- socket.assigns.attempt_id do
      RestoreIntake.fail(authority, attempt_id)
    else
      _reason -> :ok
    end
  end

  defp authorization_message("hosted"),
    do: "Verify a hosted identity before selecting hosted storage."

  defp authorization_message("device"),
    do: "Connect the worker on this device before selecting on-device storage."

  defp authorization_message(_destination), do: "Choose an available destination."

  defp validation_message(:package_too_large),
    do: "This package is too large to validate safely."

  defp validation_message(:unsupported_version),
    do: "This backup version isn't supported by this SDD Orchestrator release."

  defp validation_message(reason) when reason in [:malformed_package, :unsafe_package],
    do: "This package isn't safe or compatible. Create a new backup and try again."

  defp validation_message(_invalid_or_passphrase),
    do: "The package or recovery passphrase couldn't be verified. Check both and try again."

  defp limit(name) do
    :sdd_orchestrator
    |> Application.fetch_env!(:portability_limits)
    |> Keyword.fetch!(name)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <:actions>
        <.button variant="secondary" size="sm" phx-click="cancel" data-cancel-restore>
          <.lucide name="arrow-left" class="size-4" /> Cancel
        </.button>
      </:actions>

      <div data-screen="project-restore">
        <h1 class="text-xl font-bold text-ink">Restore a project backup</h1>
        <p class="mt-1.5 text-sm leading-relaxed text-ink-muted text-pretty">
          Choose an encrypted .sddbackup package, enter its recovery passphrase, and authorize where
          the restored project should be saved. Validation doesn't create or change a project.
        </p>

        <section class="mt-6" aria-labelledby="restore-destination-heading">
          <h2 id="restore-destination-heading" class="text-sm font-bold text-ink">
            Where should the restored project be saved?
          </h2>
          <div
            class="mt-3 grid gap-3 sm:grid-cols-2"
            role="radiogroup"
            aria-label="Restore destination"
          >
            <div>
              <.destination_option
                id="restore-hosted"
                selected={@selected_destination == "hosted"}
                disabled={@hosted_authority == nil}
                label="In my SDD Orchestrator account"
                destination="hosted"
              >
                <p class="text-[13px] font-semibold text-ink">Hosted storage</p>
                <p class="mt-0.5 text-xs text-ink-muted">
                  Requires a verified hosted identity.
                </p>
              </.destination_option>
              <.button
                :if={@hosted_authority == nil}
                variant="secondary"
                size="sm"
                navigate={~p"/hosted/access?#{[return_to: "/restore"]}"}
                class="mt-2 w-full"
                data-setup-hosted
              >
                Verify hosted identity
              </.button>
            </div>

            <div>
              <.destination_option
                id="restore-device"
                selected={@selected_destination == "device"}
                disabled={@device_authority == nil}
                label="On this device"
                destination="device"
              >
                <p class="text-[13px] font-semibold text-ink">On-device storage</p>
                <p class="mt-0.5 text-xs text-ink-muted">Requires a connected local worker.</p>
              </.destination_option>
              <.button
                :if={@device_authority == nil}
                variant="secondary"
                size="sm"
                navigate={~p"/onboarding/local"}
                class="mt-2 w-full"
                data-setup-device
              >
                Set up this device
              </.button>
            </div>
          </div>
        </section>

        <div
          :if={@error}
          id="restore-form-error"
          role="alert"
          tabindex="-1"
          class="mt-5"
          data-restore-error
        >
          <.notice variant="err" icon="triangle-alert">{@error}</.notice>
        </div>

        <.notice :if={@validating?} variant="info" icon="loader" class="mt-5">
          <span data-validation-progress>Validating package compatibility and safety…</span>
        </.notice>

        <.notice
          :if={@validation_result == :compatible}
          variant="info"
          icon="circle-check"
          class="mt-5"
        >
          <span data-validation-compatible>
            This package is compatible and passed the current safety checks. No project has been
            created yet.
          </span>
        </.notice>

        <form
          id="project-restore-form"
          phx-change="upload_changed"
          phx-submit="validate_package"
          class="mt-6"
        >
          <div>
            <label for={@uploads.package.ref} class="block text-[13px] font-semibold text-ink">
              Encrypted backup package
            </label>
            <.live_file_input
              upload={@uploads.package}
              class="mt-1.5 block w-full rounded-lg border border-line-strong bg-surface p-3 text-sm text-ink file:mr-3 file:rounded-md file:border-0 file:bg-raised file:px-3 file:py-2 file:text-[13px] file:font-semibold file:text-ink focus-visible:outline focus-visible:outline-2 focus-visible:outline-focus"
              data-package-input
            />
            <p class="mt-2 text-xs text-ink-muted">One .sddbackup file, up to 32 MiB.</p>
          </div>

          <div class="mt-5">
            <.text_field
              id="restore-passphrase"
              name="restore[passphrase]"
              type="password"
              label="Recovery passphrase"
              value=""
              hint="The passphrase is used only for this validation operation."
              autocomplete="current-password"
              required
            />
          </div>

          <div class="mt-6 flex flex-col-reverse gap-2.5 sm:flex-row sm:justify-end">
            <.button
              type="button"
              variant="secondary"
              phx-click="cancel"
              data-cancel-restore
              class="w-full sm:w-auto"
            >
              Cancel
            </.button>
            <.button
              type="submit"
              disabled={@validating?}
              data-validate-package
              class="w-full sm:w-auto"
            >
              <.lucide name="shield" class="size-4" /> Validate package
            </.button>
          </div>
        </form>
      </div>
    </.app_shell>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :destination, :string, required: true
  attr :selected, :boolean, default: false
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  defp destination_option(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="radio"
      aria-checked={to_string(@selected)}
      aria-label={@label}
      disabled={@disabled}
      phx-click="select_destination"
      phx-keydown="select_destination"
      phx-key="Enter"
      phx-value-destination={@destination}
      data-restore-destination={@destination}
      class={[
        "flex w-full items-center gap-3 rounded-lg border bg-surface p-3 text-left transition",
        "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus",
        @selected && "border-primary ring-1 ring-primary",
        !@selected && "border-line hover:border-line-strong",
        @disabled && "cursor-not-allowed opacity-60"
      ]}
    >
      <span class={[
        "flex size-[18px] flex-none items-center justify-center rounded-full border-2",
        @selected && "border-primary",
        !@selected && "border-line-strong"
      ]}>
        <span :if={@selected} class="size-2.5 rounded-full bg-primary"></span>
      </span>
      <span class="min-w-0 flex-1">{render_slot(@inner_block)}</span>
      <.lucide :if={@selected} name="check" class="size-5 flex-none text-primary" />
    </button>
    """
  end
end
