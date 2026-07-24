defmodule SddOrchestratorWeb.UIPreviewLiveTest do
  @moduledoc """
  LiveView/component proof for the shared presentation foundation (Task 2).

  Renders every shared primitive through the design-system preview and asserts
  the accessible structure, keyboard-operable single selection, and non-color
  state cues that the workflow screens rely on.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders the shared button and field primitives", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/_ui")

    assert html =~ "Design system"
    assert html =~ "Primary"
    assert html =~ "Secondary"
    assert html =~ "Ghost"
    # Disabled button is genuinely disabled, not just styled.
    assert html =~ ~r/<button[^>]*disabled/

    # A labeled field with an error pairs the message with an icon and text.
    assert html =~ "That name already exists in your workspace."
    assert html =~ ~s(aria-invalid="true")
  end

  test "the device-local theme control is present and accessible", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/_ui")

    assert has_element?(
             view,
             ~s(button#theme-toggle[data-theme-toggle][aria-label="Toggle color theme"])
           )
  end

  test "status badges carry an icon and text, not color alone", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/_ui")

    # A badge in the status section contains an inline <svg> icon alongside text.
    assert has_element?(view, "section[aria-labelledby='s-status'] span.rounded-full svg")

    # Meaningful states are labeled with words, never color alone.
    assert html =~ "Connected"
    assert html =~ "Disconnected"
    assert html =~ "Waiting for approval"

    # Notices likewise pair an icon with text.
    assert has_element?(view, "section[aria-labelledby='s-notices'] [role='note'] svg")
  end

  test "empty and failure states are distinguishable", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/_ui")

    assert html =~ "No repositories available"
    # Apostrophes are HTML-escaped in the raw payload; assert an unambiguous fragment.
    assert html =~ "load repositories"
    # The failure state announces itself to assistive tech; the empty state does not.
    assert has_element?(view, "section[aria-labelledby='s-empty'] [role='alert']")
  end

  test "single selection is keyboard-operable and mutually exclusive", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/_ui")

    # Options expose a radio group and keyboard tab stops.
    assert html =~ ~s(role="radiogroup")
    assert has_element?(view, "#repo-1[role='radio'][tabindex='0']")

    # Default selection is the first option only.
    assert has_element?(view, "#repo-1[aria-checked='true']")
    assert has_element?(view, "#repo-2[aria-checked='false']")

    # Selecting the second option moves the single selection.
    view |> element("#repo-2") |> render_click()

    assert has_element?(view, "#repo-1[aria-checked='false']")
    assert has_element?(view, "#repo-2[aria-checked='true']")
  end
end
