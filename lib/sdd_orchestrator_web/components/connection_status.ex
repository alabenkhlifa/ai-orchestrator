defmodule SddOrchestratorWeb.ConnectionStatus do
  @moduledoc """
  Shared rendering for a repository connection's status (Task 8).

  Used by the project catalog rows and the project dashboard so the connected,
  disconnected, and temporarily-unavailable states read identically everywhere.
  Status meaning never depends on color alone: each state pairs its color with a
  distinct icon and text.
  """
  use Phoenix.Component

  import SddOrchestratorWeb.UI, only: [badge: 1]

  @doc "A status badge for a `:connected` / `:disconnected` / `:temporarily_unavailable` state."
  attr :status, :atom, required: true
  attr :class, :any, default: nil

  def connection_badge(assigns) do
    ~H"""
    <.badge variant={variant(@status)} icon={icon(@status)} class={@class}>
      {label(@status)}
    </.badge>
    """
  end

  @doc "The plain-language label for a connection status."
  def label(:connected), do: "Connected"
  def label(:disconnected), do: "Disconnected"
  def label(:temporarily_unavailable), do: "Temporarily unavailable"

  defp variant(:connected), do: "ok"
  defp variant(:disconnected), do: "warn"
  defp variant(:temporarily_unavailable), do: "neutral"

  defp icon(:connected), do: "circle-check"
  defp icon(:disconnected), do: "unplug"
  defp icon(:temporarily_unavailable), do: "refresh-cw"
end
