defmodule SddOrchestratorWeb.UI do
  @moduledoc """
  Shared presentation primitives for the SDD Orchestrator onboarding surfaces.

  These function components implement the approved graphite/teal visual system
  (see `specs/01-github-project-onboarding/design.md`). They are the reusable
  building blocks — button, link, field, selection row, status, notice, loading,
  empty, and failure states, plus the shared page shell and device-local theme
  control — that every workflow screen composes.

  Design rules enforced here:

    * Meaningful state never relies on color alone: status badges, notices, and
      failure states always pair color with an icon and text.
    * Interactive elements expose a keyboard-visible focus ring
      (`focus-visible:outline`).
    * The theme control is device-local; toggling it never contacts the server
      (see the `ThemeToggle` hook and the pre-paint script in `root.html.heex`).
  """
  use Phoenix.Component

  import SddOrchestratorWeb.Icons

  @focus_ring "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  # Keyboard-visible focus ring shared by interactive primitives. Exposed as a
  # function because `@focus_ring` inside a ~H template would resolve to an
  # assign, not this module attribute.
  defp focus_ring, do: @focus_ring

  @doc """
  The shared page shell: a top bar (brand + optional actions + theme control)
  above a canvas content area. Every protected and onboarding screen renders
  inside this frame so the shell composition stays consistent.

  ## Examples

      <.app_shell brand>
        <:actions>
          <.button variant="ghost" phx-click="sign_out">Sign out</.button>
        </:actions>
        <p>Screen content</p>
      </.app_shell>
  """
  attr :brand, :boolean, default: true, doc: "show the SDD Orchestrator brand mark"
  attr :max_width, :string, default: "max-w-3xl", doc: "content max-width utility"
  attr :class, :any, default: nil
  slot :actions, doc: "controls rendered at the right of the top bar, before the theme toggle"
  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="min-h-dvh flex flex-col bg-canvas text-ink">
      <header class="h-14 flex-none flex items-center justify-between gap-3 px-4 sm:px-6 border-b border-line bg-surface">
        <div class="flex items-center gap-2.5 min-w-0">
          <a
            :if={@brand}
            href="/"
            class={["flex items-center gap-2.5 rounded-lg min-w-0", focus_ring()]}
          >
            <span class="flex-none w-7 h-7 rounded-lg bg-primary text-on-primary flex items-center justify-center">
              <.lucide name="logo" class="size-4" />
            </span>
            <span class="text-sm font-bold tracking-tight truncate">SDD Orchestrator</span>
          </a>
        </div>
        <div class="flex items-center gap-2.5 flex-none">
          {render_slot(@actions)}
          <.theme_toggle />
        </div>
      </header>
      <main class={["flex-1 min-h-0 overflow-auto", @class]}>
        <div class={["mx-auto w-full px-4 sm:px-6 py-8", @max_width]}>
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  @doc """
  Device-local light/dark theme toggle.

  Both glyphs are rendered and CSS shows the one matching the active theme, so
  the control is meaningful before JavaScript connects. The delegated handler in
  `app.js` persists the explicit choice in `localStorage` on the current device
  only; it never contacts the server.
  """
  attr :id, :string, default: "theme-toggle"
  attr :class, :any, default: nil

  def theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-theme-toggle
      aria-label="Toggle color theme"
      class={[
        "w-9 h-9 flex-none rounded-lg border border-line bg-transparent text-ink-muted",
        "flex items-center justify-center cursor-pointer hover:bg-raised hover:text-ink transition",
        focus_ring(),
        @class
      ]}
    >
      <.lucide name="sun" class="size-[18px] hidden dark:block" />
      <.lucide name="moon" class="size-[18px] block dark:hidden" />
      <span class="sr-only" data-theme-label>Toggle color theme</span>
    </button>
    """
  end

  @doc """
  A button or button-styled link.

  Pass `navigate`, `patch`, or `href` to render a link; otherwise a `<button>`.

  ## Examples

      <.button variant="primary" phx-click="go">Continue</.button>
      <.button variant="secondary" navigate={~p"/"}>Back</.button>
  """
  attr :variant, :string, default: "primary", values: ~w(primary secondary ghost)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type form)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns = assign(assigns, :computed_class, button_classes(assigns))

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@computed_class} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@computed_class} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  defp button_classes(assigns) do
    base =
      "inline-flex items-center justify-center gap-2 rounded-lg font-semibold transition " <>
        "whitespace-nowrap cursor-pointer disabled:cursor-not-allowed disabled:opacity-50 " <>
        @focus_ring

    size =
      case assigns.size do
        "sm" -> "h-8 px-3 text-[13px]"
        "md" -> "h-10 px-4 text-sm"
        "lg" -> "h-13 px-5 text-base"
      end

    variant =
      case assigns.variant do
        "primary" ->
          "bg-primary text-on-primary border border-transparent hover:brightness-110"

        "secondary" ->
          "bg-surface text-ink border border-line-strong hover:bg-raised"

        "ghost" ->
          "bg-transparent text-ink-muted border border-transparent hover:bg-raised hover:text-ink"
      end

    [base, size, variant, assigns.class]
  end

  @doc """
  A status badge (pill). Always pairs its color with an icon and text so state
  meaning never depends on color alone.
  """
  attr :variant, :string, default: "neutral", values: ~w(neutral ok info warn err)
  attr :icon, :string, default: nil, doc: "Lucide icon name; defaults per variant"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    assigns =
      assign(assigns, :resolved_icon, assigns.icon || default_status_icon(assigns.variant))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold",
      badge_variant_class(@variant),
      @class
    ]}>
      <.lucide name={@resolved_icon} class="size-3.5" />
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_variant_class("ok"), do: "bg-ok-bg text-ok-fg"
  defp badge_variant_class("info"), do: "bg-info-bg text-info-fg"
  defp badge_variant_class("warn"), do: "bg-warn-bg text-warn-fg"
  defp badge_variant_class("err"), do: "bg-err-bg text-err-fg"
  defp badge_variant_class("neutral"), do: "bg-raised text-ink-muted"

  defp default_status_icon("ok"), do: "circle-check"
  defp default_status_icon("info"), do: "info"
  defp default_status_icon("warn"), do: "triangle-alert"
  defp default_status_icon("err"), do: "triangle-alert"
  defp default_status_icon("neutral"), do: "info"

  @doc """
  An inline notice / callout box (icon + message).
  """
  attr :variant, :string, default: "info", values: ~w(info warn err neutral)
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def notice(assigns) do
    assigns =
      assign(assigns, :resolved_icon, assigns.icon || default_status_icon(assigns.variant))

    ~H"""
    <div
      role="note"
      class={[
        "flex gap-3 rounded-lg border p-3.5 text-sm leading-relaxed",
        notice_variant_class(@variant),
        @class
      ]}
    >
      <.lucide name={@resolved_icon} class="size-[18px] flex-none mt-px" />
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp notice_variant_class("info"), do: "border-line bg-raised text-ink-muted"
  defp notice_variant_class("warn"), do: "border-warn-fg/40 bg-warn-bg text-warn-fg"
  defp notice_variant_class("err"), do: "border-err-fg/40 bg-err-bg text-err-fg"
  defp notice_variant_class("neutral"), do: "border-line bg-surface text-ink-muted"

  @doc "A spinning loader icon with an accessible label."
  attr :label, :string, default: "Loading"
  attr :class, :any, default: "size-5"

  def spinner(assigns) do
    ~H"""
    <span role="status" class="inline-flex items-center gap-2 text-primary">
      <.lucide name="loader" class={["animate-spin", @class]} />
      <span class="sr-only">{@label}</span>
    </span>
    """
  end

  @doc "A skeleton placeholder block (pulsing) used in loading lists."
  attr :class, :any, default: nil

  def skeleton(assigns) do
    ~H"""
    <div class={["animate-pulse rounded bg-raised", @class]} aria-hidden="true"></div>
    """
  end

  @doc """
  An empty state: neutral icon, title, description, and optional actions.
  """
  attr :icon, :string, default: "folder"
  attr :title, :string, required: true
  slot :description
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center text-center px-6 py-12">
      <span class="w-13 h-13 rounded-xl bg-raised text-ink-muted flex items-center justify-center p-3">
        <.lucide name={@icon} class="size-6" />
      </span>
      <h3 class="mt-4 text-base font-bold text-ink">{@title}</h3>
      <p :if={@description != []} class="mt-2 max-w-sm text-sm leading-relaxed text-ink-muted">
        {render_slot(@description)}
      </p>
      <div :if={@actions != []} class="mt-5 flex flex-wrap items-center justify-center gap-2.5">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A failure state: error icon, title, description, and recovery actions. Distinct
  from `empty_state/1` by its error framing so states remain distinguishable.
  """
  attr :icon, :string, default: "triangle-alert"
  attr :title, :string, required: true
  slot :description
  slot :actions

  def failure_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center text-center px-6 py-12" role="alert">
      <span class="w-13 h-13 rounded-xl bg-err-bg text-err-fg flex items-center justify-center p-3">
        <.lucide name={@icon} class="size-6" />
      </span>
      <h3 class="mt-4 text-base font-bold text-ink">{@title}</h3>
      <p :if={@description != []} class="mt-2 max-w-sm text-sm leading-relaxed text-ink-muted">
        {render_slot(@description)}
      </p>
      <div :if={@actions != []} class="mt-5 flex flex-wrap items-center justify-center gap-2.5">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  A single-selection option row (ARIA `radio`). Keyboard operable and used by
  the repository picker and storage-selection step. Non-color selection cues:
  a filled radio dot and a trailing check icon in addition to the accent border.
  """
  attr :selected, :boolean, default: false
  attr :label, :string, required: true, doc: "accessible label for the option"
  attr :disabled, :boolean, default: false
  attr :rest, :global, include: ~w(phx-click phx-value-id tabindex role aria-checked)
  slot :inner_block, required: true

  def radio_option(assigns) do
    ~H"""
    <div
      role="radio"
      aria-checked={to_string(@selected)}
      aria-label={@label}
      aria-disabled={@disabled && "true"}
      tabindex={(@disabled && "-1") || "0"}
      data-selected={to_string(@selected)}
      class={[
        "flex items-center gap-3 rounded-lg border p-3 bg-surface transition",
        (@selected && "border-primary ring-1 ring-primary") || "border-line hover:border-line-strong",
        @disabled && "opacity-60 cursor-not-allowed",
        focus_ring()
      ]}
      {@rest}
    >
      <span class={[
        "flex-none w-[18px] h-[18px] rounded-full border-2 flex items-center justify-center",
        (@selected && "border-primary") || "border-line-strong"
      ]}>
        <span :if={@selected} class="w-2.5 h-2.5 rounded-full bg-primary"></span>
      </span>
      <div class="flex-1 min-w-0">{render_slot(@inner_block)}</div>
      <.lucide :if={@selected} name="check" class="size-5 flex-none text-primary" />
    </div>
    """
  end

  @doc """
  A labeled text field with optional hint and error message. Errors pair color
  with an icon and text.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, default: nil
  attr :value, :string, default: ""
  attr :type, :string, default: "text"
  attr :error, :string, default: nil
  attr :hint, :string, default: nil

  attr :rest, :global,
    include:
      ~w(placeholder autocomplete inputmode maxlength minlength required disabled phx-debounce phx-blur)

  def text_field(assigns) do
    ~H"""
    <div>
      <label for={@id} class="block text-[13px] font-semibold text-ink">{@label}</label>
      <input
        id={@id}
        name={@name}
        type={@type}
        value={@value}
        aria-invalid={(@error && "true") || nil}
        aria-describedby={(@error && "#{@id}-error") || (@hint && "#{@id}-hint") || nil}
        class={[
          "mt-1.5 w-full h-10 rounded-lg border bg-surface px-3 text-sm text-ink outline-none",
          "focus:outline focus:outline-2 focus:outline-offset-0 focus:outline-focus",
          (@error && "border-err-fg") || "border-line-strong focus:border-focus"
        ]}
        {@rest}
      />
      <p :if={@error} id={"#{@id}-error"} class="mt-2 flex items-center gap-1.5 text-xs text-err-fg">
        <.lucide name="circle-alert" class="size-3.5 flex-none" />
        {@error}
      </p>
      <p :if={@hint && !@error} id={"#{@id}-hint"} class="mt-2 text-xs text-ink-muted">{@hint}</p>
    </div>
    """
  end
end
