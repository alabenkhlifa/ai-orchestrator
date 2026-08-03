defmodule SddOrchestratorWeb.AIConnectionsLiveTest do
  @moduledoc "Focused Task 9 proof for the account-level AI Connections workflow."

  use SddOrchestratorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.{ModelCatalogs, PersonalConnections, PersonalWorkerRPC}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.ProjectsFixtures

  setup do
    path = store_path()
    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    start_supervised!({Local, path: path})
    :ok
  end

  test "requires an authenticated account", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/ai-connections")
  end

  test "shows missing-worker guidance and unknown catalog and quota facts", %{conn: conn} do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})

    {:ok, view, html} = live(conn, ~p"/ai-connections")

    assert has_element?(view, ~s([data-screen="ai-connections"]))
    assert has_element?(view, ~s([data-worker-guidance="missing"]))
    assert has_element?(view, "[data-recheck-workers]")
    assert has_element?(view, ~s([data-setup-local-worker][href="/onboarding/local"]))
    assert has_element?(view, "#connection-worker[disabled]")
    assert has_element?(view, "[data-catalog-panel]")
    assert has_element?(view, "[data-quota-panel]")
    assert html =~ "currently unavailable"
    assert html =~ "currently unknown"
    refute html =~ ~s(type="password")
    refute html =~ "worker_profile_ref"
  end

  test "rechecks worker readiness without discarding the label or authentication mode", %{
    conn: conn
  } do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    {:ok, view, _html} = live(conn, ~p"/ai-connections")
    assert has_element?(view, ~s([data-worker-guidance="unavailable"]))

    render_change(view, "change_connection", %{
      "connection" => %{
        label: "Preserved label",
        worker_id: "",
        authentication_mode: "api_key"
      }
    })

    start_responder(workspace.id, worker)
    view |> element("[data-recheck-workers]") |> render_click()

    assert has_element?(view, "[data-link-connection]:not([disabled])")
    assert has_element?(view, ~s(#connection-label[value="Preserved label"]))
    assert has_element?(view, ~s(input[value="api_key"][checked]))
    assert has_element?(view, ~s(option[value="local-worker-1"][selected]))
  end

  test "classifies paired workers from the live personal AI RPC contract without rendering ids",
       %{
         conn: conn
       } do
    %{conn: conn} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    unavailable = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})
    incompatible = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})
    ready = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    start_responder(workspace.id, incompatible,
      protocol_version: "personal-ai/0",
      capabilities: ["connection/1"]
    )

    start_responder(workspace.id, ready)

    {:ok, view, html} = live(conn, ~p"/ai-connections")

    assert has_element?(view, "[data-worker-list] li", "Local worker")
    assert html =~ "Ready"
    assert html =~ "Unavailable"
    assert html =~ "Needs update"
    refute html =~ unavailable.id
    refute html =~ incompatible.id
    refute html =~ ready.id
  end

  test "links multiple labelled ChatGPT and API-key connections with pending and completed handoffs",
       %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})
    start_responder(workspace.id, worker, delay_ms: 40)

    {:ok, view, _html} = live(conn, ~p"/ai-connections")

    pending =
      view
      |> form("#ai-connection-form",
        connection: %{
          label: "Personal ChatGPT",
          worker_id: "local-worker-1",
          authentication_mode: "chatgpt"
        }
      )
      |> render_submit()

    assert pending =~ "Waiting for the local worker"
    assert render_async(view, 1_000) =~ "ChatGPT sign-in completed in the local worker"

    view
    |> form("#ai-connection-form",
      connection: %{
        label: "Personal API",
        worker_id: "local-worker-1",
        authentication_mode: "api_key"
      }
    )
    |> render_submit()

    html = render_async(view, 1_000)
    assert html =~ "API-key entry stayed in the local worker"
    assert html =~ "Personal ChatGPT"
    assert html =~ "Personal API"
    assert length(PersonalConnections.list_connections(account)) == 2
    refute html =~ ~s(type="password")
    refute html =~ ~s(name="api_key")
    refute html =~ "profile-e2e"
  end

  test "shows duplicate-label and typed worker failures without raw adapter output", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})
    start_responder(workspace.id, worker)
    personal_ai_connection_fixture(%{account: account, worker: worker, label: "Duplicate"})

    {:ok, view, _html} = live(conn, ~p"/ai-connections")

    view
    |> form("#ai-connection-form",
      connection: %{
        label: "duplicate",
        worker_id: "local-worker-1",
        authentication_mode: "chatgpt"
      }
    )
    |> render_submit()

    assert render_async(view, 1_000) =~ "That label is already in use"

    stop_responder(workspace.id, worker.id)
    {:ok, view, _html} = live(conn, ~p"/ai-connections")
    assert has_element?(view, ~s([data-worker-guidance="unavailable"]))

    html =
      render_submit(view, "link", %{
        "connection" => %{
          label: "Offline",
          worker_id: worker.id,
          authentication_mode: "chatgpt"
        }
      })

    assert html =~ "selected local worker is unavailable"
    refute html =~ worker.id
    refute html =~ "raw provider"
  end

  test "renames and requests revocation through account-scoped inline controls", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: first} =
      personal_ai_connection_fixture(%{account: account, worker: worker, label: "First"})

    personal_ai_connection_fixture(%{
      account: account,
      worker: worker,
      label: "Already used",
      worker_profile_ref: "another-worker-profile"
    })

    {:ok, view, _html} = live(conn, ~p"/ai-connections")

    view
    |> element("#connection-#{first.id} [data-rename-connection]")
    |> render_click()

    assert has_element?(view, "#rename-input-#{first.id}")

    view
    |> form("#rename-form-#{first.id}", rename: %{label: "Renamed connection"})
    |> render_submit()

    assert has_element?(
             view,
             "#connection-#{first.id} [data-connection-label]",
             "Renamed connection"
           )

    assert has_element?(view, "#connection-#{first.id} [data-rename-result]")

    view
    |> element("#connection-#{first.id} [data-rename-connection]")
    |> render_click()

    html =
      view
      |> form("#rename-form-#{first.id}", rename: %{label: "already USED"})
      |> render_submit()

    assert html =~ "That label is already in use"
    view |> element("#rename-form-#{first.id} button[phx-click=cancel_rename]") |> render_click()
    refute has_element?(view, "#rename-error")

    view
    |> element("#connection-#{first.id} [data-revoke-connection]")
    |> render_click()

    assert has_element?(view, "#connection-#{first.id} [data-revoke-confirmation]")
    view |> element("#connection-#{first.id} [data-confirm-revoke]") |> render_click()
    assert render_async(view, 1_000) =~ "Revocation requested"

    assert PersonalConnections.get_connection(account, first.id).revocation_state == "requested"
  end

  test "rename rejects malformed labels without raising", %{conn: conn} do
    %{account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: connection} =
      personal_ai_connection_fixture(%{account: account, worker: worker})

    for invalid <- [nil, 42, "   ", String.duplicate("x", 101)] do
      assert {:error, :invalid_label} =
               PersonalConnections.rename_connection(account, connection.id, invalid)
    end

    assert PersonalConnections.get_connection(account, connection.id).label == connection.label
  end

  test "Projects navigation exposes the account-level workflow", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    workspace = ProjectsFixtures.workspace_fixture(account)
    ProjectsFixtures.registered_project(workspace, name: "Navigation project")

    {:ok, view, _html} = live(conn, ~p"/projects")
    assert has_element?(view, ~s([data-ai-connections-link][href="/ai-connections"]))
  end

  test "refreshes and renders only safe authenticated model and effort facts", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: connection} =
      personal_ai_connection_fixture(%{account: account, worker: worker, label: "Live catalog"})

    start_responder(workspace.id, worker,
      catalog_result:
        catalog_result(%{
          models: [
            catalog_model(%{
              model: "provider-live-model",
              display_name: "Provider Live Model",
              current: true,
              default: true,
              efforts: ["minimal", "high"]
            })
          ]
        })
    )

    {:ok, view, html} = live(conn, ~p"/ai-connections")
    assert has_element?(view, "#catalog-#{connection.id} [data-catalog-unknown]")
    refute html =~ "provider-live-model"

    pending =
      view
      |> element("#catalog-#{connection.id} [data-refresh-catalog]")
      |> render_click()

    assert pending =~ "Requesting the live catalog"
    html = render_async(view, 1_000)

    assert html =~ "Provider Live Model"
    assert html =~ "provider-live-model"
    assert has_element?(view, ~s([data-catalog-model][data-model="provider-live-model"]))
    assert has_element?(view, ~s([data-effort="minimal"]))
    assert has_element?(view, ~s([data-effort="high"]))
    assert has_element?(view, "[data-catalog-provenance]", "Official client")
    assert has_element?(view, ~s([data-catalog-result="ok"]))

    forbidden = [
      connection.worker_profile_ref,
      "provider@example.test",
      "provider-account-123",
      "provider-workspace-456",
      "premium-plan",
      "raw provider failure",
      "secret-credential"
    ]

    for value <- forbidden, do: refute(html =~ value)
  end

  test "clears a previously rendered catalog when a later refresh is malformed", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: connection} =
      personal_ai_connection_fixture(%{account: account, worker: worker})

    valid =
      catalog_result(%{
        models: [
          catalog_model(%{
            model: "catalog-must-disappear",
            display_name: "Catalog Must Disappear"
          })
        ]
      })

    malformed = Map.put(valid, "provider_account_id", "provider-account-123")
    start_responder(workspace.id, worker, catalog_results: [valid, malformed])

    {:ok, view, _html} = live(conn, ~p"/ai-connections")

    view |> element("#catalog-#{connection.id} [data-refresh-catalog]") |> render_click()
    assert render_async(view, 1_000) =~ "Catalog Must Disappear"

    pending =
      view
      |> element("#catalog-#{connection.id} [data-refresh-catalog]")
      |> render_click()

    assert pending =~ "Requesting the live catalog"
    refute pending =~ "Catalog Must Disappear"

    html = render_async(view, 1_000)
    assert has_element?(view, ~s([data-catalog-result="error"]))
    refute html =~ "Catalog Must Disappear"
    refute html =~ "catalog-must-disappear"
    refute html =~ "provider-account-123"

    assert {:error, :unknown} =
             ModelCatalogs.current_catalog(account, connection.id)
  end

  test "shows only the proven current model for an enumeration-unsupported catalog", %{
    conn: conn
  } do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: connection} =
      personal_ai_connection_fixture(%{account: account, worker: worker})

    start_responder(workspace.id, worker,
      catalog_result:
        catalog_result(%{
          status: "enumeration_unsupported",
          models: [
            catalog_model(%{
              model: "worker-proven-current",
              display_name: "Worker Proven Current",
              current: true,
              default: false,
              efforts: ["medium"]
            })
          ]
        })
    )

    {:ok, view, _html} = live(conn, ~p"/ai-connections")
    view |> element("#catalog-#{connection.id} [data-refresh-catalog]") |> render_click()
    html = render_async(view, 1_000)

    assert has_element?(view, "#catalog-#{connection.id} [data-catalog-limited]")
    assert html =~ "Worker Proven Current"
    assert html =~ "medium"
    refute html =~ "guessed"
  end

  test "fails safely on malformed catalog output and marks expired snapshots stale", %{conn: conn} do
    %{conn: conn, account: account} = register_and_log_in_account(%{conn: conn})
    {:ok, workspace} = Devices.establish_workspace()
    worker = personal_ai_worker_fixture(%{device_workspace_id: workspace.id})

    %{connection: malformed_connection} =
      personal_ai_connection_fixture(%{account: account, worker: worker, label: "Malformed"})

    stale_time = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.truncate(:second)

    %{connection: stale_connection} =
      model_catalog_snapshot_fixture(%{
        account: account,
        worker: worker,
        label: "Expired",
        worker_profile_ref: "expired-profile",
        now: stale_time,
        ttl_seconds: 300
      })

    start_responder(workspace.id, worker,
      catalog_result: Map.put(catalog_result(), "provider_email", "provider@example.test")
    )

    {:ok, view, _html} = live(conn, ~p"/ai-connections")
    assert has_element?(view, "#catalog-#{stale_connection.id} [data-catalog-stale]")

    view
    |> element("#catalog-#{malformed_connection.id} [data-refresh-catalog]")
    |> render_click()

    html = render_async(view, 1_000)
    assert has_element?(view, ~s([data-catalog-result="error"]))
    assert html =~ "could not be refreshed safely"
    refute html =~ "provider@example.test"
    refute html =~ malformed_connection.worker_profile_ref
  end

  defp start_responder(workspace_id, worker, opts \\ []) do
    parent = self()
    ready_ref = make_ref()

    pid =
      spawn(fn ->
        contract = %{
          protocol_version: Keyword.get(opts, :protocol_version, "personal-ai/1"),
          capabilities: Keyword.get(opts, :capabilities, ["catalog/1", "connection/1"])
        }

        result = PersonalWorkerRPC.attach(workspace_id, worker.id, contract)
        send(parent, {ready_ref, result})
        responder_loop(opts, 0)
      end)

    assert_receive {^ready_ref, {:ok, _registry}}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp responder_loop(opts, count) do
    receive do
      {:ai_request, envelope, caller, request_ref, _deadline} ->
        Process.sleep(Keyword.get(opts, :delay_ms, 0))

        result = responder_result(envelope, opts, count)

        send(caller, {PersonalWorkerRPC, request_ref, {:ok, result}})
        responder_loop(opts, count + 1)

      {:cancel_ai_request, _request_id} ->
        responder_loop(opts, count)
    end
  end

  defp responder_result(%{"capability" => "connection/1"} = envelope, _opts, count) do
    authentication_mode = envelope["params"]["authentication_mode"]

    %{
      "worker_profile_ref" => "profile-e2e-#{count + 1}",
      "provider" => "openai_codex",
      "authentication_mode" => authentication_mode,
      "availability" => "available",
      "adapter_compatibility_version" => "connection/1"
    }
  end

  defp responder_result(%{"capability" => "catalog/1"}, opts, count) do
    case Keyword.get(opts, :catalog_results) do
      results when is_list(results) and results != [] ->
        Enum.at(results, count, List.last(results))

      _other ->
        Keyword.get_lazy(opts, :catalog_result, &catalog_result/0)
    end
  end

  defp catalog_result(attrs \\ %{}) do
    %{
      "status" => Map.get(attrs, :status, "enumerated"),
      "provider" => "openai_codex",
      "source" => "official_client",
      "source_method" => "model/list",
      "source_version" => "codex-cli 0.live.0|schema:" <> String.duplicate("9", 64),
      "retrieved_at" =>
        attrs
        |> Map.get_lazy(:retrieved_at, fn -> DateTime.utc_now() end)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601(),
      "models" => Map.get_lazy(attrs, :models, fn -> [catalog_model()] end)
    }
  end

  defp catalog_model(attrs \\ %{}) do
    model = Map.get(attrs, :model, "provider-live-default")
    efforts = Map.get(attrs, :efforts, ["low", "medium", "high"])
    default_effort = if "medium" in efforts, do: "medium", else: hd(efforts)

    %{
      "id" => "catalog-#{model}",
      "model" => model,
      "display_name" => Map.get(attrs, :display_name, "Provider Live Default"),
      "current" => Map.get(attrs, :current, false),
      "default" => Map.get(attrs, :default, true),
      "default_reasoning_effort" => Map.get(attrs, :default_reasoning_effort, default_effort),
      "supported_reasoning_efforts" =>
        Enum.map(efforts, fn effort ->
          %{
            "reasoning_effort" => effort,
            "description" => "Authenticated #{effort} reasoning"
          }
        end)
    }
  end

  defp stop_responder(workspace_id, worker_id) do
    case PersonalWorkerRPC.connection(workspace_id, worker_id) do
      {:ok, pid, _meta} -> Process.exit(pid, :kill)
      :error -> :ok
    end
  end

  defp store_path do
    directory =
      Path.join(System.tmp_dir!(), "ai_connections_live_#{System.unique_integer([:positive])}")

    Path.join(directory, "store.dets")
  end
end
