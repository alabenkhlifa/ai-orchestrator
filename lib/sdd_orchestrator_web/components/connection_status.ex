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

  @device_statuses ~w(connected unavailable authorization_required invalid)

  @doc """
  A status badge for a local (device) repository connection state (slice 02).

  The state vocabulary is `SddOrchestrator.Devices.RepositoryConnectionContract`'s
  connected / unavailable / authorization_required / invalid. Each state pairs a
  distinct color with a distinct icon and text so its meaning never depends on
  color alone; the hard-error `invalid` state uses an error-red icon.
  """
  attr :status, :string, required: true
  attr :class, :any, default: nil

  def device_connection_badge(assigns) do
    ~H"""
    <.badge variant={device_variant(@status)} icon={device_icon(@status)} class={@class}>
      {device_label(@status)}
    </.badge>
    """
  end

  @doc "The permitted device connection statuses."
  def device_statuses, do: @device_statuses

  @doc "The plain-language label for a device connection status."
  def device_label("connected"), do: "Connected"
  def device_label("unavailable"), do: "Unavailable"
  def device_label("authorization_required"), do: "Pairing needed"
  def device_label("invalid"), do: "Invalid repository"

  # Distinct color per state: ok / neutral / warn / err.
  defp device_variant("connected"), do: "ok"
  defp device_variant("unavailable"), do: "neutral"
  defp device_variant("authorization_required"), do: "warn"
  defp device_variant("invalid"), do: "err"

  # Distinct icon per state; `invalid` gets the error-red triangle.
  defp device_icon("connected"), do: "circle-check"
  defp device_icon("unavailable"), do: "unplug"
  defp device_icon("authorization_required"), do: "shield"
  defp device_icon("invalid"), do: "triangle-alert"
end
