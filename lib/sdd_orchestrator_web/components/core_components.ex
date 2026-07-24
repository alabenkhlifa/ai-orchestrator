defmodule SddOrchestratorWeb.CoreComponents do
  @moduledoc """
  Core framework-level UI helpers: flash notices, the bundled Heroicon helper,
  changeset error translation, and the show/hide JS transitions.

  The product's visual design-system primitives (buttons, fields, selection
  rows, status, notices, loading/empty/failure states, the page shell, and the
  device-local theme control) live in `SddOrchestratorWeb.UI`, and the locally
  bundled Lucide icons in `SddOrchestratorWeb.Icons`. Both are imported into
  every view alongside this module.
  """
  use Phoenix.Component
  use Gettext, backend: SddOrchestratorWeb.Gettext

  import SddOrchestratorWeb.Icons

  alias Phoenix.LiveView.JS

  @doc """
  Renders a flash notice as a top-end toast. Meaning is carried by an icon and
  text in addition to color.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} title="Something went wrong" />
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed top-4 right-4 z-50 w-80 sm:w-96 max-w-[calc(100vw-2rem)]"
      {@rest}
    >
      <div class={[
        "flex items-start gap-3 rounded-lg border p-3.5 shadow-lg text-sm",
        @kind == :info && "border-info-fg/40 bg-info-bg text-info-fg",
        @kind == :error && "border-err-fg/40 bg-err-bg text-err-fg"
      ]}>
        <.lucide :if={@kind == :info} name="info" class="size-5 flex-none mt-px" />
        <.lucide :if={@kind == :error} name="triangle-alert" class="size-5 flex-none mt-px" />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="text-wrap">{msg}</p>
        </div>
        <button
          type="button"
          class="flex-none cursor-pointer opacity-60 hover:opacity-100"
          aria-label={gettext("close")}
        >
          <.lucide name="x" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a bundled [Heroicon](https://heroicons.com).

  Icons are extracted from the `deps/heroicons` directory and bundled within the
  compiled `app.css` by the plugin in `assets/vendor/heroicons.js`; no external
  request is made. Product UI prefers `SddOrchestratorWeb.Icons.lucide/1`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(SddOrchestratorWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(SddOrchestratorWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
