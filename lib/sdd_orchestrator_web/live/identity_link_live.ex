defmodule SddOrchestratorWeb.IdentityLinkLive do
  @moduledoc """
  The GitHub-to-passwordless identity-linking flow.

  After a GitHub sign-in whose verified email matches an existing passwordless
  account, this screen requests a fresh passwordless proof, then — once both
  sign-in methods are proven and the preflight is clear — shows the merge
  consequences and requires explicit confirmation before the atomic commit. Every
  failure keeps both accounts separate; the candidate account's data is never
  shown before proof.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.IdentityLinking

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    account = socket.assigns.current_account

    case IdentityLinking.get_live_attempt_for_account(id, account.id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:info, "There is nothing to link right now.")
         |> push_navigate(to: ~p"/projects")}

      attempt ->
        {:ok,
         socket
         |> assign(:page_title, "Link your GitHub sign-in")
         |> assign(:attempt, attempt)
         |> assign(:step, step_for(attempt))}
    end
  end

  @impl true
  def handle_event("send_proof", _params, socket) do
    case IdentityLinking.send_passwordless_proof(socket.assigns.attempt) do
      :ok ->
        {:noreply, assign(socket, :step, :sent)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "We could not start verification. Your accounts are unchanged.")
         |> push_navigate(to: ~p"/projects")}
    end
  end

  def handle_event("confirm", _params, socket) do
    attempt = socket.assigns.attempt

    with {:ok, confirmed} <- IdentityLinking.confirm_merge(attempt),
         {:ok, _record} <- IdentityLinking.commit_merge(confirmed) do
      {:noreply,
       socket
       |> put_flash(:info, "Your GitHub sign-in is now linked and your projects are combined.")
       |> push_navigate(to: ~p"/projects")}
    else
      _error ->
        {:noreply,
         socket
         |> put_flash(:error, "Linking could not complete, so your accounts are unchanged.")
         |> push_navigate(to: ~p"/projects")}
    end
  end

  def handle_event("decline", _params, socket) do
    {:ok, _} = IdentityLinking.abort_merge_attempt(socket.assigns.attempt)

    {:noreply,
     socket
     |> put_flash(:info, "Your accounts were kept separate.")
     |> push_navigate(to: ~p"/projects")}
  end

  defp step_for(attempt) do
    if is_nil(attempt.passwordless_proven_at), do: :detected, else: :confirm
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl p-6" id="identity-link">
      <h1 class="text-2xl font-semibold">Link your GitHub sign-in</h1>

      <div :if={@step == :detected} class="mt-4 space-y-4" id="link-step-detected">
        <p>
          Your GitHub email matches an existing SDD Orchestrator account. To link them,
          confirm you control that email. We will send a verification link to it.
        </p>
        <div class="flex flex-col gap-3 sm:flex-row">
          <button
            phx-click="send_proof"
            class="w-full rounded-md bg-zinc-900 px-4 py-2 font-medium text-white sm:w-auto"
          >
            Email me a verification link
          </button>
          <button
            phx-click="decline"
            class="w-full rounded-md border border-zinc-300 px-4 py-2 font-medium sm:w-auto"
          >
            Keep accounts separate
          </button>
        </div>
      </div>

      <div :if={@step == :sent} class="mt-4 space-y-4" id="link-step-sent">
        <p>
          Check your email and open the verification link to continue linking. This
          page will show the final confirmation once your email is verified.
        </p>
        <button
          phx-click="decline"
          class="w-full rounded-md border border-zinc-300 px-4 py-2 font-medium sm:w-auto"
        >
          Keep accounts separate
        </button>
      </div>

      <div :if={@step == :confirm} class="mt-4 space-y-4" id="link-step-confirm">
        <p>Both sign-in methods are verified. Linking will:</p>
        <ul class="list-disc space-y-1 pl-6">
          <li>combine every project into your existing account,</li>
          <li>make GitHub a sign-in method for it,</li>
          <li>revoke any worker paired to the absorbed workspace, and</li>
          <li>cannot be undone by yourself afterward.</li>
        </ul>
        <div class="flex flex-col gap-3 sm:flex-row">
          <button
            phx-click="confirm"
            class="w-full rounded-md bg-zinc-900 px-4 py-2 font-medium text-white sm:w-auto"
          >
            Confirm and link
          </button>
          <button
            phx-click="decline"
            class="w-full rounded-md border border-zinc-300 px-4 py-2 font-medium sm:w-auto"
          >
            Keep accounts separate
          </button>
        </div>
      </div>
    </div>
    """
  end
end
