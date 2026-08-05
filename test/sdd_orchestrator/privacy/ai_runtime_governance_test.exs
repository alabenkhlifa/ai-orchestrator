defmodule SddOrchestrator.Privacy.AIRuntimeGovernanceTest do
  @moduledoc """
  Task 15 operational-privacy proof for the AI-runtime slice.

  Covers the active processing inventory and field-purpose map, the
  contract and service-security lawful bases, least-privilege support access,
  the processor and transfer inventory, the structured content-free operational
  log and its 30-day expiry, credential and raw-account redaction, backup
  exclusion and expiry, and the prohibited-use controls: no product analytics,
  no advertising, no model-training, no unrelated improvement, and no secondary
  use — with negative scans over the stored schema.
  """
  use SddOrchestrator.DataCase, async: true

  import ExUnit.CaptureLog

  alias SddOrchestrator.AIRuntime.SecurityLog
  alias SddOrchestrator.AIRuntime.SecurityLog.Event

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    QuotaSnapshot,
    RuntimeCostLedger
  }

  alias SddOrchestrator.Privacy.AIRuntimeDataUsePolicy, as: Policy
  alias SddOrchestrator.Privacy.{DataProcessingRecord, DeploymentPrivacyProfile}
  alias SddOrchestrator.Privacy.ProcessingInventory

  @record_activities [
    :personal_ai_connection,
    :ai_model_catalog,
    :ai_quota_snapshot,
    :ai_runtime_session,
    :ai_runtime_cost_ledger,
    :agent_runtime_observation
  ]

  @new_activities @record_activities ++ [:ai_runtime_operational_log]

  @provider_contacting_activities [
    :personal_ai_connection,
    :ai_model_catalog,
    :ai_quota_snapshot
  ]

  @purpose_vocabulary [
    :catalog_selection,
    :connection_selection,
    :credential_locality,
    :operational_observation,
    :participant_run_visibility,
    :quota_control,
    :reliability_operations,
    :retention_cleanup,
    :runtime_pinning,
    :security_operations,
    :spending_control,
    :verified_rights
  ]

  @prohibited_purposes [
    :advertising,
    :analytics,
    :identity_tracking,
    :model_training,
    :unrelated_product_improvement
  ]

  @prohibited_consumers [
    :advertising_network,
    :analytics_processor,
    :coding_agent,
    :model_provider
  ]

  @ai_runtime_tables ~w(
    personal_ai_connections model_catalog_snapshots quota_snapshots
    ai_runtime_sessions runtime_cost_ledgers agent_runtime_observations
  )

  # Columns whose names match the credential-shaped pattern but hold no
  # credential. The four `credential_removal_*` columns are the revocation
  # lifecycle's own counter, timestamp, typed failure reason, and typed result;
  # the `*token*` columns are consumption counters and bounded request limits,
  # not tokens. Every other column is scanned.
  @credential_lifecycle_columns ~w(
    credential_removal_attempts credential_removal_attempted_at
    credential_removal_failure_reason credential_removal_result
  )

  @token_counter_columns ~w(
    token_activity max_input_tokens max_output_tokens
    input_tokens output_tokens total_tokens tokens_source
  )

  @documented_columns @credential_lifecycle_columns ++ @token_counter_columns

  @credential_shaped ~r/credential|token|api_key|password|secret|email|plan_name|refresh/i

  describe "inventory" do
    test "records every AI-runtime activity with a complete, approved contract" do
      activities = ProcessingInventory.activities()

      for activity <- @new_activities do
        assert activity in activities, "processing inventory is missing #{activity}"
      end

      for record <- new_records() do
        assert record.purpose not in [nil, ""]
        assert record.lawful_basis in DataProcessingRecord.lawful_bases()
        assert is_list(record.personal_data) and record.personal_data != []
        assert record.access not in [nil, ""]
        assert record.retention not in [nil, ""]
        assert record.rights not in [nil, ""]
        assert is_list(record.processors) and record.processors != []
        assert record.transfers not in [nil, ""]
        assert record.review not in [nil, ""]
      end
    end

    test "keeps every access statement least-privilege and agent-free" do
      for record <- new_records(), record.activity in @record_activities do
        access = String.downcase(record.access)

        assert access =~ "coding agents and model providers never receive it",
               "#{record.activity} does not exclude coding agents and model providers"

        assert access =~ "verified rights operator only for a verified rights request"
        assert access =~ "approved operations personnel only for lifecycle enforcement"
      end

      for activity <- [:ai_quota_snapshot, :ai_runtime_cost_ledger] do
        access = activity |> record!() |> Map.fetch!(:access) |> String.downcase()
        assert access =~ "never a project participant"
      end
    end
  end

  describe "purpose" do
    test "names one necessity purpose for every persisted AI-runtime field" do
      purposes = ProcessingInventory.ai_runtime_field_purposes()

      assert Enum.sort(Map.keys(purposes)) ==
               Enum.sort([
                 :personal_ai_connection,
                 :model_catalog_snapshot,
                 :quota_snapshot,
                 :ai_runtime_session,
                 :runtime_cost_ledger,
                 :agent_runtime_observation
               ])

      assert Enum.sort(Map.keys(purposes.personal_ai_connection)) ==
               Enum.sort(PersonalAIConnection.__schema__(:fields))

      assert Enum.sort(Map.keys(purposes.model_catalog_snapshot)) ==
               Enum.sort(ModelCatalogSnapshot.__schema__(:fields))

      assert Enum.sort(Map.keys(purposes.quota_snapshot)) ==
               Enum.sort(QuotaSnapshot.__schema__(:fields))

      assert Enum.sort(Map.keys(purposes.ai_runtime_session)) ==
               Enum.sort(AIRuntimeSession.__schema__(:fields))

      assert Enum.sort(Map.keys(purposes.runtime_cost_ledger)) ==
               Enum.sort(RuntimeCostLedger.__schema__(:fields))

      assert Enum.sort(Map.keys(purposes.agent_runtime_observation)) ==
               Enum.sort(AgentRuntimeObservation.__schema__(:fields))

      for {_entity, fields} <- purposes, {_field, purpose} <- fields do
        assert is_binary(purpose) and String.trim(purpose) != ""
      end
    end
  end

  describe "basis" do
    test "uses contract necessity for the records and service security for the log" do
      for activity <- @record_activities do
        assert record!(activity).lawful_basis == :contract
      end

      assert record!(:ai_runtime_operational_log).lawful_basis == :legitimate_interests

      assert new_records() |> Enum.map(& &1.lawful_basis) |> Enum.uniq() |> Enum.sort() ==
               [:contract, :legitimate_interests]
    end
  end

  describe "support access" do
    test "gives operations and rights personnel no content-reading route" do
      for activity <- @record_activities,
          {purpose, consumers} <- Policy.allowed_routes()[activity],
          consumer <- consumers do
        case consumer do
          :approved_operations ->
            assert purpose == :retention_cleanup,
                   "#{activity} exposes approved operations under #{purpose}"

          :verified_rights_operator ->
            assert purpose == :verified_rights,
                   "#{activity} exposes a rights operator under #{purpose}"

          _other ->
            :ok
        end
      end
    end

    test "scopes participant visibility to the run and never to account-wide spend" do
      for {data_class, routes} <- Policy.allowed_routes(),
          {purpose, consumers} <- routes,
          purpose == :participant_run_visibility do
        assert data_class in [:ai_runtime_session, :agent_runtime_observation]
        assert consumers == [:current_project_participant]
      end

      for data_class <- [:ai_quota_snapshot, :ai_runtime_cost_ledger],
          purpose <- @purpose_vocabulary do
        assert Policy.authorize(data_class, purpose, :current_project_participant) ==
                 {:error, :not_authorized},
               "#{data_class} leaks account-wide allowance or spend under #{purpose}"
      end
    end

    test "keeps credential locality on the authorized worker alone" do
      assert Policy.allowed_routes().personal_ai_connection.credential_locality ==
               [:authorized_worker]

      for {data_class, routes} <- Policy.allowed_routes(),
          data_class != :personal_ai_connection do
        refute Map.has_key?(routes, :credential_locality)
      end
    end
  end

  describe "processor" do
    test "names the processors behind every AI-runtime activity" do
      for record <- new_records() do
        assert Enum.all?(record.processors, &(String.trim(&1) != ""))
      end

      for activity <- @record_activities do
        assert Enum.any?(record!(activity).processors, &String.contains?(&1, "Hosting database"))
      end

      assert record!(:ai_runtime_operational_log).processors == ["Hosting and logging services"]
    end

    test "treats the provider as an independent controller reached only by the local client" do
      for activity <- @provider_contacting_activities do
        processors = Enum.join(record!(activity).processors, " ")

        assert processors =~ "OpenAI (independent controller of its own platform;"
        assert processors =~ "contacted only by the user's worker-local official client)"
        assert processors =~ "Authorized device worker under the operating-system boundary"
      end
    end
  end

  describe "transfer" do
    test "states a transfer boundary for every AI-runtime activity" do
      for record <- new_records() do
        assert String.trim(record.transfers) != ""
      end

      connection = record!(:personal_ai_connection)

      assert connection.transfers =~
               "No credential or provider identity is transferred to the control plane"

      assert connection.transfers =~ "only by the user's own worker-local official client"
    end
  end

  describe "structured log" do
    test "emits one closed, allowlisted event shape" do
      entry = %Event{
        event_type: :session_pin,
        occurred_at: "2026-01-01T00:00:00Z",
        outcome: :failed,
        correlation_id: Ecto.UUID.generate()
      }

      assert entry |> Map.from_struct() |> Map.keys() |> Enum.sort() ==
               [:correlation_id, :event_type, :occurred_at, :outcome]

      log = capture_log(fn -> SecurityLog.audit({:error, :not_found}, :connection_link) end)

      assert Enum.sort(Map.keys(decode_event!(log))) ==
               ~w(correlation_id event_type occurred_at outcome)

      assert :worker_rpc_request in SecurityLog.events()

      # Dispatched through `apply/3` so the refusal is proven at run time
      # rather than turned into a compile-time type warning.
      assert_raise FunctionClauseError, fn ->
        apply(SecurityLog, :audit, [{:error, :not_found}, :prompt_content])
      end
    end
  end

  describe "expiry" do
    test "expires operational log lines after the deployment-enforced 30 days" do
      assert SecurityLog.retention_days() == 30

      assert SecurityLog.retention_days() ==
               DeploymentPrivacyProfile.retention_requirements().operational_security_logs_days

      assert record!(:ai_runtime_operational_log).retention == "Deleted after 30 days."
    end
  end

  describe "redaction" do
    test "never writes credential-shaped content into a log line" do
      reason = %{"api_key" => "sk-live-SECRETMARKER", "access_token" => "tok-SECRETMARKER"}

      log =
        capture_log(fn ->
          assert SecurityLog.audit({:error, reason}, :credential_removal) ==
                   {:error, reason}
        end)

      assert log =~ "[ai_runtime_security]"
      assert log =~ ~s("outcome":"failed")
      refute log =~ "SECRETMARKER"
      refute log =~ "api_key"
      refute log =~ "access_token"
    end

    test "never writes a provider email or raw provider account into a log line" do
      reason = {:provider_account, "acct-RAWACCOUNTMARKER", "person@example.test"}

      log =
        capture_log(fn ->
          assert SecurityLog.audit({:error, reason}, :connection_link) == {:error, reason}
        end)

      assert log =~ "[ai_runtime_security]"
      assert log =~ ~s("outcome":"failed")
      refute log =~ "RAWACCOUNTMARKER"
      refute log =~ "person@example.test"
    end

    test "never writes prompt or completion content into a log line" do
      reason = {:rejected_prompt, "PROMPTMARKER summarize the private design document"}

      log =
        capture_log(fn ->
          assert SecurityLog.audit({:error, reason}, :observation_append) == {:error, reason}
        end)

      refute log =~ "PROMPTMARKER"
      refute log =~ "private design document"

      assert Enum.sort(Map.keys(decode_event!(log))) ==
               ~w(correlation_id event_type occurred_at outcome)
    end

    test "a success emits no line at all and returns the result unchanged" do
      # Contamination note: `capture_log` is global, so this asserts that no
      # AI-runtime security line is emitted rather than that no other async
      # test logged anything.
      plain = capture_log(fn -> assert SecurityLog.audit(:ok, :session_pin) == :ok end)
      refute plain =~ "[ai_runtime_security]"

      success = {:ok, %{secret: "SUCCESSMARKER"}}
      tagged = capture_log(fn -> assert SecurityLog.audit(success, :quota_refresh) == success end)
      refute tagged =~ "[ai_runtime_security]"
      refute tagged =~ "SUCCESSMARKER"
    end

    test "redacts the worker-local profile reference at rest" do
      assert :worker_profile_ref in PersonalAIConnection.__schema__(:redact_fields)
    end
  end

  describe "backup" do
    test "keeps AI-runtime records inside the encrypted 35-day backup lifecycle" do
      contract = DeploymentPrivacyProfile.backup_lifecycle_contract()

      assert contract.encrypted == true
      assert contract.maximum_expiry_days == 35
      assert contract.deletion_propagation == :required

      for activity <- @record_activities do
        assert record!(activity).retention =~ "encrypted backup copies expire within 35 days",
               "#{activity} does not name the encrypted backup expiry"
      end
    end
  end

  describe "prohibited use" do
    test "declares no analytics activity and refuses every analytics route" do
      refute ProcessingInventory.analytics?()

      for record <- new_records() do
        refute String.contains?(String.downcase(record.purpose), [
                 "analytic",
                 "advertis",
                 "model training"
               ])
      end

      for data_class <- Policy.data_classes() do
        assert Policy.authorize(data_class, :analytics, :approved_operations) ==
                 {:error, :secondary_use_prohibited}
      end
    end

    test "refuses advertising, model training, unrelated improvement, and identity tracking" do
      for data_class <- Policy.data_classes(), purpose <- @prohibited_purposes do
        assert Policy.authorize(data_class, purpose, :approved_operations) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} permits #{purpose}"

        assert Policy.authorize(data_class, purpose, :connection_owner) ==
                 {:error, :secondary_use_prohibited}
      end

      assert Enum.sort(Policy.prohibited_purposes()) == Enum.sort(@prohibited_purposes)
    end

    test "refuses every prohibited recipient and every unlisted route while staying usable" do
      for data_class <- Policy.data_classes(),
          {purpose, _consumers} <- Policy.allowed_routes()[data_class],
          consumer <- @prohibited_consumers do
        assert Policy.authorize(data_class, purpose, consumer) ==
                 {:error, :consumer_prohibited},
               "#{data_class} permits #{consumer} under #{purpose}"
      end

      assert Enum.sort(Policy.prohibited_consumers()) == Enum.sort(@prohibited_consumers)

      assert Policy.authorize(:ai_runtime_session, :spending_control, :connection_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(:unknown_class, :runtime_pinning, :connection_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(
               :personal_ai_connection,
               :connection_selection,
               :approved_operations
             ) ==
               {:error, :not_authorized}

      # Not vacuous: the approved service routes still authorize.
      assert Policy.authorize(:personal_ai_connection, :connection_selection, :connection_owner) ==
               :ok

      assert Policy.authorize(:personal_ai_connection, :credential_locality, :authorized_worker) ==
               :ok

      assert Policy.authorize(
               :agent_runtime_observation,
               :participant_run_visibility,
               :current_project_participant
             ) == :ok

      assert Policy.authorize(
               :ai_runtime_operational_log,
               :security_operations,
               :approved_operations
             ) ==
               :ok

      assert Enum.sort(Policy.data_classes()) == Enum.sort(@new_activities)

      boundary = Policy.anonymous_aggregate_boundary()
      assert boundary.current_processing == :prohibited
      assert boundary.future_requirement == :aggregate_and_genuinely_anonymous

      for identifier <- [
            :user,
            :device,
            :workspace,
            :project,
            :connection,
            :worker_profile,
            :session,
            :content,
            :network,
            :stable_pseudonymous_identifier
          ] do
        assert identifier in boundary.prohibited_identifiers
      end
    end
  end

  describe "negative scan" do
    test "no AI-runtime column, index, or table name carries credential or analytics content" do
      {:ok, %{rows: column_rows}} =
        Repo.query(
          """
          SELECT table_name, column_name
          FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = ANY($1)
          """,
          [@ai_runtime_tables]
        )

      scanned_tables = column_rows |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()
      assert scanned_tables == Enum.sort(@ai_runtime_tables)

      columns = Enum.map(column_rows, fn [_table, column] -> column end)

      for column <- @documented_columns do
        assert column in columns, "documented exception #{column} is no longer in the schema"
      end

      for column <- columns, column not in @documented_columns do
        refute Regex.match?(@credential_shaped, column),
               "unexpected credential-shaped column: #{column}"
      end

      # The two textual credential-lifecycle columns hold a fixed vocabulary,
      # so the documented exception cannot become a free-text credential sink.
      assert PersonalAIConnection.credential_removal_results() == ~w(removed absent)

      assert PersonalAIConnection.credential_removal_failure_reasons() ==
               ~w(worker_unavailable timeout incompatible invalid_request invalid_response)

      {:ok, %{rows: index_rows}} =
        Repo.query("SELECT indexname FROM pg_indexes WHERE tablename = ANY($1)", [
          @ai_runtime_tables
        ])

      index_names = List.flatten(index_rows)
      assert index_names != []

      for index <- index_names do
        refute Regex.match?(~r/analytic|metric|telemetry|tracking|cache/i, index),
               "unexpected analytics-like index: #{index}"
      end

      for table <- @ai_runtime_tables do
        refute Regex.match?(~r/analytic|metric|telemetry|tracking/i, table)
      end
    end

    test "the purpose map itself names no credential, secret, or filesystem detail" do
      # The map's keys are the schemas' own column names, four of which are named
      # for the worker-local removal lifecycle, so the minimization scan covers
      # the descriptive purposes rather than the column identifiers.
      minimized =
        ProcessingInventory.ai_runtime_field_purposes()
        |> Map.values()
        |> Enum.flat_map(&Map.values/1)
        |> Enum.join(" ")
        |> String.downcase()

      refute minimized =~ "credential"
      refute minimized =~ "api key"
      refute minimized =~ "password"
      refute minimized =~ "provider email"
      refute minimized =~ "plan name"
      refute minimized =~ "path"
      refute minimized =~ "/"
    end
  end

  defp new_records do
    Enum.filter(ProcessingInventory.records(), &(&1.activity in @new_activities))
  end

  defp record!(activity) do
    Enum.find(ProcessingInventory.records(), &(&1.activity == activity)) ||
      flunk("processing inventory is missing #{activity}")
  end

  defp decode_event!(log) do
    [json] =
      Regex.run(~r/\[ai_runtime_security\] (\{[^\n]*\})/, log, capture: :all_but_first)

    Jason.decode!(json)
  end
end
