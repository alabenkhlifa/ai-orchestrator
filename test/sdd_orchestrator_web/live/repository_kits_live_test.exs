defmodule SddOrchestratorWeb.RepositoryKitsLiveTest do
  @moduledoc "Focused read-only package inspection UI proof (Task 1, AC-02)."

  use SddOrchestratorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SddOrchestrator.RepositoryKitFixtures

  test "requires an authenticated account", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/repository-kits")
  end

  test "shows an empty state when no package is published", %{conn: conn} do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})

    {:ok, view, _html} = live(conn, ~p"/repository-kits")

    assert has_element?(view, ~s([data-screen="repository-kits"]))
    assert has_element?(view, "[data-empty-state]")
    refute has_element?(view, "[data-package-list]")
  end

  test "lists a published package's source, publisher, version, and digest prefix", %{
    conn: conn
  } do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})
    package = publish_package_fixture()

    {:ok, view, _html} = live(conn, ~p"/repository-kits")

    refute has_element?(view, "[data-empty-state]")
    assert has_element?(view, ~s([data-package-row][data-package-id="#{package.id}"]))
    assert has_element?(view, "[data-row-field=source]", package.source)
    assert has_element?(view, "[data-row-field=publisher]", package.publisher)
    assert has_element?(view, "[data-row-field=license]", package.license)
    assert has_element?(view, "[data-row-field=digest]", String.slice(package.digest, 0, 12))
    assert has_element?(view, "li", "v#{package.version}")
  end

  test "selecting a package reveals every AC-02 detail field", %{conn: conn} do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})
    package = publish_package_fixture()

    {:ok, view, _html} = live(conn, ~p"/repository-kits")

    refute has_element?(view, "[data-package-detail]")

    render_click(view, "select_package", %{"id" => package.id})

    assert has_element?(view, "[data-package-detail]")
    assert has_element?(view, "[data-detail=source]", package.source)
    assert has_element?(view, "[data-detail=publisher]", package.publisher)
    assert has_element?(view, "[data-detail=version]", package.version)
    assert has_element?(view, "[data-detail=digest]", package.digest)
    assert has_element?(view, "[data-detail=license]", package.license)
    assert has_element?(view, "[data-provenance=ref_type]", package.provenance["ref_type"])
    assert has_element?(view, "[data-provenance=ref]", package.provenance["ref"])
    assert has_element?(view, "[data-provenance=repository]", package.provenance["repository"])

    for adapter <- package.supported_adapters do
      assert has_element?(view, "[data-detail=supported_adapters]", adapter)
    end

    for permission <- package.required_permissions do
      assert has_element?(view, "[data-detail=required_permissions]", permission)
    end

    for script <- package.scripts do
      assert has_element?(view, "[data-detail=scripts]", script)
    end

    for file <- package.file_manifest["files"] do
      assert has_element?(view, ~s([data-manifest-file][data-path="#{file["path"]}"]))
    end

    assert has_element?(
             view,
             "[data-detail=inserted_at]",
             DateTime.to_iso8601(package.inserted_at)
           )
  end

  test "shows the supersession badge only on the superseded version", %{conn: conn} do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})

    older =
      publish_package_fixture(%{source: "sup", publisher: "pub", version: "1.0.0", scripts: []}, [
        %{path: "SKILL.md", content: "# sup v1.0.0\n", executable: false}
      ])

    newer =
      publish_package_fixture(%{source: "sup", publisher: "pub", version: "1.1.0", scripts: []}, [
        %{path: "SKILL.md", content: "# sup v1.1.0\n", executable: false}
      ])

    {:ok, view, _html} = live(conn, ~p"/repository-kits")

    older_row = element(view, ~s([data-package-row][data-package-id="#{older.id}"]))
    newer_row = element(view, ~s([data-package-row][data-package-id="#{newer.id}"]))

    assert render(older_row) =~ "data-superseded"
    assert render(older_row) =~ "Superseded by v1.1.0"
    refute render(newer_row) =~ "data-superseded"
  end
end
