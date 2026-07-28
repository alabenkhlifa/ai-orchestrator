defmodule SddOrchestratorWeb.ProjectBackupLiveTest do
  @moduledoc """
  Task 6 proof for authorized hosted and device backup creation, explicit package
  scope, recovery-passphrase confirmation, loss acknowledgement, direct encrypted
  download delivery, actionable failure, cancellation, and access boundaries.
  """

  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SddOrchestrator.AccountsFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.Portability.PackageEncryption
  alias SddOrchestrator.ProjectsFixtures
  alias SddOrchestrator.SpecificationFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    :ok
  end

  describe "hosted backup" do
    setup %{conn: conn} do
      %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
      workspace = ProjectsFixtures.workspace_fixture(account)
      project = ProjectsFixtures.registered_project(workspace, name: "Roadmap")

      %{conn: conn, workspace: workspace, project: project}
    end

    test "shows the exact included and excluded scope without sharing or copy claims", %{
      conn: conn,
      project: project
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}/backup")

      assert has_element?(view, ~s([data-screen="project-backup"]))

      assert has_element?(
               view,
               "[data-included-categories] li",
               "Project identity and display name"
             )

      assert has_element?(view, "[data-included-categories] li", "Canonical repository identity")
      assert has_element?(view, "[data-included-categories] li", "Current specifications")

      assert html =~ "requirements.md"
      assert html =~ "design.md"
      assert html =~ "tasks.md"
      assert html =~ "History"
      assert html =~ "agent runs"
      assert html =~ "generated artifacts"
      assert html =~ "comments"
      assert html =~ "attachments"
      assert html =~ "logs"
      assert html =~ "repository source"
      refute html =~ "share this backup"
      refute html =~ "create a copy"
    end

    test "requires matching passphrases and the unrecoverable-loss acknowledgement", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/backup")

      html =
        view
        |> form("#project-backup-form",
          backup: %{
            passphrase: "first recovery phrase",
            passphrase_confirmation: "different recovery phrase"
          }
        )
        |> render_submit()

      assert html =~ "The recovery passphrases don&#39;t match."
      assert html =~ "Confirm that a lost passphrase cannot be recovered."
      assert has_element?(view, "#backup-form-error[role=alert][tabindex='-1']")
      assert_push_event(view, "backup-form-error", %{})
      refute_push_event(view, "backup-download", %{})
    end

    test "delivers an encrypted package that opens only with the submitted passphrase", %{
      conn: conn,
      workspace: workspace,
      project: project
    } do
      SpecificationFixtures.hosted_specification(workspace, project, %{title: "Portability"})
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/backup")
      passphrase = "correct horse battery staple"

      html =
        view
        |> form("#project-backup-form",
          backup: %{
            passphrase: passphrase,
            passphrase_confirmation: passphrase,
            loss_acknowledged: "true"
          }
        )
        |> render_submit()

      assert html =~ "Your encrypted backup was downloaded."
      refute html =~ passphrase

      assert_push_event view, "backup-download", %{
        contents: contents,
        filename: filename,
        mime_type: "application/octet-stream"
      }

      assert filename == "sdd-project-#{project.id}.sddbackup"
      assert {:ok, encrypted} = Base.decode64(contents)
      refute encrypted =~ project.name
      assert {:ok, package} = PackageEncryption.decrypt(encrypted, passphrase)
      assert package.project.content == %{"id" => project.id, "name" => project.name}

      assert [%{"title" => "Portability"}] =
               Enum.map(package.specifications.content, &Map.take(&1, ["title"]))
    end

    test "returns an actionable generation failure without emitting a download", %{
      conn: conn,
      workspace: workspace,
      project: project
    } do
      SpecificationFixtures.hosted_specification(workspace, project, %{
        documents: %{
          requirements: "api_key=abcdefghijklmnopqrstuvwxyz123456",
          design: "# Design",
          tasks: "# Tasks"
        }
      })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/backup")

      html =
        view
        |> form("#project-backup-form",
          backup: %{
            passphrase: "one safe recovery phrase",
            passphrase_confirmation: "one safe recovery phrase",
            loss_acknowledged: "true"
          }
        )
        |> render_submit()

      assert html =~ "We couldn&#39;t create this backup."
      assert html =~ "current specifications don&#39;t contain credentials"
      assert_push_event(view, "backup-form-error", %{})
      refute_push_event(view, "backup-download", %{})
    end

    test "cancel returns to the same project and the dashboard links back to backup", %{
      conn: conn,
      project: project
    } do
      {:ok, dashboard, _html} = live(conn, ~p"/projects/#{project.id}")

      assert has_element?(
               dashboard,
               "[data-backup-project][href='/projects/#{project.id}/backup']"
             )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/backup")

      assert {:error, {:live_redirect, %{to: "/projects/" <> id}}} =
               view |> element("main [data-cancel-backup]") |> render_click()

      assert id == project.id
    end

    test "does not render an unknown or another workspace's project", %{
      conn: conn
    } do
      foreign_account = AccountsFixtures.account_fixture()
      foreign_workspace = ProjectsFixtures.workspace_fixture(foreign_account)
      foreign_project = ProjectsFixtures.registered_project(foreign_workspace, name: "Foreign")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{foreign_project.id}/backup")

      assert {:error, {:live_redirect, %{to: "/projects"}}} =
               live(conn, ~p"/projects/#{Ecto.UUID.generate()}/backup")
    end
  end

  describe "device backup" do
    test "creates an encrypted device-authoritative package without requiring an account", %{
      conn: conn
    } do
      {:ok, project} =
        Devices.register_project(%{
          name: "Local ledger",
          repository_fingerprint: "fp-local-ledger",
          status: "connected"
        })

      {:ok, dashboard, _html} = live(conn, ~p"/local/projects/#{project.id}")

      assert has_element?(
               dashboard,
               "[data-backup-project][href='/local/projects/#{project.id}/backup']"
             )

      {:ok, view, _html} = live(conn, ~p"/local/projects/#{project.id}/backup")
      passphrase = "device recovery phrase"

      view
      |> form("#project-backup-form",
        backup: %{
          passphrase: passphrase,
          passphrase_confirmation: passphrase,
          loss_acknowledged: "true"
        }
      )
      |> render_submit()

      assert_push_event view, "backup-download", %{
        contents: contents,
        filename: "sdd-project-" <> _id,
        mime_type: "application/octet-stream"
      }

      assert {:ok, encrypted} = Base.decode64(contents)
      assert {:ok, package} = PackageEncryption.decrypt(encrypted, passphrase)
      assert package.project.content["id"] == project.id

      assert package.repository.content == %{
               "provider" => "local",
               "repository_id" => "fp-local-ledger"
             }
    end

    test "routes a missing device project back to local onboarding", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/onboarding/local"}}} =
               live(conn, ~p"/local/projects/#{Ecto.UUID.generate()}/backup")
    end
  end

  test "hosted backup requires an authenticated session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/projects/#{Ecto.UUID.generate()}/backup")
  end

  defp store_path do
    dir = Path.join(System.tmp_dir!(), "sdd_backup_live_#{System.unique_integer([:positive])}")
    Path.join(dir, "store.dets")
  end
end
