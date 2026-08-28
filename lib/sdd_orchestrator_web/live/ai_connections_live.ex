defmodule SddOrchestratorWeb.AIConnectionsLive do
  @moduledoc """
  Account-level management for credential-local personal AI connections.

  Worker discovery is derived from the current device authority and the live
  personal-worker RPC registry. Browser events carry only short-lived display
  keys; every selected worker is looked up again and re-authorized before the
  connection domain is called. Provider credentials and raw provider identity
  have no field or rendering path in this LiveView.
  """

  use SddOrchestratorWeb, :live_view

  alias Phoenix.LiveView.JS

  alias SddOrchestrator.AIRuntime.{
    ModelCatalogs,
    PersonalConnections,
    PersonalWorkerRPC,
    Quotas
  }

  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.Pairing

  @protocol_version "personal-ai/1"
  @connection_capability "connection/1"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "AI Connections")
     |> assign(:editing_connection_id, nil)
     |> assign(:confirming_revoke_id, nil)
     |> assign(:link_pending?, false)
     |> assign(:link_result, nil)
     |> assign(:rename_result, nil)
     |> assign(:revocation_results, %{})
     |> assign(:revoking_ids, MapSet.new())
     |> assign(:catalogs, %{})
     |> assign(:catalog_results, %{})
     |> assign(:catalog_refreshing_ids, MapSet.new())
     |> assign(:quotas, %{})
     |> assign(:quota_results, %{})
     |> assign(:quota_refreshing_ids, MapSet.new())
     |> refresh_workers()
     |> reset_create_form()
     |> refresh_connections()}
  end

  @impl true
  def handle_event("refresh_catalog", %{"id" => id}, socket) do
    account = socket.assigns.current_account

    cond do
      MapSet.member?(socket.assigns.catalog_refreshing_ids, id) ->
        {:noreply, socket}

      is_nil(PersonalConnections.get_connection(account, id)) ->
        {:noreply, put_catalog_result(socket, id, {:error, :not_found})}

      true ->
        {:noreply,
         socket
         |> update(:catalog_refreshing_ids, &MapSet.put(&1, id))
         |> update(:catalogs, &Map.put(&1, id, {:error, :unknown}))
         |> put_catalog_result(id, :pending)
         |> start_async({:refresh_catalog, id}, fn ->
           ModelCatalogs.refresh(account, id)
         end)}
    end
  end

  def handle_event("refresh_catalog", _params, socket) do
    {:noreply, put_catalog_result(socket, "invalid", {:error, :not_found})}
  end

  def handle_event("refresh_quota", %{"id" => id}, socket) do
    account = socket.assigns.current_account

    cond do
      MapSet.member?(socket.assigns.quota_refreshing_ids, id) ->
        {:noreply, socket}

      is_nil(PersonalConnections.get_connection(account, id)) ->
        {:noreply, put_quota_result(socket, id, {:error, :not_found})}

      true ->
        {:noreply,
         socket
         |> update(:quota_refreshing_ids, &MapSet.put(&1, id))
         |> update(:quotas, &Map.put(&1, id, {:error, :unknown}))
         |> put_quota_result(id, :pending)
         |> start_async({:refresh_quota, id}, fn ->
           Quotas.refresh(account, id)
         end)}
    end
  end

  def handle_event("refresh_quota", _params, socket) do
    {:noreply, put_quota_result(socket, "invalid", {:error, :not_found})}
  end

  @impl true
  def handle_event("link", %{"connection" => params}, socket) do
    socket = refresh_workers(socket)

    with false <- socket.assigns.link_pending?,
         {:ok, candidate} <- selected_candidate(socket, params["worker_id"]),
         :ok <- authorize_candidate(socket, candidate),
         {:ok, attrs} <- link_attrs(params) do
      account = socket.assigns.current_account
      worker = candidate.worker
      authentication_mode = attrs.authentication_mode

      {:noreply,
       socket
       |> assign(:create_values, Map.take(params, ["label", "worker_id", "authentication_mode"]))
       |> assign(:link_pending?, true)
       |> assign(:link_result, {:pending, authentication_mode})
       |> start_async(:link_connection, fn ->
         PersonalConnections.link_connection(account, worker, attrs)
       end)}
    else
      true -> {:noreply, socket}
      {:error, reason} -> {:noreply, assign(socket, :link_result, {:error, reason})}
    end
  end

  def handle_event("link", _params, socket) do
    {:noreply, assign(socket, :link_result, {:error, :invalid_connection})}
  end

  def handle_event("change_connection", %{"connection" => params}, socket) do
    values =
      socket.assigns.create_values
      |> Map.merge(Map.take(params, ["label", "worker_id", "authentication_mode"]))

    {:noreply, assign(socket, :create_values, values)}
  end

  def handle_event("change_connection", _params, socket), do: {:noreply, socket}

  def handle_event("recheck_workers", _params, socket) do
    {:noreply,
     socket
     |> refresh_workers()
     |> preserve_create_values()}
  end

  def handle_event("start_rename", %{"id" => id}, socket) do
    case PersonalConnections.get_connection(socket.assigns.current_account, id) do
      nil ->
        {:noreply, assign(socket, :rename_result, {:error, :not_found})}

      connection ->
        {:noreply,
         socket
         |> assign(:editing_connection_id, connection.id)
         |> assign(:rename_result, nil)}
    end
  end

  def handle_event("cancel_rename", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_connection_id, nil)
     |> assign(:rename_result, nil)}
  end

  def handle_event("rename", %{"rename" => %{"label" => label}}, socket) do
    account = socket.assigns.current_account

    case socket.assigns.editing_connection_id do
      nil ->
        {:noreply, assign(socket, :rename_result, {:error, :not_found})}

      connection_id ->
        case PersonalConnections.rename_connection(account, connection_id, label) do
          {:ok, connection} ->
            {:noreply,
             socket
             |> assign(:editing_connection_id, nil)
             |> assign(:rename_result, {:ok, connection.id})
             |> refresh_connections()}

          {:error, reason} ->
            {:noreply, assign(socket, :rename_result, {:error, reason})}
        end
    end
  end

  def handle_event("rename", _params, socket) do
    {:noreply, assign(socket, :rename_result, {:error, :invalid_label})}
  end

  def handle_event("start_revoke", %{"id" => id}, socket) do
    case PersonalConnections.get_connection(socket.assigns.current_account, id) do
      nil -> {:noreply, put_revocation_result(socket, id, {:error, :not_found})}
      connection -> {:noreply, assign(socket, :confirming_revoke_id, connection.id)}
    end
  end

  def handle_event("cancel_revoke", _params, socket) do
    {:noreply, assign(socket, :confirming_revoke_id, nil)}
  end

  def handle_event("confirm_revoke", _params, socket) do
    case socket.assigns.confirming_revoke_id do
      nil ->
        {:noreply, socket}

      connection_id ->
        account = socket.assigns.current_account

        {:noreply,
         socket
         |> assign(:confirming_revoke_id, nil)
         |> update(:revoking_ids, &MapSet.put(&1, connection_id))
         |> put_revocation_result(connection_id, :pending)
         |> start_async({:revoke_connection, connection_id}, fn ->
           PersonalConnections.request_revocation(account, connection_id)
         end)}
    end
  end

  @impl true
  def handle_async(:link_connection, {:ok, {:ok, connection}}, socket) do
    {:noreply,
     socket
     |> assign(:link_pending?, false)
     |> assign(:link_result, {:ok, connection.authentication_mode})
     |> reset_create_form()
     |> refresh_connections()}
  end

  def handle_async(:link_connection, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:link_pending?, false)
     |> assign(:link_result, {:error, reason})}
  end

  def handle_async(:link_connection, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:link_pending?, false)
     |> assign(:link_result, {:error, :worker_unavailable})}
  end

  def handle_async({:revoke_connection, connection_id}, {:ok, {:ok, _connection}}, socket) do
    {:noreply,
     socket
     |> update(:revoking_ids, &MapSet.delete(&1, connection_id))
     |> put_revocation_result(connection_id, :ok)
     |> refresh_connections()}
  end

  def handle_async({:revoke_connection, connection_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update(:revoking_ids, &MapSet.delete(&1, connection_id))
     |> put_revocation_result(connection_id, {:error, reason})}
  end

  def handle_async({:revoke_connection, connection_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:revoking_ids, &MapSet.delete(&1, connection_id))
     |> put_revocation_result(connection_id, {:error, :worker_unavailable})}
  end

  def handle_async({:refresh_catalog, connection_id}, {:ok, {:ok, catalog}}, socket) do
    {:noreply,
     socket
     |> update(:catalog_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:catalogs, &Map.put(&1, connection_id, {:ok, catalog}))
     |> put_catalog_result(connection_id, :ok)}
  end

  def handle_async({:refresh_catalog, connection_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update(:catalog_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:catalogs, &Map.put(&1, connection_id, {:error, :unknown}))
     |> put_catalog_result(connection_id, {:error, reason})}
  end

  def handle_async({:refresh_catalog, connection_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:catalog_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:catalogs, &Map.put(&1, connection_id, {:error, :unknown}))
     |> put_catalog_result(connection_id, {:error, :worker_unavailable})}
  end

  def handle_async({:refresh_quota, connection_id}, {:ok, {:ok, quota}}, socket) do
    {:noreply,
     socket
     |> update(:quota_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:quotas, &Map.put(&1, connection_id, {:ok, quota}))
     |> put_quota_result(connection_id, :ok)}
  end

  def handle_async({:refresh_quota, connection_id}, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> update(:quota_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:quotas, &Map.put(&1, connection_id, {:error, :unknown}))
     |> put_quota_result(connection_id, {:error, reason})}
  end

  def handle_async({:refresh_quota, connection_id}, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> update(:quota_refreshing_ids, &MapSet.delete(&1, connection_id))
     |> update(:quotas, &Map.put(&1, connection_id, {:error, :unknown}))
     |> put_quota_result(connection_id, {:error, :worker_unavailable})}
  end

  defp refresh_connections(socket) do
    account = socket.assigns.current_account
    connections = PersonalConnections.list_connections(account)

    catalogs =
      Map.new(connections, fn connection ->
        {connection.id, ModelCatalogs.current_catalog(account, connection.id)}
      end)

    quotas =
      Map.new(connections, fn connection ->
        {connection.id, Quotas.current_quota(account, connection.id)}
      end)

    socket
    |> assign(:connections, connections)
    |> assign(:catalogs, catalogs)
    |> assign(:quotas, quotas)
  end

  defp refresh_workers(socket) do
    {workspace_id, candidates} = discover_workers()

    socket
    |> assign(:device_workspace_id, workspace_id)
    |> assign(:worker_candidates, candidates)
    |> assign(:worker_state, combined_worker_state(candidates))
  end

  defp discover_workers do
    case Devices.get_workspace() do
      {:ok, %{id: workspace_id}} ->
        candidates =
          workspace_id
          |> Pairing.active_workers()
          |> Enum.sort_by(& &1.id)
          |> Enum.with_index(1)
          |> Enum.map(fn {worker, index} ->
            %{
              key: "local-worker-#{index}",
              name: "Local worker #{index}",
              state: worker_state(workspace_id, worker.id),
              worker: worker
            }
          end)

        {workspace_id, candidates}

      _ ->
        {nil, []}
    end
  end

  defp worker_state(workspace_id, worker_id) do
    case PersonalWorkerRPC.connection(workspace_id, worker_id) do
      {:ok, _pid, %{protocol_version: @protocol_version, capabilities: capabilities}}
      when is_list(capabilities) ->
        if @connection_capability in capabilities, do: :ready, else: :incompatible

      {:ok, _pid, _contract} ->
        :incompatible

      :error ->
        :unavailable
    end
  end

  defp combined_worker_state([]), do: :missing

  defp combined_worker_state(candidates) do
    states = Enum.map(candidates, & &1.state)

    cond do
      :ready in states -> :ready
      :incompatible in states -> :incompatible
      true -> :unavailable
    end
  end

  defp reset_create_form(socket) do
    default_worker =
      socket.assigns.worker_candidates
      |> Enum.find(&(&1.state == :ready))
      |> case do
        nil -> ""
        candidate -> candidate.key
      end

    assign(socket, :create_values, %{
      "label" => "",
      "worker_id" => default_worker,
      "authentication_mode" => "chatgpt"
    })
  end

  defp preserve_create_values(socket) do
    values = socket.assigns.create_values
    selected = values["worker_id"]

    selected =
      if Enum.any?(socket.assigns.worker_candidates, fn candidate ->
           candidate.key == selected and candidate.state == :ready
         end) do
        selected
      else
        socket.assigns.worker_candidates
        |> Enum.find(&(&1.state == :ready))
        |> case do
          nil -> ""
          candidate -> candidate.key
        end
      end

    assign(socket, :create_values, Map.put(values, "worker_id", selected))
  end

  defp selected_candidate(socket, key) when is_binary(key) do
    case Enum.find(socket.assigns.worker_candidates, &(&1.key == key and &1.state == :ready)) do
      nil -> {:error, worker_selection_error(socket.assigns.worker_state)}
      candidate -> {:ok, candidate}
    end
  end

  defp selected_candidate(socket, _key),
    do: {:error, worker_selection_error(socket.assigns.worker_state)}

  defp authorize_candidate(%{assigns: %{device_workspace_id: workspace_id}}, candidate)
       when is_binary(workspace_id),
       do: Pairing.authorize_for_workspace(candidate.worker, workspace_id)

  defp authorize_candidate(_socket, _candidate), do: {:error, :worker_unavailable}

  defp worker_selection_error(:incompatible), do: :incompatible
  defp worker_selection_error(_state), do: :worker_unavailable

  defp link_attrs(params) do
    attrs = %{
      label: params["label"],
      provider: "openai_codex",
      authentication_mode: params["authentication_mode"]
    }

    if is_binary(attrs.label) and attrs.authentication_mode in ["chatgpt", "api_key"],
      do: {:ok, attrs},
      else: {:error, :invalid_connection}
  end

  defp put_revocation_result(socket, id, result) do
    update(socket, :revocation_results, &Map.put(&1, id, result))
  end

  defp put_catalog_result(socket, id, result) do
    update(socket, :catalog_results, &Map.put(&1, id, result))
  end

  defp put_quota_result(socket, id, result) do
    update(socket, :quota_results, &Map.put(&1, id, result))
  end

  defp link_result_message({:pending, "api_key"}),
    do: "Waiting for the local worker. Enter the API key only in the worker window."

  defp link_result_message({:pending, _mode}),
    do: "Waiting for the local worker to complete ChatGPT sign-in."

  defp link_result_message({:ok, "api_key"}),
    do: "Connection added. API-key entry stayed in the local worker."

  defp link_result_message({:ok, _mode}),
    do: "Connection added. ChatGPT sign-in completed in the local worker."

  defp link_result_message({:error, reason}), do: error_message(reason)

  defp error_message(:label_taken), do: "That label is already in use. Choose another label."
  defp error_message(:invalid_label), do: "Enter a label between 1 and 100 characters."
  defp error_message(:invalid_connection), do: "Check the label and connection choices."
  defp error_message(:worker_unavailable), do: "The selected local worker is unavailable."
  defp error_message(:timeout), do: "The local worker did not respond in time. Try again."
  defp error_message(:incompatible), do: "The selected local worker needs a compatible update."
  defp error_message(:profile_already_linked), do: "That worker-local profile is already linked."
  defp error_message(:binding_mismatch), do: "That connection cannot be rebound. Revoke it first."

  defp error_message(:account_unavailable),
    do: "This account cannot manage connections right now."

  defp error_message(:not_found), do: "That connection is no longer available."
  defp error_message(_reason), do: "The connection could not be changed. Try again."

  defp catalog_error_message(:stale),
    do: "The last catalog expired. Refresh it before selecting a model."

  defp catalog_error_message(:enumeration_unsupported),
    do: "This worker could not prove a current or default model."

  defp catalog_error_message(:incompatible),
    do: "The local worker needs a compatible catalog update."

  defp catalog_error_message(:revoking), do: "This connection is being revoked."
  defp catalog_error_message(:revoked), do: "This connection is revoked."
  defp catalog_error_message(:unavailable), do: "This connection is unavailable."

  defp catalog_error_message(:timeout),
    do: "The local worker did not return the catalog in time."

  defp catalog_error_message(:worker_unavailable),
    do: "The local worker is unavailable. Open it and try again."

  defp catalog_error_message(_reason),
    do: "The authenticated catalog could not be refreshed safely."

  defp catalog_source_label("official_client"), do: "Official client"
  defp catalog_source_label("provider_api"), do: "Provider API"

  defp catalog_time(%DateTime{} = value) do
    Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")
  end

  defp quota_error_message(:stale),
    do: "The last quota snapshot expired. Refresh it before relying on these facts."

  defp quota_error_message(:incompatible),
    do: "The local worker needs a compatible quota update."

  defp quota_error_message(:revoking), do: "This connection is being revoked."
  defp quota_error_message(:revoked), do: "This connection is revoked."
  defp quota_error_message(:unavailable), do: "This connection is unavailable."

  defp quota_error_message(:timeout),
    do: "The local worker did not return quota facts in time."

  defp quota_error_message(:worker_unavailable),
    do: "The local worker is unavailable. Open it and try again."

  defp quota_error_message(_reason),
    do: "Authenticated quota facts could not be refreshed safely."

  defp quota_time(%DateTime{} = value), do: Calendar.strftime(value, "%Y-%m-%d %H:%M UTC")

  defp quota_source_methods([]), do: "No quota or billing method supplied a fact"
  defp quota_source_methods(methods), do: Enum.join(methods, " + ")

  defp quota_value(nil), do: "Unknown"
  defp quota_value(value), do: to_string(value)

  defp quota_scope_label("general"), do: "General"
  defp quota_scope_label("model_specific"), do: "Model-specific"
  defp quota_scope_label("provider_defined"), do: "Provider-defined"

  defp paid_continuation_label("available"), do: "Available"
  defp paid_continuation_label("unavailable"), do: "Unavailable"
  defp paid_continuation_label("unknown"), do: "Paid continuation unknown"

  defp worker_state_label(:ready), do: "Ready"
  defp worker_state_label(:unavailable), do: "Unavailable"
  defp worker_state_label(:incompatible), do: "Needs update"

  defp worker_state_variant(:ready), do: "ok"
  defp worker_state_variant(:unavailable), do: "warn"
  defp worker_state_variant(:incompatible), do: "err"

  defp availability_label(%{revocation_state: "requested"}), do: "Revocation pending"
  defp availability_label(%{revocation_state: "acknowledged"}), do: "Revoked"
  defp availability_label(%{availability: "available"}), do: "Available"
  defp availability_label(%{availability: "unavailable"}), do: "Unavailable"
  defp availability_label(%{availability: "incompatible"}), do: "Needs update"

  defp availability_variant(%{revocation_state: "requested"}), do: "warn"
  defp availability_variant(%{revocation_state: "acknowledged"}), do: "neutral"
  defp availability_variant(%{availability: "available"}), do: "ok"
  defp availability_variant(%{availability: "unavailable"}), do: "warn"
  defp availability_variant(%{availability: "incompatible"}), do: "err"

  defp authentication_label("api_key"), do: "API key"
  defp authentication_label(_chatgpt), do: "ChatGPT"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-6xl">
      <:actions>
        <.button variant="ghost" size="sm" navigate={~p"/projects"} data-projects-link>
          <.lucide name="folder" class="size-4" /> Projects
        </.button>
        <.button variant="secondary" size="sm" href={~p"/auth/sign_out"} method="delete">
          <.lucide name="log-out" class="size-4" /> Sign out
        </.button>
      </:actions>

      <div data-screen="ai-connections" class="space-y-8">
        <header class="max-w-3xl">
          <p class="text-xs font-semibold uppercase tracking-[0.16em] text-primary">
            Account settings
          </p>
          <h1 class="mt-2 text-2xl font-bold text-ink sm:text-3xl">AI Connections</h1>
          <p class="mt-3 text-sm leading-6 text-ink-muted">
            Link labelled personal AI connections through a paired worker on this device.
            Sign-in and secret entry stay in that local worker.
          </p>
        </header>

        <section
          aria-labelledby="worker-heading"
          class="rounded-xl border border-line bg-surface p-4 sm:p-6"
        >
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 id="worker-heading" class="text-base font-bold text-ink">Local worker</h2>
              <p class="mt-1 text-sm text-ink-muted">
                Only compatible live workers can start a connection handoff.
              </p>
            </div>
            <.badge :if={@worker_state == :missing} variant="warn">No paired worker</.badge>
            <.badge :if={@worker_state == :unavailable} variant="warn">Worker unavailable</.badge>
            <.badge :if={@worker_state == :incompatible} variant="err">Update required</.badge>
            <.badge :if={@worker_state == :ready} variant="ok">Ready to connect</.badge>
          </div>

          <p
            :if={@worker_state == :missing}
            data-worker-guidance="missing"
            class="mt-4 text-sm text-ink-muted"
          >
            Pair a local worker on this device before adding an AI connection.
          </p>
          <p
            :if={@worker_state == :unavailable}
            data-worker-guidance="unavailable"
            class="mt-4 text-sm text-ink-muted"
          >
            A worker is paired but its AI connection is offline. Open the worker and try again.
          </p>
          <p
            :if={@worker_state == :incompatible}
            data-worker-guidance="incompatible"
            class="mt-4 text-sm text-ink-muted"
          >
            The live worker does not support the required personal AI connection protocol. Update it before continuing.
          </p>

          <div class="mt-4 flex flex-wrap gap-2">
            <.button
              type="button"
              size="sm"
              variant="secondary"
              phx-click="recheck_workers"
              data-recheck-workers
            >
              <.lucide name="refresh-cw" class="size-4" /> Check workers again
            </.button>
            <.button
              :if={@worker_state == :missing}
              size="sm"
              variant="ghost"
              navigate={~p"/onboarding/local"}
              data-setup-local-worker
            >
              Set up a local worker
            </.button>
          </div>

          <ul
            :if={@worker_candidates != []}
            class="mt-4 grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
            data-worker-list
          >
            <li
              :for={candidate <- @worker_candidates}
              class="flex items-center justify-between gap-3 rounded-lg border border-line bg-canvas px-3 py-2.5"
            >
              <span class="text-sm font-semibold text-ink">{candidate.name}</span>
              <.badge variant={worker_state_variant(candidate.state)}>
                {worker_state_label(candidate.state)}
              </.badge>
            </li>
          </ul>
        </section>

        <div class="grid gap-6 lg:grid-cols-[minmax(0,1.25fr)_minmax(18rem,0.75fr)]">
          <section
            aria-labelledby="add-connection-heading"
            class="rounded-xl border border-line bg-surface p-4 sm:p-6"
          >
            <h2 id="add-connection-heading" class="text-base font-bold text-ink">Add a connection</h2>
            <p class="mt-1 text-sm text-ink-muted">
              Choose a label, a ready worker, and where authentication will happen.
            </p>

            <form
              id="ai-connection-form"
              phx-change="change_connection"
              phx-submit="link"
              class="mt-5 space-y-5"
            >
              <.text_field
                id="connection-label"
                name="connection[label]"
                label="Connection label"
                value={@create_values["label"]}
                maxlength="100"
                required
                disabled={@link_pending?}
                hint="Use a name you can recognize without exposing provider account identity."
              />

              <div>
                <label for="connection-worker" class="block text-[13px] font-semibold text-ink">Local worker</label>
                <select
                  id="connection-worker"
                  name="connection[worker_id]"
                  required
                  disabled={@link_pending? or @worker_state != :ready}
                  class="mt-1.5 h-10 w-full rounded-lg border border-line-strong bg-surface px-3 text-sm text-ink outline-none focus:outline-solid focus:outline-2 focus:outline-focus"
                >
                  <option value="" disabled selected={@create_values["worker_id"] == ""}>
                    Choose a ready local worker
                  </option>
                  <option
                    :for={candidate <- @worker_candidates}
                    value={candidate.key}
                    disabled={candidate.state != :ready}
                    selected={@create_values["worker_id"] == candidate.key}
                  >
                    {candidate.name} ({worker_state_label(candidate.state)})
                  </option>
                </select>
              </div>

              <fieldset>
                <legend class="text-[13px] font-semibold text-ink">Authentication handoff</legend>
                <div class="mt-2 grid gap-3 sm:grid-cols-2">
                  <label class="flex cursor-pointer gap-3 rounded-lg border border-line-strong p-3 focus-within:outline focus-within:outline-2 focus-within:outline-focus">
                    <input
                      type="radio"
                      name="connection[authentication_mode]"
                      value="chatgpt"
                      checked={@create_values["authentication_mode"] == "chatgpt"}
                      disabled={@link_pending?}
                    />
                    <span>
                      <span class="block text-sm font-semibold text-ink">ChatGPT</span>
                      <span class="mt-1 block text-xs leading-5 text-ink-muted">The local worker opens and completes managed sign-in.</span>
                    </span>
                  </label>
                  <label class="flex cursor-pointer gap-3 rounded-lg border border-line-strong p-3 focus-within:outline focus-within:outline-2 focus-within:outline-focus">
                    <input
                      type="radio"
                      name="connection[authentication_mode]"
                      value="api_key"
                      checked={@create_values["authentication_mode"] == "api_key"}
                      disabled={@link_pending?}
                    />
                    <span>
                      <span class="block text-sm font-semibold text-ink">API key</span>
                      <span class="mt-1 block text-xs leading-5 text-ink-muted">Enter the secret only in the local worker window.</span>
                    </span>
                  </label>
                </div>
              </fieldset>

              <.button
                type="submit"
                disabled={@link_pending? or @worker_state != :ready}
                data-link-connection
              >
                <.lucide :if={@link_pending?} name="loader" class="size-4 motion-safe:animate-spin" />
                {if @link_pending?, do: "Waiting for local worker", else: "Add connection"}
              </.button>
            </form>

            <div
              :if={@link_result}
              id="link-result"
              role={if match?({:error, _}, @link_result), do: "alert", else: "status"}
              aria-live="polite"
              tabindex={if match?({:pending, _}, @link_result), do: nil, else: "-1"}
              phx-mounted={if match?({:pending, _}, @link_result), do: nil, else: JS.focus()}
              class="mt-5 rounded-lg border border-line bg-canvas p-3 text-sm text-ink"
              data-link-state={@link_result |> elem(0) |> Atom.to_string()}
            >
              {link_result_message(@link_result)}
            </div>
          </section>

          <aside class="space-y-4" aria-label="Connection facts">
            <section data-catalog-panel class="rounded-xl border border-line bg-surface p-4 sm:p-5">
              <h2 class="text-sm font-bold text-ink">Model catalog</h2>
              <p :if={@connections == []} class="mt-2 text-sm leading-6 text-ink-muted">
                Model and effort facts are currently unavailable. Add a connection before retrieving authenticated facts.
              </p>

              <div :if={@connections != []} class="mt-3 space-y-4">
                <article
                  :for={connection <- @connections}
                  id={"catalog-#{connection.id}"}
                  data-catalog-connection
                  class="rounded-lg border border-line bg-canvas p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <h3 class="truncate text-sm font-semibold text-ink">{connection.label}</h3>
                      <p class="mt-0.5 text-xs text-ink-muted">Authenticated catalog only</p>
                    </div>
                    <.button
                      type="button"
                      size="sm"
                      variant="ghost"
                      phx-click="refresh_catalog"
                      phx-value-id={connection.id}
                      disabled={
                        connection.availability != "available" or
                          connection.revocation_state != "active" or
                          MapSet.member?(@catalog_refreshing_ids, connection.id)
                      }
                      data-refresh-catalog
                    >
                      <.lucide
                        :if={MapSet.member?(@catalog_refreshing_ids, connection.id)}
                        name="loader"
                        class="size-4 motion-safe:animate-spin"
                      />
                      {if MapSet.member?(@catalog_refreshing_ids, connection.id),
                        do: "Refreshing",
                        else: "Refresh"}
                    </.button>
                  </div>

                  <p
                    :if={Map.get(@catalogs, connection.id) in [nil, {:error, :unknown}]}
                    class="mt-3 text-xs leading-5 text-ink-muted"
                    data-catalog-unknown
                  >
                    Model and effort compatibility is unknown until a live refresh succeeds.
                  </p>

                  <p
                    :if={match?({:error, :stale}, Map.get(@catalogs, connection.id))}
                    class="mt-3 text-xs leading-5 text-warn-fg"
                    data-catalog-stale
                  >
                    The last catalog expired. Refresh it before selecting a model.
                  </p>

                  <div :for={{:ok, catalog} <- [Map.get(@catalogs, connection.id)]} class="mt-3">
                    <p
                      :if={catalog.status == "enumeration_unsupported"}
                      class="mb-3 text-xs leading-5 text-warn-fg"
                      data-catalog-limited
                    >
                      Enumeration is unsupported. Only the worker-proven current or default model is shown.
                    </p>

                    <ul class="space-y-3" data-catalog-models>
                      <li
                        :for={model <- catalog.models}
                        class="rounded-md border border-line bg-surface p-3"
                        data-catalog-model
                        data-model={model.model}
                      >
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="text-sm font-semibold text-ink">{model.display_name}</span>
                          <.badge :if={model.current} variant="ok">Current</.badge>
                          <.badge :if={model.default} variant="neutral">Default</.badge>
                        </div>
                        <p class="mt-1 break-all text-xs text-ink-muted">{model.model}</p>

                        <div class="mt-2 flex flex-wrap gap-1.5" data-effort-choices>
                          <span
                            :for={effort <- model.supported_reasoning_efforts}
                            class="rounded-full border border-line-strong bg-canvas px-2 py-1 text-xs text-ink"
                            data-effort={effort.reasoning_effort}
                            title={effort.description}
                          >
                            {effort.reasoning_effort}
                            <span
                              :if={model.default_reasoning_effort == effort.reasoning_effort}
                              class="text-ink-muted"
                            >
                              · default
                            </span>
                          </span>
                        </div>
                      </li>
                    </ul>

                    <p class="mt-3 text-[11px] leading-4 text-ink-muted" data-catalog-provenance>
                      {catalog_source_label(catalog.provenance.source)} · {catalog.provenance.method} · retrieved {catalog_time(
                        catalog.provenance.retrieved_at
                      )} · expires {catalog_time(catalog.expires_at)}
                    </p>
                  </div>

                  <p
                    :if={Map.get(@catalog_results, connection.id) == :pending}
                    class="mt-3 text-xs text-ink-muted"
                    role="status"
                    aria-live="polite"
                    data-catalog-result="pending"
                  >
                    Requesting the live catalog from the local worker…
                  </p>
                  <p
                    :if={Map.get(@catalog_results, connection.id) == :ok}
                    class="mt-3 text-xs text-ok-fg"
                    role="status"
                    aria-live="polite"
                    data-catalog-result="ok"
                  >
                    Live model and effort facts refreshed.
                  </p>
                  <p
                    :for={{:error, reason} <- [Map.get(@catalog_results, connection.id)]}
                    class="mt-3 text-xs text-err-fg"
                    role="alert"
                    aria-live="polite"
                    data-catalog-result="error"
                  >
                    {catalog_error_message(reason)}
                  </p>
                </article>
              </div>
            </section>
            <section data-quota-panel class="rounded-xl border border-line bg-surface p-4 sm:p-5">
              <h2 class="text-sm font-bold text-ink">Quota</h2>
              <p :if={@connections == []} class="mt-2 text-sm leading-6 text-ink-muted">
                Quota, reset, credit, paid-use, and token-activity facts are currently unknown. Add a connection before retrieving authenticated facts.
              </p>

              <div :if={@connections != []} class="mt-3 space-y-4">
                <article
                  :for={connection <- @connections}
                  id={"quota-#{connection.id}"}
                  data-quota-connection
                  class="rounded-lg border border-line bg-canvas p-3"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <h3 class="truncate text-sm font-semibold text-ink">{connection.label}</h3>
                      <p class="mt-0.5 text-xs text-ink-muted">
                        {if connection.authentication_mode == "api_key",
                          do: "API-key quota and billing stay unknown",
                          else: "Connection-owner ChatGPT facts only"}
                      </p>
                    </div>
                    <.button
                      type="button"
                      size="sm"
                      variant="ghost"
                      phx-click="refresh_quota"
                      phx-value-id={connection.id}
                      disabled={
                        connection.availability != "available" or
                          connection.revocation_state != "active" or
                          MapSet.member?(@quota_refreshing_ids, connection.id)
                      }
                      data-refresh-quota
                    >
                      <.lucide
                        :if={MapSet.member?(@quota_refreshing_ids, connection.id)}
                        name="loader"
                        class="size-4 motion-safe:animate-spin"
                      />
                      {if MapSet.member?(@quota_refreshing_ids, connection.id),
                        do: "Refreshing",
                        else: "Refresh"}
                    </.button>
                  </div>

                  <p
                    :if={Map.get(@quotas, connection.id) in [nil, {:error, :unknown}]}
                    class="mt-3 text-xs leading-5 text-ink-muted"
                    data-quota-unknown
                  >
                    No quantity, reset, credit, paid continuation, token activity, or billing state is assumed.
                  </p>

                  <p
                    :if={match?({:error, :stale}, Map.get(@quotas, connection.id))}
                    class="mt-3 text-xs leading-5 text-warn-fg"
                    data-quota-stale
                  >
                    The last quota snapshot expired. Refresh it before relying on these facts.
                  </p>

                  <div :for={{:ok, quota} <- [Map.get(@quotas, connection.id)]} class="mt-3">
                    <p
                      :if={quota.authentication_mode == "api_key"}
                      class="rounded-md border border-line bg-surface p-3 text-xs leading-5 text-warn-fg"
                      data-api-key-quota-unknown
                    >
                      API-key account quota, credits, and billing are unknown. ChatGPT rate-limit and token-activity methods are not used as API-key billing evidence.
                    </p>

                    <p
                      :if={quota.authentication_mode == "chatgpt" and quota.buckets == []}
                      class="rounded-md border border-line bg-surface p-3 text-xs leading-5 text-warn-fg"
                      data-quota-buckets-unknown
                    >
                      The authenticated client did not supply a complete quota bucket. Capacity remains unknown.
                    </p>

                    <ul :if={quota.buckets != []} class="space-y-3" data-quota-buckets>
                      <li
                        :for={bucket <- quota.buckets}
                        class="rounded-md border border-line bg-surface p-3"
                        data-quota-bucket
                        data-bucket-id={bucket.id}
                        data-bucket-scope={bucket.scope}
                      >
                        <div class="flex flex-wrap items-center gap-2">
                          <span class="break-all text-sm font-semibold text-ink">
                            {bucket.display_name || bucket.id}
                          </span>
                          <.badge variant="neutral">{quota_scope_label(bucket.scope)}</.badge>
                        </div>
                        <p :if={bucket.model} class="mt-1 break-all text-xs text-ink-muted">
                          Model scope: {bucket.model}
                        </p>

                        <div class="mt-3 grid gap-2 sm:grid-cols-2">
                          <div
                            :if={bucket.primary_window}
                            class="rounded-md border border-line bg-canvas p-2.5"
                            data-primary-window
                          >
                            <p class="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                              Primary window
                            </p>
                            <p class="mt-1 text-sm font-semibold text-ink">
                              {bucket.primary_window.used_percent}% used
                            </p>
                            <p class="mt-1 text-xs text-ink-muted">
                              Reset: {quota_value(
                                bucket.primary_window.resets_at &&
                                  quota_time(bucket.primary_window.resets_at)
                              )}
                            </p>
                            <p class="text-xs text-ink-muted">
                              Duration: {quota_value(bucket.primary_window.duration_minutes)} minutes
                            </p>
                          </div>
                          <div
                            :if={bucket.secondary_window}
                            class="rounded-md border border-line bg-canvas p-2.5"
                            data-secondary-window
                          >
                            <p class="text-[11px] font-semibold uppercase tracking-wide text-ink-muted">
                              Secondary window
                            </p>
                            <p class="mt-1 text-sm font-semibold text-ink">
                              {bucket.secondary_window.used_percent}% used
                            </p>
                            <p class="mt-1 text-xs text-ink-muted">
                              Reset: {quota_value(
                                bucket.secondary_window.resets_at &&
                                  quota_time(bucket.secondary_window.resets_at)
                              )}
                            </p>
                            <p class="text-xs text-ink-muted">
                              Duration: {quota_value(bucket.secondary_window.duration_minutes)} minutes
                            </p>
                          </div>
                        </div>

                        <div class="mt-3 grid gap-1 text-xs text-ink-muted">
                          <p data-paid-continuation>
                            Paid continuation: {paid_continuation_label(bucket.paid_continuation)}
                          </p>
                          <p :if={bucket.credits} data-credit-facts>
                            Credits: {if bucket.credits.has_credits,
                              do: "available",
                              else: "not available"} · unlimited: {if bucket.credits.unlimited,
                              do: "yes",
                              else: "no"} · balance: {quota_value(bucket.credits.balance)}
                          </p>
                          <p :if={bucket.spend_control} data-spend-control>
                            Provider spend control: {bucket.spend_control.remaining_percent}% remaining · reset {quota_time(
                              bucket.spend_control.resets_at
                            )}
                          </p>
                          <p :if={bucket.limit_reached_reason} data-limit-reached>
                            Provider limit state: {bucket.limit_reached_reason}
                          </p>
                          <p :if={bucket.unknown_fields != []} data-bucket-unknowns>
                            {length(bucket.unknown_fields)} bucket {if length(bucket.unknown_fields) ==
                                                                         1,
                                                                       do: "field is",
                                                                       else: "fields are"} unknown.
                          </p>
                        </div>
                      </li>
                    </ul>

                    <div class="mt-3 grid gap-2 text-xs text-ink-muted sm:grid-cols-2">
                      <p class="rounded-md border border-line bg-surface p-2.5" data-reset-credits>
                        Reset credits: {if quota.reset_credits,
                          do: quota.reset_credits.available_count,
                          else: "Unknown"}
                      </p>
                      <p class="rounded-md border border-line bg-surface p-2.5" data-token-activity>
                        Lifetime token activity: {if quota.token_activity,
                          do: quota_value(quota.token_activity.lifetime_tokens),
                          else: "Unknown"}
                      </p>
                    </div>

                    <p
                      :if={quota.unknown_fields != []}
                      class="mt-2 text-xs text-ink-muted"
                      data-quota-unknowns
                    >
                      {length(quota.unknown_fields)} account {if length(quota.unknown_fields) == 1,
                        do: "fact is",
                        else: "facts are"} explicitly unknown.
                    </p>

                    <p class="mt-3 text-[11px] leading-4 text-ink-muted" data-quota-provenance>
                      Official client · {quota_source_methods(quota.provenance.methods)} · retrieved {quota_time(
                        quota.provenance.retrieved_at
                      )} · expires {quota_time(quota.expires_at)}
                    </p>
                  </div>

                  <p
                    :if={Map.get(@quota_results, connection.id) == :pending}
                    class="mt-3 text-xs text-ink-muted"
                    role="status"
                    aria-live="polite"
                    data-quota-result="pending"
                  >
                    Requesting live quota facts from the local worker…
                  </p>
                  <p
                    :if={Map.get(@quota_results, connection.id) == :ok}
                    class="mt-3 text-xs text-ok-fg"
                    role="status"
                    aria-live="polite"
                    data-quota-result="ok"
                  >
                    Live quota and token-activity facts refreshed.
                  </p>
                  <p
                    :for={{:error, reason} <- [Map.get(@quota_results, connection.id)]}
                    class="mt-3 text-xs text-err-fg"
                    role="alert"
                    aria-live="polite"
                    data-quota-result="error"
                  >
                    {quota_error_message(reason)}
                  </p>
                </article>
              </div>
            </section>
          </aside>
        </div>

        <section aria-labelledby="connections-heading">
          <div class="flex items-end justify-between gap-4">
            <div>
              <h2 id="connections-heading" class="text-lg font-bold text-ink">Your connections</h2>
              <p class="mt-1 text-sm text-ink-muted">Labels and safe availability only.</p>
            </div>
            <span class="text-sm text-ink-muted">{length(@connections)} total</span>
          </div>

          <div
            :if={@connections == []}
            data-empty-connections
            class="mt-4 rounded-xl border border-dashed border-line-strong bg-surface p-6 text-sm text-ink-muted"
          >
            No personal AI connections yet.
          </div>

          <ul :if={@connections != []} id="ai-connections-list" class="mt-4 grid gap-4 lg:grid-cols-2">
            <li
              :for={connection <- @connections}
              id={"connection-#{connection.id}"}
              data-connection
              class="min-w-0 rounded-xl border border-line bg-surface p-4 sm:p-5"
            >
              <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <h3 data-connection-label class="truncate text-base font-bold text-ink">
                    {connection.label}
                  </h3>
                  <p class="mt-1 text-sm text-ink-muted">
                    {authentication_label(connection.authentication_mode)} · credential-local
                  </p>
                </div>
                <.badge variant={availability_variant(connection)}>
                  {availability_label(connection)}
                </.badge>
              </div>

              <form
                :if={@editing_connection_id == connection.id}
                id={"rename-form-#{connection.id}"}
                phx-submit="rename"
                class="mt-4 rounded-lg border border-line bg-canvas p-3"
                phx-mounted={JS.focus(to: "#rename-input-#{connection.id}")}
              >
                <.text_field
                  id={"rename-input-#{connection.id}"}
                  name="rename[label]"
                  label="Connection label"
                  value={connection.label}
                  maxlength="100"
                  required
                />
                <div class="mt-3 flex flex-wrap gap-2">
                  <.button type="submit" size="sm" data-save-rename>Save label</.button>
                  <.button type="button" size="sm" variant="ghost" phx-click="cancel_rename">Cancel</.button>
                </div>
              </form>

              <div
                :if={@rename_result == {:ok, connection.id}}
                role="status"
                aria-live="polite"
                tabindex="-1"
                phx-mounted={JS.focus()}
                class="mt-3 text-sm text-ok-fg"
                data-rename-result
              >
                Label updated.
              </div>

              <div
                :if={@confirming_revoke_id == connection.id}
                class="mt-4 rounded-lg border border-warn-fg/40 bg-warn-bg p-3"
                data-revoke-confirmation
              >
                <p class="text-sm font-semibold text-warn-fg">Revoke this connection?</p>
                <p class="mt-1 text-xs leading-5 text-warn-fg">
                  New AI work will be denied immediately. Worker-local credential removal is reconciled separately.
                </p>
                <div class="mt-3 flex flex-wrap gap-2">
                  <.button
                    id={"confirm-revoke-#{connection.id}"}
                    type="button"
                    size="sm"
                    phx-click="confirm_revoke"
                    phx-mounted={JS.focus()}
                    data-confirm-revoke
                  >
                    Confirm revoke
                  </.button>
                  <.button type="button" size="sm" variant="ghost" phx-click="cancel_revoke">Keep connection</.button>
                </div>
              </div>

              <div
                :if={Map.get(@revocation_results, connection.id)}
                role={
                  if match?({:error, _}, Map.get(@revocation_results, connection.id)),
                    do: "alert",
                    else: "status"
                }
                aria-live="polite"
                tabindex={
                  if Map.get(@revocation_results, connection.id) == :pending, do: nil, else: "-1"
                }
                phx-mounted={
                  if Map.get(@revocation_results, connection.id) == :pending,
                    do: nil,
                    else: JS.focus()
                }
                class="mt-3 text-sm text-ink"
                data-revoke-result
              >
                <span :if={Map.get(@revocation_results, connection.id) == :pending}>Recording the revocation request…</span>
                <span :if={Map.get(@revocation_results, connection.id) == :ok}>Revocation requested. New AI work is denied.</span>
                <span :if={match?({:error, _}, Map.get(@revocation_results, connection.id))}>
                  {error_message(elem(Map.get(@revocation_results, connection.id), 1))}
                </span>
              </div>

              <div
                :if={
                  @editing_connection_id != connection.id and @confirming_revoke_id != connection.id
                }
                class="mt-4 flex flex-wrap gap-2"
              >
                <.button
                  type="button"
                  size="sm"
                  variant="secondary"
                  phx-click="start_rename"
                  phx-value-id={connection.id}
                  disabled={connection.revocation_state != "active"}
                  data-rename-connection
                >
                  <.lucide name="pencil" class="size-4" /> Rename
                </.button>
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="start_revoke"
                  phx-value-id={connection.id}
                  disabled={
                    connection.revocation_state != "active" or
                      MapSet.member?(@revoking_ids, connection.id)
                  }
                  data-revoke-connection
                >
                  <.lucide name="unplug" class="size-4" /> Revoke
                </.button>
              </div>
            </li>
          </ul>

          <div
            :if={match?({:error, _}, @rename_result)}
            id="rename-error"
            role="alert"
            aria-live="polite"
            tabindex="-1"
            phx-mounted={JS.focus()}
            class="mt-4 rounded-lg border border-err-fg/40 bg-err-bg p-3 text-sm text-err-fg"
          >
            {error_message(elem(@rename_result, 1))}
          </div>
        </section>
      </div>
    </.app_shell>
    """
  end
end
