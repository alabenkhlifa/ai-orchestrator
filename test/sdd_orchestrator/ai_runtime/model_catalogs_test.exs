defmodule SddOrchestrator.AIRuntime.ModelCatalogsTest do
  @moduledoc "Task 2 proof for account-scoped live catalog persistence and compatibility."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.ModelCatalogAdapter.RPC
  alias SddOrchestrator.AIRuntime.{ModelCatalogs, ModelCatalogSnapshot, PersonalConnections}
  alias SddOrchestrator.ModelCatalogAdapterDouble

  @now ~U[2026-08-03 12:00:00Z]
  @live_source_version "codex-cli 0.live.17|schema:" <> String.duplicate("7", 64)

  setup do
    personal_ai_connection_fixture()
  end

  describe "authenticated refresh and minimized projection" do
    test "persists account and connection scoped provenance, expiry, models, and efforts",
         context do
      default =
        model_catalog_model(%{
          id: "live-default",
          model: "provider-live-default",
          display_name: "Live Default",
          default: true,
          current: false
        })

      current =
        model_catalog_model(%{
          id: "live-current",
          model: "provider-live-current",
          display_name: "Live Current",
          default: false,
          current: true,
          efforts: ["low", "high"],
          default_reasoning_effort: "low"
        })

      result =
        model_catalog_adapter_result(%{
          retrieved_at: @now,
          models: [default, current],
          source_version: @live_source_version
        })

      assert {:ok, catalog} = refresh(context, result)

      assert catalog.connection_id == context.connection.id
      assert catalog.status == "enumerated"
      assert catalog.provider == "openai_codex"
      assert catalog.expires_at == DateTime.add(@now, 300, :second)

      assert catalog.provenance == %{
               source: "official_client",
               method: "model/list",
               version: @live_source_version,
               retrieved_at: @now
             }

      assert Enum.map(catalog.models, & &1.model) == [
               "provider-live-default",
               "provider-live-current"
             ]

      assert Enum.find(catalog.models, & &1.current).model == "provider-live-current"
      assert Enum.find(catalog.models, & &1.default).model == "provider-live-default"

      assert Enum.map(List.last(catalog.models).supported_reasoning_efforts, fn effort ->
               effort.reasoning_effort
             end) == ["low", "high"]

      snapshot = Repo.one!(ModelCatalogSnapshot)
      assert snapshot.account_id == context.account.id
      assert snapshot.connection_id == context.connection.id

      assert ModelCatalogSnapshot.__schema__(:fields) |> Enum.sort() ==
               [
                 :account_id,
                 :connection_id,
                 :expires_at,
                 :id,
                 :inserted_at,
                 :models,
                 :provider,
                 :retrieved_at,
                 :source,
                 :source_method,
                 :source_version,
                 :status,
                 :updated_at
               ]

      safe_text = inspect(catalog)
      refute safe_text =~ context.connection.worker_profile_ref

      for forbidden <- [
            :account_id,
            :worker_id,
            :worker_profile_ref,
            :provider_email,
            :provider_account_id,
            :provider_workspace_id,
            :plan,
            :plan_detail,
            :credential,
            :raw_error
          ] do
        refute Map.has_key?(catalog, forbidden)
      end
    end

    test "preserves arbitrary live model names and does not infer models from plan-like input",
         context do
      names = ["provider-release-#{System.unique_integer([:positive])}", "private-preview-live"]

      result =
        model_catalog_adapter_result(%{
          retrieved_at: @now,
          models:
            Enum.with_index(names, fn name, index ->
              model_catalog_model(%{
                id: "model-#{index}",
                model: name,
                display_name: "Live #{index}",
                default: index == 0
              })
            end)
        })

      assert {:ok, catalog} = refresh(context, result)
      assert Enum.map(catalog.models, & &1.model) == names

      assert {:error, :invalid_response} =
               refresh(context, Map.put(result, :plan, "pro"))

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0

      assert {:error, :unknown} =
               ModelCatalogs.current_catalog(context.account, context.connection.id)
    end

    test "requires current account ownership and an eligible active connection", context do
      result = model_catalog_adapter_result(%{retrieved_at: @now})

      assert {:error, :not_found} =
               ModelCatalogs.current_catalog(account_fixture(), context.connection.id, now: @now)

      assert {:ok, requested} =
               PersonalConnections.request_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoking} =
               ModelCatalogs.refresh(context.account, requested.id,
                 adapter: ModelCatalogAdapterDouble,
                 adapter_result: {:ok, result},
                 notify: self(),
                 now: @now
               )

      refute_received {:catalog_fetch, _, _}
      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
    end
  end

  describe "compatible effort selection and fail-closed reads" do
    test "admits only a proven model and supported effort", context do
      result =
        model_catalog_adapter_result(%{
          retrieved_at: @now,
          models: [
            model_catalog_model(%{
              model: "live-compatible",
              efforts: ["minimal", "high"],
              default_reasoning_effort: "high"
            })
          ]
        })

      assert {:ok, catalog} = refresh(context, result)

      assert {:ok, selection} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "live-compatible",
                 "minimal",
                 now: @now
               )

      assert selection.snapshot_id == catalog.snapshot_id
      assert selection.model == "live-compatible"
      assert selection.effort == "minimal"

      assert {:error, :unknown_compatibility} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "unproven-model",
                 "minimal",
                 now: @now
               )

      assert {:error, :unknown_compatibility} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "live-compatible",
                 "unproven-effort",
                 now: @now
               )

      assert {:ok, _requested} =
               PersonalConnections.request_revocation(context.account, context.connection.id,
                 at: @now
               )

      assert {:error, :revoking} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "live-compatible",
                 "minimal",
                 now: @now
               )

      assert {:error, :invalid_selection} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 " live-compatible ",
                 "minimal",
                 now: @now
               )
    end

    test "accepts only one proven current or default model when enumeration is unsupported",
         context do
      limited_model =
        model_catalog_model(%{
          model: "worker-proven-current",
          current: true,
          default: false,
          efforts: ["medium"],
          default_reasoning_effort: "medium"
        })

      limited =
        model_catalog_adapter_result(%{
          status: "enumeration_unsupported",
          retrieved_at: @now,
          models: [limited_model]
        })

      assert {:ok, catalog} = refresh(context, limited)
      assert catalog.status == "enumeration_unsupported"
      assert Enum.map(catalog.models, & &1.model) == ["worker-proven-current"]

      assert {:ok, _selection} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "worker-proven-current",
                 "medium",
                 now: @now
               )

      unproven = %{limited_model | current: false, default: false}
      assert {:error, :invalid_response} = refresh(context, %{limited | models: [unproven]})

      assert {:error, :invalid_response} =
               refresh(context, %{limited | models: [limited_model, limited_model]})
    end

    test "refuses stale adapter data and expired current snapshots", context do
      stale_time = DateTime.add(@now, -301, :second)
      stale_result = model_catalog_adapter_result(%{retrieved_at: stale_time})

      assert {:error, :stale} = refresh(context, stale_result)
      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0

      current_result = model_catalog_adapter_result(%{retrieved_at: @now})
      assert {:ok, _catalog} = refresh(context, current_result)

      assert {:error, :stale} =
               ModelCatalogs.current_catalog(context.account, context.connection.id,
                 now: DateTime.add(@now, 300, :second)
               )

      assert {:error, :stale} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "codex-test-model",
                 "medium",
                 now: DateTime.add(@now, 301, :second)
               )
    end

    test "a failed refresh invalidates the prior catalog and its selection evidence", context do
      valid = model_catalog_adapter_result(%{retrieved_at: @now})

      failures = [
        {{:ok, Map.put(valid, :provider_account_id, "provider-account-123")}, :invalid_response},
        {{:error, :incompatible}, :incompatible},
        {{:error, :enumeration_unsupported}, :enumeration_unsupported}
      ]

      for {adapter_result, expected_reason} <- failures do
        assert {:ok, _catalog} = refresh(context, valid)

        assert {:error, ^expected_reason} =
                 ModelCatalogs.refresh(context.account, context.connection.id,
                   adapter: ModelCatalogAdapterDouble,
                   adapter_result: adapter_result,
                   now: @now,
                   ttl_seconds: 300
                 )

        assert {:error, :unknown} =
                 ModelCatalogs.current_catalog(context.account, context.connection.id, now: @now)

        assert {:error, :unknown} =
                 ModelCatalogs.validate_selection(
                   context.account,
                   context.connection.id,
                   "codex-test-model",
                   "medium",
                   now: @now
                 )
      end
    end

    test "revalidates stored provenance before projection or selection", context do
      assert {:ok, _catalog} =
               refresh(context, model_catalog_adapter_result(%{retrieved_at: @now}))

      Repo.update_all(ModelCatalogSnapshot, set: [source_method: "provider-account-123"])

      assert {:error, :unknown} =
               ModelCatalogs.current_catalog(context.account, context.connection.id, now: @now)

      assert {:error, :unknown} =
               ModelCatalogs.validate_selection(
                 context.account,
                 context.connection.id,
                 "codex-test-model",
                 "medium",
                 now: @now
               )
    end
  end

  describe "strict adapter and RPC validation" do
    test "rejects malformed, oversized, duplicate, and unsafe adapter output", context do
      safe = model_catalog_adapter_result(%{retrieved_at: @now})
      model = hd(safe.models)
      oversized = %{model | display_name: String.duplicate("x", 201)}
      duplicate_effort = hd(model.supported_reasoning_efforts)

      invalid_results = [
        Map.put(safe, :provider_email, "provider@example.test"),
        %{safe | provider: "other"},
        %{safe | source: "provider_api"},
        %{safe | source_method: "provider-account/lookup"},
        %{safe | source_version: "worker-reported-version"},
        %{safe | source_version: String.duplicate("x", 201)},
        %{safe | models: [oversized]},
        %{
          safe
          | models: [%{model | display_name: "provider@example.test"}]
        },
        %{
          safe
          | models: [%{model | display_name: "Bearer worker-secret"}]
        },
        %{
          safe
          | models: [%{model | id: context.connection.worker_profile_ref}]
        },
        %{safe | models: [Map.put(model, :plan, "pro")]},
        %{
          safe
          | models: [
              %{
                model
                | supported_reasoning_efforts: [duplicate_effort, duplicate_effort]
              }
            ]
        },
        %{safe | models: Enum.map(1..101, fn index -> unique_model(index) end)},
        %{
          safe
          | models:
              Enum.map(1..100, fn index ->
                model = unique_model(index)

                %{
                  model
                  | supported_reasoning_efforts:
                      Enum.map(1..16, fn effort ->
                        %{
                          reasoning_effort: "effort-#{effort}",
                          description: String.duplicate("x", 500)
                        }
                      end),
                    default_reasoning_effort: "effort-1"
                }
              end)
        }
      ]

      for result <- invalid_results do
        assert {:error, :invalid_response} = refresh(context, result)
      end

      assert Repo.aggregate(ModelCatalogSnapshot, :count) == 0
    end

    test "the production RPC sends the exact catalog/1 request and validates its result",
         context do
      connection = Repo.preload(context.connection, :worker)
      result = model_catalog_adapter_result(%{retrieved_at: @now})

      string_result =
        result
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, normalized} =
               RPC.fetch(context.account, connection,
                 rpc: ModelCatalogAdapterDouble,
                 rpc_result: {:ok, string_result},
                 notify: self()
               )

      assert normalized.models |> hd() |> Map.fetch!(:model) == "codex-test-model"

      assert_received {:catalog_rpc_request, account_id, workspace_id, worker_id, "catalog/1",
                       params}

      assert account_id == context.account.id
      assert workspace_id == context.worker.device_workspace_id
      assert worker_id == context.worker.id

      assert params == %{
               "operation" => "refresh",
               "connection_ref" => context.connection.worker_profile_ref,
               "provider" => "openai_codex"
             }

      refute Map.has_key?(normalized, :connection_ref)
      refute inspect(normalized) =~ context.connection.worker_profile_ref

      assert {:error, :invalid_response} =
               RPC.fetch(context.account, connection,
                 rpc: ModelCatalogAdapterDouble,
                 rpc_result: {:ok, Map.put(string_result, "plan", "pro")}
               )
    end

    test "the deterministic adapter reports the exact authorized connection", context do
      result = model_catalog_adapter_result(%{retrieved_at: @now})

      assert {:ok, _catalog} =
               ModelCatalogs.refresh(context.account, context.connection.id,
                 adapter: ModelCatalogAdapterDouble,
                 adapter_result: {:ok, result},
                 notify: self(),
                 now: @now
               )

      assert_received {:catalog_fetch, account, connection}
      assert account.id == context.account.id
      assert connection.id == context.connection.id
      assert connection.worker.id == context.worker.id
    end
  end

  defp refresh(context, result) do
    ModelCatalogs.refresh(context.account, context.connection.id,
      adapter: ModelCatalogAdapterDouble,
      adapter_result: {:ok, result},
      now: @now,
      ttl_seconds: 300
    )
  end

  defp unique_model(index) do
    model_catalog_model(%{
      id: "catalog-#{index}",
      model: "provider-model-#{index}",
      display_name: "Provider Model #{index}",
      default: index == 1
    })
  end
end
