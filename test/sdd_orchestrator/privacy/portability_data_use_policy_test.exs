defmodule SddOrchestrator.Privacy.PortabilityDataUsePolicyTest do
  @moduledoc """
  Task 24 proof that portability operation data has no secondary-use or agent path.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Privacy.PortabilityDataUsePolicy, as: Policy
  alias SddOrchestrator.Privacy.ProcessingInventory

  @prohibited_purposes [
    :analytics,
    :advertising,
    :identity_tracking,
    :model_training,
    :unrelated_product_improvement
  ]

  @prohibited_consumers [:coding_agent, :model_provider]

  @source_paths Path.wildcard("lib/sdd_orchestrator/portability/*.ex") ++
                  [
                    "lib/sdd_orchestrator_web/live/project_backup_live.ex",
                    "lib/sdd_orchestrator_web/live/project_restore_live.ex"
                  ]

  test "permits only explicit service, security, lifecycle, and rights routes" do
    assert :ok = Policy.authorize(:project_package, :backup_generation, :authorized_user)
    assert :ok = Policy.authorize(:project_package, :restore_commit, :selected_destination)

    assert :ok =
             Policy.authorize(
               :hosted_local_repository_binding,
               :repository_routing,
               :authorized_device_worker
             )

    assert :ok =
             Policy.authorize(
               :operational_security_log,
               :security_operations,
               :approved_operations
             )

    assert {:error, :not_authorized} =
             Policy.authorize(:project_package, :backup_generation, :approved_operations)

    assert {:error, :not_authorized} =
             Policy.authorize(:unknown_data, :backup_generation, :authorized_user)
  end

  test "rejects every prohibited purpose for every portability data class" do
    for data_class <- Policy.data_classes(),
        purpose <- @prohibited_purposes do
      assert {:error, :secondary_use_prohibited} =
               Policy.authorize(data_class, purpose, :approved_operations)
    end
  end

  test "rejects coding agents and model providers even for approved service purposes" do
    for consumer <- @prohibited_consumers do
      assert {:error, :consumer_prohibited} =
               Policy.authorize(:project_package, :restore_validation, consumer)

      assert {:error, :consumer_prohibited} =
               Policy.authorize(
                 :hosted_local_repository_binding,
                 :repository_routing,
                 consumer
               )
    end
  end

  test "keeps analytics disabled and defines the minimum future anonymous boundary" do
    refute ProcessingInventory.analytics?()

    assert Policy.anonymous_aggregate_boundary() == %{
             current_processing: :prohibited,
             future_requirement: :aggregate_and_genuinely_anonymous,
             prohibited_identifiers: [
               :user,
               :device,
               :workspace,
               :project,
               :repository,
               :package,
               :content,
               :network,
               :stable_pseudonymous_identifier
             ]
           }
  end

  test "inventory covers package and temporary restore data without a secondary recipient" do
    activities = [
      :project_package,
      :import_attempt,
      :restore_operation,
      :package_provenance,
      :hosted_local_repository_binding,
      :operational_security_log
    ]

    for activity <- activities do
      record = Enum.find(ProcessingInventory.records(), &(&1.activity == activity))
      contract = inspect(record) |> String.downcase()

      refute record == nil
      refute record.purpose =~ "analytics"
      refute record.purpose =~ "advertising"
      refute record.purpose =~ "model training"
      refute contract =~ "coding agent processor"
      refute contract =~ "model provider processor"
    end
  end

  test "portability code has no telemetry, analytics, cache, agent, or model dependency" do
    dependencies =
      @source_paths
      |> Enum.flat_map(&source_dependencies/1)
      |> Enum.uniq()

    refute Enum.any?(
             dependencies,
             &Regex.match?(
               ~r/(Analytics|Telemetry|Cache|CodingAgent|ModelProvider|OpenAI|Anthropic)/,
               &1
             )
           )
  end

  test "encrypted package content is absent from indexes and analytics-like tables" do
    %{rows: indexes} =
      Repo.query!("""
      SELECT indexdef
      FROM pg_indexes
      WHERE tablename IN (
        'import_attempts',
        'package_provenances',
        'hosted_local_repository_bindings'
      )
      """)

    index_text = indexes |> List.flatten() |> Enum.join(" ") |> String.downcase()
    refute index_text =~ "encrypted_package"

    %{rows: tables} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public'
      """)

    table_text = tables |> List.flatten() |> Enum.join(" ") |> String.downcase()
    refute Regex.match?(~r/portability.*(analytic|telemetry|tracking|cache)/, table_text)
  end

  defp source_dependencies(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, dependencies} =
      Macro.prewalk(ast, [], fn
        {:alias, _meta, [{:__aliases__, _alias_meta, parts}]} = node, acc ->
          {node, [Module.concat(parts) |> Atom.to_string() | acc]}

        {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, _function]}, _call_meta, _arguments} =
            node,
        acc ->
          {node, [Module.concat(parts) |> Atom.to_string() | acc]}

        node, acc ->
          {node, acc}
      end)

    dependencies
  end
end
