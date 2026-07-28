defmodule SddOrchestratorWeb.Icons do
  @moduledoc """
  Locally bundled [Lucide](https://lucide.dev) icons.

  The icon path data is embedded directly in the compiled application, so the
  browser never issues an external icon request. Each entry is the inner markup
  of a 24×24 stroked Lucide glyph; `lucide/1` wraps it in a consistent `<svg>`.

  Render with `<.lucide name="github" class="size-5" />`. Icons are decorative
  by default (`aria-hidden`); pass `aria-hidden="false"` and a `title`/label on
  the surrounding element when an icon conveys meaning on its own.
  """
  use Phoenix.Component

  # Inner SVG markup keyed by Lucide icon name. Trusted, static, project-owned.
  @icons %{
    # Brand / logo mark (Lucide "boxes"-style blocks used across onboarding).
    "logo" =>
      ~S|<rect width="8" height="8" x="3" y="3" rx="2"/><path d="M7 11v4a2 2 0 0 0 2 2h4"/><rect width="8" height="8" x="13" y="13" rx="2"/>|,
    "sun" =>
      ~S|<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>|,
    "moon" => ~S|<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"/>|,
    "github" =>
      ~S|<path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.4 5.4 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"/><path d="M9 18c-4.51 2-5-2-7-2"/>|,
    "truck" =>
      ~S|<line x1="22" x2="2" y1="12" y2="12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" x2="6.01" y1="16" y2="16"/><line x1="10" x2="10.01" y1="16" y2="16"/>|,
    "loader" => ~S|<path d="M21 12a9 9 0 1 1-6.219-8.56"/>|,
    "triangle-alert" =>
      ~S|<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"/><path d="M12 9v4"/><path d="M12 17h.01"/>|,
    "x" => ~S|<path d="M18 6 6 18"/><path d="m6 6 12 12"/>|,
    "refresh-cw" =>
      ~S|<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M3 21v-5h5"/>|,
    "lock" =>
      ~S|<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>|,
    "search" => ~S|<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>|,
    "search-x" =>
      ~S|<path d="m13.5 8.5-5 5"/><path d="m8.5 8.5 5 5"/><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>|,
    "globe" =>
      ~S|<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/><path d="M2 12h20"/>|,
    "building-2" =>
      ~S|<path d="M6 22V4a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v18Z"/><path d="M6 12H4a2 2 0 0 0-2 2v6a2 2 0 0 0 2 2h2"/><path d="M18 9h2a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-2"/><path d="M10 6h4"/><path d="M10 10h4"/><path d="M10 14h4"/>|,
    "check" => ~S|<path d="M20 6 9 17l-5-5"/>|,
    "circle-check" => ~S|<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>|,
    "circle-alert" =>
      ~S|<circle cx="12" cy="12" r="10"/><line x1="12" x2="12" y1="8" y2="12"/><line x1="12" x2="12.01" y1="16" y2="16"/>|,
    "info" => ~S|<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>|,
    "folder" =>
      ~S|<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>|,
    "folder-git-2" =>
      ~S|<path d="M9 20H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v3"/><circle cx="13" cy="17" r="2"/><path d="M22 17h-3"/><path d="M15 17H9"/>|,
    "shield" =>
      ~S|<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="M12 8v4"/><path d="M12 16h.01"/>|,
    "arrow-right" => ~S|<path d="M5 12h14"/><path d="m12 5 7 7-7 7"/>|,
    "arrow-left" => ~S|<path d="m12 19-7-7 7-7"/><path d="M19 12H5"/>|,
    "chevron-left" => ~S|<path d="m15 18-6-6 6-6"/>|,
    "chevron-right" => ~S|<path d="m9 18 6-6-6-6"/>|,
    "plus" => ~S|<path d="M5 12h14"/><path d="M12 5v14"/>|,
    "pencil" =>
      ~S|<path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"/><path d="m15 5 4 4"/>|,
    "log-out" =>
      ~S|<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>|,
    "log-in" =>
      ~S|<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><polyline points="10 17 15 12 10 7"/><line x1="15" x2="3" y1="12" y2="12"/>|,
    "unplug" =>
      ~S|<path d="m19 5 3-3"/><path d="m2 22 3-3"/><path d="M6.3 20.3a2.4 2.4 0 0 0 3.4 0L12 18l-6-6-2.3 2.3a2.4 2.4 0 0 0 0 3.4Z"/><path d="M7.5 13.5 10 11"/><path d="M10.5 16.5 13 14"/><path d="m12 6 6 6 2.3-2.3a2.4 2.4 0 0 0 0-3.4l-2.6-2.6a2.4 2.4 0 0 0-3.4 0Z"/>|,
    "cloud" => ~S|<path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"/>|,
    "hard-drive" =>
      ~S|<line x1="22" x2="2" y1="12" y2="12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/><line x1="6" x2="6.01" y1="16" y2="16"/><line x1="10" x2="10.01" y1="16" y2="16"/>|,
    "external-link" =>
      ~S|<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>|,
    "download" =>
      ~S|<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>|,
    "link" =>
      ~S|<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>|,
    "folder-open" =>
      ~S|<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"/>|,
    "play" => ~S|<path d="M6 3v18l14-9Z"/>|,
    "wifi" =>
      ~S|<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.86a10 10 0 0 1 14 0"/><path d="M8.5 16.43a5 5 0 0 1 7 0"/>|
  }

  @doc """
  Renders a locally bundled Lucide icon as inline SVG.

  ## Examples

      <.lucide name="github" />
      <.lucide name="loader" class="size-5 animate-spin text-primary" />
  """
  attr :name, :string, required: true, doc: "the Lucide icon name (see icon_names/0)"
  attr :class, :any, default: "size-5"
  attr :rest, :global

  def lucide(assigns) do
    assigns = assign(assigns, :body, Map.fetch!(@icons, assigns.name))

    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
      aria-hidden="true"
      {@rest}
    >{Phoenix.HTML.raw(@body)}</svg>
    """
  end

  @doc "Returns the sorted list of bundled Lucide icon names."
  def icon_names, do: @icons |> Map.keys() |> Enum.sort()
end
