defmodule SddOrchestratorWeb.Layouts do
  @moduledoc """
  Layouts and the flash group used across the application.

  The root layout (`layouts/root.html.heex`) holds the HTML skeleton, the
  self-hosted font/asset links, and the pre-paint device-local theme script.
  Workflow screens render inside the shared page frame provided by
  `SddOrchestratorWeb.UI.app_shell/1`.
  """
  use SddOrchestratorWeb, :html

  # Embed all files in layouts/* within this module (root.html.heex).
  embed_templates "layouts/*"

  @doc """
  Shows the flash group with standard titles and content, including the
  LiveView connection-status notices.

  ## Examples

      <Layouts.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.lucide name="loader" class="ml-1 inline-block size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.lucide name="loader" class="ml-1 inline-block size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
