defmodule SddOrchestratorWeb.ProjectNav do
  @moduledoc """
  Project-scoped navigation shared by every screen that belongs to one project.

  The feature board is where delivery work happens, so it is the project's
  default view and has to be reachable by clicking rather than by typing its
  address. This component is that path: one row of destinations, rendered
  identically on the overview, the board, a feature, and the people screen, so
  moving between them never depends on knowing a URL or on the browser's back
  button.

  Two rules shape what it renders.

  The overview destination is owner-only. A hosted participant holds no
  application session and the project is not in their personal workspace, so
  `/projects/:id/overview` would bounce them to sign-in. Offering a destination
  the viewer cannot open is worse than leaving it out, so the caller passes
  `owner?` and a participant simply sees fewer destinations.

  The current destination is never marked by color alone. It carries a heavier
  label and an indicator bar as well, so it stays identifiable in a monochrome
  or high-contrast rendering, and it exposes `aria-current` — `"page"` when the
  rendered screen is that exact destination, `"true"` when it is a descendant of
  it, such as one feature under `Features`.

  Rendering a link here grants nothing: every destination revalidates project
  authorization on its own mount rather than trusting the screen that linked to
  it.
  """
  use Phoenix.Component
  use SddOrchestratorWeb, :verified_routes

  import SddOrchestratorWeb.Icons

  # The keyboard-visible focus ring the design system's primitives use.
  # `outline-none` is deliberately absent: in Tailwind v4 it sets
  # `--tw-outline-style: none`, which every outline *width* utility then
  # resolves from, so combining the two computes to `outline-style: none` and
  # the ring never paints.
  @focus_ring "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"

  # Exposed as a function because `@focus_ring` inside a ~H template would
  # resolve to an assign rather than to this module attribute.
  defp focus_ring, do: @focus_ring

  @doc """
  The project's destination row.

  ## Examples

      <.project_nav project_id={@project_id} current={:features} owner?={@owner?} />
      <.project_nav project_id={@project_id} current={:features} exact?={false} />
  """
  attr :project_id, :string, required: true

  attr :current, :atom,
    required: true,
    doc: "`:overview`, `:features`, `:assessment`, or `:people`"

  attr :owner?, :boolean,
    default: false,
    doc: "renders the owner-only project overview destination"

  attr :exact?, :boolean,
    default: true,
    doc: "false when the rendered screen is a descendant of the current destination"

  attr :class, :any, default: nil

  def project_nav(assigns) do
    assigns = assign(assigns, :destinations, destinations(assigns.project_id, assigns.owner?))

    ~H"""
    <nav
      aria-label="Project"
      data-project-nav
      class={["flex items-center gap-1 border-b border-line", @class]}
    >
      <.link
        :for={destination <- @destinations}
        navigate={destination.path}
        data-nav-destination={destination.key}
        data-nav-current={current?(destination, @current)}
        aria-current={aria_current(destination, @current, @exact?)}
        class={[
          "-mb-px inline-flex items-center gap-1.5 whitespace-nowrap rounded-t-md",
          "border-b-2 px-2 py-2 text-sm transition",
          focus_ring(),
          (current?(destination, @current) && "border-primary font-semibold text-ink") ||
            "border-transparent font-medium text-ink-muted hover:bg-raised hover:text-ink"
        ]}
      >
        <.lucide name={destination.icon} class="size-4 flex-none" />
        {destination.label}
      </.link>
    </nav>
    """
  end

  defp destinations(project_id, owner?) do
    overview = %{
      key: "overview",
      label: "Overview",
      icon: "folder-git-2",
      path: ~p"/projects/#{project_id}/overview"
    }

    board = %{
      key: "features",
      label: "Features",
      icon: "folder",
      path: ~p"/projects/#{project_id}/features"
    }

    people = %{
      key: "people",
      label: "People",
      icon: "users",
      path: ~p"/projects/#{project_id}/participation"
    }

    assessment = %{
      key: "assessment",
      label: "Assessment",
      icon: "search",
      path: ~p"/projects/#{project_id}/assessment"
    }

    if owner?, do: [overview, board, assessment, people], else: [board, people]
  end

  defp current?(%{key: key}, current), do: key == Atom.to_string(current)

  defp aria_current(destination, current, exact?) do
    cond do
      not current?(destination, current) -> nil
      exact? -> "page"
      true -> "true"
    end
  end
end
