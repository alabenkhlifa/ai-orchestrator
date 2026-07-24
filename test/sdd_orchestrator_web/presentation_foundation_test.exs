defmodule SddOrchestratorWeb.PresentationFoundationTest do
  @moduledoc """
  Root-layout and asset proofs for the shared presentation foundation (Task 2):
  the device-local theme behavior and the self-hosted, request-free font/icon
  boundary.
  """
  use SddOrchestratorWeb.ConnCase, async: true

  @external_asset_hosts [
    "fonts.googleapis.com",
    "fonts.gstatic.com",
    "www.googletagmanager.com",
    "google-analytics.com",
    "cdn.jsdelivr.net",
    "unpkg.com"
  ]

  test "the root document sets the title and applies the device-local theme before paint", %{
    conn: conn
  } do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ "SDD Orchestrator"

    # Device-local, pre-paint theme: reads localStorage, falls back to the OS
    # preference, and never sends the value to the server.
    assert html =~ "sdd:theme"
    assert html =~ "localStorage"
    assert html =~ "prefers-color-scheme"
    assert html =~ "data-theme"
  end

  test "the served document requests no external font, icon, or analytics host", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    for host <- @external_asset_hosts do
      refute html =~ host, "root document must not reference #{host}"
    end
  end

  test "application CSS self-hosts Public Sans and pulls no external font", _ctx do
    css = File.read!("assets/css/app.css")

    # Self-hosted Public Sans served from our own /fonts path.
    assert css =~ "@font-face"
    assert css =~ "/fonts/public-sans/"

    # No Google Fonts (or other external) request.
    for host <- @external_asset_hosts do
      refute css =~ host, "app.css must not reference #{host}"
    end
  end

  test "the approved graphite/teal tokens are defined for light and dark themes", _ctx do
    css = File.read!("assets/css/app.css")

    # Light primary teal and dark canvas prove both token sets exist.
    assert css =~ "#006d77"
    assert css =~ ~s([data-theme="dark"])
    assert css =~ "#101415"
  end
end
