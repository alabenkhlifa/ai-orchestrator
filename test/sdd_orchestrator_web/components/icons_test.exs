defmodule SddOrchestratorWeb.IconsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias SddOrchestratorWeb.Icons

  test "renders a bundled Lucide icon as inline, decorative SVG" do
    html = render_component(&Icons.lucide/1, name: "github")

    assert html =~ "<svg"
    assert html =~ ~s(aria-hidden="true")
    assert html =~ ~s(stroke="currentColor")
    # The path data is embedded (no external icon request).
    assert html =~ "<path"
  end

  test "raises for an unknown icon name so typos fail loudly" do
    assert_raise KeyError, fn -> render_component(&Icons.lucide/1, name: "no-such-icon") end
  end

  test "icon_names/0 returns the sorted bundled set" do
    names = Icons.icon_names()

    assert "github" in names
    assert "loader" in names
    assert "circle-check" in names
    assert names == Enum.sort(names)
  end
end
