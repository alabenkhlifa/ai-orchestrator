defmodule SddOrchestrator.Privacy.AIRuntimePrivacyReviewTest do
  @moduledoc """
  Task 6 consolidated privacy and security review for the AI-runtime slice.

  Owns AC-15. With the connection, catalog, quota, configuration, cost-ledger,
  usage, observation, log, cache, backup, deletion, and rights paths inspected
  together, credentials stay on the user's own device, access stays
  purpose-limited and least-privilege, retention is enforced, provider data is
  minimized, and no product analytics or secondary use exists.

  This file reviews the contracts and boundaries the slice's tasks established
  across each other. It deliberately does not re-prove any single task's
  internal behaviour; those proofs live with the tasks that own them.
  """
  use SddOrchestrator.DataCase, async: true

  import ExUnit.CaptureLog
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AIRuntime.CodexAppServer
  alias SddOrchestrator.AIRuntime.CodexAppServer.Compatibility
  alias SddOrchestrator.AIRuntime.PersonalConnectionRevocations
  alias SddOrchestrator.AIRuntime.RuntimeCosts.PriceSnapshot
  alias SddOrchestrator.AIRuntime.RuntimeProjections
  alias SddOrchestrator.AIRuntime.SecurityLog

  alias SddOrchestrator.AIRuntime.{
    AgentRuntimeObservation,
    AIRuntimeSession,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    QuotaSnapshot,
    RuntimeCostLedger
  }

  alias SddOrchestrator.Privacy.AIRuntimeDataUsePolicy, as: Policy

  alias SddOrchestrator.Privacy.{
    DataProcessingRecord,
    DeploymentPrivacyProfile,
    ProcessingInventory,
    Retention,
    RetentionPruner,
    Rights
  }

  # The six persisted AI-runtime entities plus the content-free operational log.
  @record_classes [
    :personal_ai_connection,
    :ai_model_catalog,
    :ai_quota_snapshot,
    :ai_runtime_session,
    :ai_runtime_cost_ledger,
    :agent_runtime_observation
  ]

  @governed_classes @record_classes ++ [:ai_runtime_operational_log]

  @entities [
    {:personal_ai_connection, PersonalAIConnection},
    {:model_catalog_snapshot, ModelCatalogSnapshot},
    {:quota_snapshot, QuotaSnapshot},
    {:ai_runtime_session, AIRuntimeSession},
    {:runtime_cost_ledger, RuntimeCostLedger},
    {:agent_runtime_observation, AgentRuntimeObservation}
  ]

  @ai_runtime_tables ~w(
    personal_ai_connections model_catalog_snapshots quota_snapshots
    ai_runtime_sessions runtime_cost_ledgers agent_runtime_observations
  )

  # Columns whose names read as credential-shaped but hold no credential: the
  # revocation lifecycle's own counter, timestamp, typed reason, and typed
  # result, and the consumption counters and bounded request limits.
  @non_credential_columns ~w(
    credential_removal_attempts credential_removal_attempted_at
    credential_removal_failure_reason credential_removal_result
    token_activity max_input_tokens max_output_tokens
    input_tokens output_tokens total_tokens tokens_source
  )a

  @credential_shaped_name ~r/credential|token|api_?key|password|secret|authorization|cookie|bearer/i

  # Credential material as it actually appears, not as a detection rule: a real
  # key or token literal, a PEM block, or a literal assigned to a secret name.
  @credential_literal ~r/sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{16,}|-----BEGIN|Bearer\s+[A-Za-z0-9._-]{8,}/
  @credential_assignment ~r/(api_?key|secret|password|token|credential)"?\s*(=>|:|=)\s*"[^"\n]{8,}"/i

  @analytics_shaped ~r/analytic|telemetry|tracking|metric|cache/i

  @app_server_sources [
    "lib/sdd_orchestrator/ai_runtime/codex_app_server.ex",
    "lib/sdd_orchestrator/ai_runtime/codex_app_server/compatibility.ex",
    "lib/sdd_orchestrator/ai_runtime/codex_app_server/process.ex"
  ]

  @web_sources [
    "lib/sdd_orchestrator_web/channels/personal_ai_worker_socket.ex",
    "lib/sdd_orchestrator_web/channels/personal_ai_worker_channel.ex",
    "lib/sdd_orchestrator_web/live/ai_connections_live.ex"
  ]

  @named_sources [
    "lib/sdd_orchestrator/ai_runtime/personal_worker_rpc.ex",
    "lib/sdd_orchestrator/ai_runtime/personal_worker_protocol.ex",
    "lib/sdd_orchestrator/ai_runtime/personal_connections.ex",
    "lib/sdd_orchestrator/ai_runtime/personal_connection_revocations.ex",
    "lib/sdd_orchestrator/ai_runtime/model_catalogs.ex",
    "lib/sdd_orchestrator/ai_runtime/quotas.ex",
    "lib/sdd_orchestrator/ai_runtime/quota_policy.ex",
    "lib/sdd_orchestrator/ai_runtime/runtime_sessions.ex",
    "lib/sdd_orchestrator/ai_runtime/runtime_costs.ex",
    "lib/sdd_orchestrator/ai_runtime/runtime_costs/price_snapshot.ex",
    "lib/sdd_orchestrator/ai_runtime/runtime_observations.ex",
    "lib/sdd_orchestrator/ai_runtime/runtime_projections.ex",
    "lib/sdd_orchestrator/ai_runtime/security_log.ex"
  ]

  @provider_contacting [:personal_ai_connection, :ai_model_catalog, :ai_quota_snapshot]

  describe "cross-task data flow" do
    test "records every AI-runtime processing activity with a complete contract" do
      records = inventory()

      for activity <- @governed_classes do
        assert %DataProcessingRecord{} = record = Map.fetch!(records, activity)
        assert record.purpose not in [nil, ""]
        assert record.lawful_basis in DataProcessingRecord.lawful_bases()
        assert record.personal_data != []
        assert record.access not in [nil, ""]
        assert record.retention not in [nil, ""]
        assert record.rights not in [nil, ""]
        assert record.processors != []
        assert record.transfers not in [nil, ""]
        assert record.review not in [nil, ""]
      end

      # The governed vocabulary is one vocabulary: the fail-closed policy and
      # the inventory cannot drift apart and leave a class governed by neither.
      assert Enum.sort(Policy.data_classes()) == Enum.sort(@governed_classes)
    end

    test "names one necessity purpose for every persisted field of the six entities" do
      purposes = ProcessingInventory.ai_runtime_field_purposes()

      assert Enum.sort(Map.keys(purposes)) ==
               @entities |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      for {entity, schema} <- @entities do
        assert Enum.sort(Map.keys(Map.fetch!(purposes, entity))) ==
                 Enum.sort(schema.__schema__(:fields)),
               "#{entity} has a persisted field with no recorded purpose"
      end

      for {_entity, fields} <- purposes, {_field, purpose} <- fields do
        assert is_binary(purpose) and String.trim(purpose) != ""
      end
    end
  end

  describe "credential locality" do
    test "keeps every AI-runtime schema free of a column that could hold a credential" do
      for {entity, schema} <- @entities,
          field <- schema.__schema__(:fields),
          field not in @non_credential_columns do
        refute Regex.match?(@credential_shaped_name, Atom.to_string(field)),
               "#{entity}.#{field} is a credential-shaped column"
      end

      # The documented exceptions must still exist, so the exception list can
      # never quietly become a way to skip a newly added column.
      for field <- @non_credential_columns do
        assert Enum.any?(@entities, fn {_entity, schema} ->
                 field in schema.__schema__(:fields)
               end),
               "documented exception #{field} is no longer a persisted field"
      end

      assert :worker_profile_ref in PersonalAIConnection.__schema__(:redact_fields)
    end

    test "carries no credential material in any AI-runtime source under review" do
      sources = reviewed_sources()

      for named <- @named_sources ++ @app_server_sources ++ @web_sources do
        assert named in sources, "the review no longer covers #{named}"
      end

      for path <- sources, {line, number} <- Enum.with_index(read_lines(path), 1) do
        refute Regex.match?(@credential_literal, line),
               "#{path}:#{number} carries credential-shaped material"

        refute Regex.match?(@credential_assignment, line),
               "#{path}:#{number} assigns a literal to a credential-named key"
      end
    end
  end

  describe "app server boundary" do
    test "fails closed on an unconfigured registry, a foreign transport, and a bad binding" do
      digest = String.duplicate("a", 64)

      # An empty registry admits nothing, which is what an unconfigured
      # deployment has: no adapter starts and no process is spawned.
      assert Compatibility.verify("0.test.0", digest, %{}) == {:error, :unsupported_version}

      assert Compatibility.verify("0.test.0", digest, %{"0.test.1" => [digest]}) ==
               {:error, :unsupported_version}

      assert Compatibility.verify("0.test.0", "not-a-digest", %{"0.test.0" => ["not-a-digest"]}) ==
               {:error, :unsupported_schema_digest}

      # Not vacuous: an explicitly registered pair is admitted.
      assert Compatibility.verify("0.test.0", digest, %{"0.test.0" => [digest]}) == :ok

      assert CodexAppServer.start_link(
               worker_profile_ref: "profile-review",
               codex_version: "0.test.0",
               schema_digest: digest
             ) == {:error, :unsupported_version}

      assert CodexAppServer.start_link(
               worker_profile_ref: "profile-review",
               transport: :websocket,
               codex_version: "0.test.0",
               schema_digest: digest
             ) == {:error, :unsupported_transport}

      assert CodexAppServer.start_link(
               worker_profile_ref: nil,
               codex_version: "0.test.0",
               schema_digest: digest
             ) == {:error, :invalid_request}
    end

    test "admits only the documented account and discovery methods" do
      assert CodexAppServer.request_methods() == [
               "account/login/start",
               "account/login/cancel",
               "account/rateLimits/read",
               "account/read",
               "account/usage/read",
               "model/list"
             ]

      assert CodexAppServer.notification_methods() == [
               "account/login/completed",
               "account/rateLimits/updated",
               "thread/tokenUsage/updated"
             ]

      for method <- CodexAppServer.request_methods() ++ CodexAppServer.notification_methods() do
        refute Regex.match?(~r/prompt|completion|content|message|exec|shell|file/i, method),
               "#{method} would reach conversation or filesystem content"

        refute String.contains?(method, "*")
      end
    end

    test "refuses malformed input and an absent process without leaking raw provider text" do
      absent = :sdd_orchestrator_ai_runtime_review_absent_app_server

      assert CodexAppServer.login_api_key(absent, 123) == {:error, :invalid_request}
      assert CodexAppServer.cancel_login(absent, 123) == {:error, :invalid_request}
      refute CodexAppServer.binding_matches?(absent, "")
      assert CodexAppServer.request(absent, "model/list") == {:error, :process_unavailable}
      assert CodexAppServer.compatibility(absent) == {:error, :process_unavailable}

      # Raw App Server errors, stderr, and credential-shaped payloads are
      # normalized to typed atoms; the adapter has no way to print them.
      source = Enum.map_join(@app_server_sources, "\n", &File.read!/1)
      refute source =~ "Logger."
      refute source =~ "inspect("
      assert source =~ ":credential_content"
      assert source =~ ":app_server_error"
    end
  end

  describe "price source safety" do
    test "refuses every reservation when no official price registry is configured" do
      # The deployment's real price source is release-gated evidence, so the
      # implemented default must make an unconfigured deployment refuse rather
      # than treat a model as free.
      assert Application.get_env(:sdd_orchestrator, :official_price_snapshots) == nil

      assert PriceSnapshot.current("codex-test-model", ~U[2026-08-05 12:00:00Z]) ==
               {:error, :missing_price}

      assert PriceSnapshot.current("codex-test-model", ~U[2026-08-05 12:00:00Z], snapshots: %{}) ==
               {:error, :missing_price}
    end

    test "fails closed on an unknown, unpublished, or expired registration" do
      snapshots = review_price_snapshots()

      assert {:ok, price} =
               PriceSnapshot.current("codex-test-model", ~U[2026-08-05 12:00:00Z],
                 snapshots: snapshots
               )

      assert price.currency == "USD"

      assert PriceSnapshot.current("unregistered-model", ~U[2026-08-05 12:00:00Z],
               snapshots: snapshots
             ) == {:error, :missing_price}

      assert PriceSnapshot.current("codex-test-model", ~U[2026-07-01 00:00:00Z],
               snapshots: snapshots
             ) == {:error, :missing_price}

      assert PriceSnapshot.current("codex-test-model", ~U[2026-09-02 00:00:00Z],
               snapshots: snapshots
             ) == {:error, :stale_price}
    end
  end

  describe "access, purpose limitation, and least privilege" do
    test "refuses every prohibited purpose and every prohibited recipient" do
      for data_class <- Policy.data_classes(), purpose <- Policy.prohibited_purposes() do
        assert Policy.authorize(data_class, purpose, :connection_owner) ==
                 {:error, :secondary_use_prohibited},
               "#{data_class} permits #{purpose}"
      end

      for data_class <- Policy.data_classes(),
          {purpose, _consumers} <- Policy.allowed_routes()[data_class],
          consumer <- Policy.prohibited_consumers() do
        assert Policy.authorize(data_class, purpose, consumer) == {:error, :consumer_prohibited},
               "#{data_class} permits #{consumer} under #{purpose}"
      end
    end

    test "gives operations and rights personnel only a lifecycle and a rights route" do
      for data_class <- @record_classes,
          {purpose, consumers} <- Policy.allowed_routes()[data_class],
          consumer <- consumers do
        case consumer do
          :approved_operations ->
            assert purpose == :retention_cleanup,
                   "#{data_class} reaches approved operations under #{purpose}"

          :verified_rights_operator ->
            assert purpose == :verified_rights,
                   "#{data_class} reaches a rights operator under #{purpose}"

          _service_route ->
            :ok
        end
      end
    end

    test "never routes account-wide allowance or spend to a project participant" do
      purposes =
        Policy.allowed_routes()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      for data_class <- [:ai_quota_snapshot, :ai_runtime_cost_ledger], purpose <- purposes do
        assert Policy.authorize(data_class, purpose, :current_project_participant) ==
                 {:error, :not_authorized},
               "#{data_class} reaches a participant under #{purpose}"
      end

      # Not vacuous: the approved service, worker, lifecycle, and rights routes
      # still authorize, so the boundary refuses by rule and not by silence.
      assert Policy.authorize(:personal_ai_connection, :credential_locality, :authorized_worker) ==
               :ok

      assert Policy.authorize(:ai_model_catalog, :catalog_selection, :connection_owner) == :ok
      assert Policy.authorize(:ai_quota_snapshot, :retention_cleanup, :approved_operations) == :ok

      assert Policy.authorize(
               :agent_runtime_observation,
               :participant_run_visibility,
               :current_project_participant
             ) == :ok

      assert Policy.authorize(
               :ai_runtime_cost_ledger,
               :verified_rights,
               :verified_rights_operator
             ) == :ok
    end
  end

  describe "owner and participant access" do
    test "keeps account-wide allowance, spend, and connection facts owner-only" do
      owner = MapSet.new(RuntimeProjections.owner_keys())
      participant = MapSet.new(RuntimeProjections.participant_keys())

      assert MapSet.subset?(participant, owner)
      assert MapSet.size(participant) < MapSet.size(owner)

      # The owner set is the richer one, so excluding these from the
      # participant set is a real narrowing rather than a shared minimum.
      for key <- [:quota, :spend, :consumer, :consumer_ref, :provider, :authentication_mode] do
        assert MapSet.member?(owner, key)
      end

      exposed =
        RuntimeProjections.participant_keys() ++ RuntimeProjections.participant_observation_keys()

      for key <- exposed do
        refute Regex.match?(
                 ~r/quota|credit|spend|ceiling|cost|reserv|connection|consumer|provenance|price/i,
                 Atom.to_string(key)
               ),
               "the participant projection exposes #{key}"
      end
    end
  end

  describe "lifecycle and retention" do
    test "runs the five AI-runtime sweeps under pairwise-distinct advisory locks" do
      keys = [
        RetentionPruner.advisory_lock_key(),
        PersonalConnectionRevocations.advisory_lock_key(),
        Retention.snapshot_advisory_lock_key(),
        Retention.runtime_advisory_lock_key(),
        Retention.observation_advisory_lock_key()
      ]

      assert length(Enum.uniq(keys)) == length(keys)
      assert Enum.all?(keys, &(is_integer(&1) and &1 > 0))

      counts = Retention.prune_all(~U[2026-08-05 12:00:00Z])

      for category <- [
            :acknowledged_personal_ai_connections,
            :revoked_personal_ai_connections,
            :expired_model_catalog_snapshots,
            :expired_quota_snapshots,
            :expired_ai_runtime_sessions,
            :expired_runtime_cost_ledgers,
            :expired_agent_runtime_observations
          ] do
        assert Map.has_key?(counts, category), "the pruner does not report #{category}"
        assert counts[category] == 0
      end
    end

    test "records the approved catalog, quota, session, ledger, and observation windows" do
      records = inventory()

      for activity <- [:ai_model_catalog, :ai_quota_snapshot] do
        assert records[activity].retention =~ "Expires on the stored short lifetime"
        assert records[activity].retention =~ "terminally revoked or scheduled for deletion"
      end

      assert records.ai_runtime_session.retention =~ "Pruned 90 days after the pin"
      assert records.ai_runtime_session.retention =~ "30 days after connection removal"
      assert records.ai_runtime_cost_ledger.retention =~ "Cascades with its runtime session"
      assert records.ai_runtime_cost_ledger.retention =~ "90-day attached and 30-day detached"

      assert records.agent_runtime_observation.retention =~
               "Pruned 30 days after the observation time"

      assert records.ai_runtime_operational_log.retention == "Deleted after 30 days."

      for activity <- @record_classes do
        assert records[activity].retention =~ "encrypted backup copies expire within 35 days",
               "#{activity} does not name the encrypted backup expiry"
      end
    end
  end

  describe "rights coverage" do
    test "exports the six entities and refuses correction of the immutable records" do
      context = runtime_observation_context_fixture()
      observation = runtime_observation_fixture(context)

      assert {:ok, export} = Rights.export_account(context.account.id)

      for key <- [
            :personal_ai_connections,
            :model_catalog_snapshots,
            :quota_snapshots,
            :ai_runtime_sessions,
            :runtime_cost_ledgers,
            :agent_runtime_observations
          ] do
        assert is_list(Map.fetch!(export, key)), "the export omits #{key}"
      end

      assert length(export.personal_ai_connections) == 1
      assert length(export.ai_runtime_sessions) == 1
      assert length(export.agent_runtime_observations) == 1

      assert {:ok, pinned} =
               Rights.assess_runtime_session_request(
                 context.account,
                 context.session.session_id,
                 :correction
               )

      assert pinned.disposition == :refused_immutable_accountability_evidence

      assert {:ok, observed} =
               Rights.assess_runtime_observation_request(
                 context.account,
                 observation.observation_id,
                 :correction
               )

      assert observed.disposition == :refused_immutable_operational_record

      for disposition <- [pinned, observed] do
        assert :access in disposition.available_actions
        assert :erasure in disposition.available_actions
        assert disposition.propagation.processors != []
        assert disposition.propagation.derived_records != []

        assert disposition.propagation.encrypted_backups ==
                 DeploymentPrivacyProfile.backup_handoff(:access)
      end

      # A foreign or unknown record is not found rather than disclosed.
      assert Rights.assess_runtime_session_request(
               context.account,
               Ecto.UUID.generate(),
               :correction
             ) == {:error, :not_found}
    end
  end

  describe "logging" do
    test "emits four allowlisted keys, only on failure, from a closed outcome vocabulary" do
      refute capture_log(fn -> SecurityLog.audit(:ok, :session_pin) end) =~
               "[ai_runtime_security]"

      outcomes =
        for {reason, expected} <- [
              {:revoked, "denied"},
              {:paused, "paused"},
              {:worker_unavailable, "unavailable"},
              {:credential_content, "rejected"},
              {%{"api_key" => "sk-live-REVIEWMARKER"}, "failed"}
            ] do
          log =
            capture_log(fn -> SecurityLog.audit({:error, reason}, :app_server_request) end)

          event = decode_event!(log)

          assert Enum.sort(Map.keys(event)) ==
                   ~w(correlation_id event_type occurred_at outcome)

          refute log =~ "REVIEWMARKER"
          refute log =~ "api_key"
          assert event["outcome"] == expected

          event["outcome"]
        end

      assert Enum.sort(outcomes) == ~w(denied failed paused rejected unavailable)

      assert SecurityLog.retention_days() ==
               DeploymentPrivacyProfile.retention_requirements().operational_security_logs_days

      assert SecurityLog.retention_days() == 30

      for event <- SecurityLog.events() do
        refute Regex.match?(~r/prompt|content|label|profile|account_name/i, Atom.to_string(event))
      end

      assert_raise FunctionClauseError, fn ->
        apply(SecurityLog, :audit, [{:error, :revoked}, :prompt_content])
      end
    end
  end

  describe "processor and transfer" do
    test "names the processors and a transfer boundary behind every activity" do
      records = inventory()

      for activity <- @governed_classes do
        record = records[activity]
        assert Enum.all?(record.processors, &(String.trim(&1) != ""))
        assert String.trim(record.transfers) != ""
      end

      for activity <- @record_classes do
        assert Enum.any?(records[activity].processors, &String.contains?(&1, "Hosting database"))
      end
    end

    test "treats the provider as an independent controller reached only by the local client" do
      records = inventory()

      for activity <- @provider_contacting do
        processors = Enum.join(records[activity].processors, " ")

        assert processors =~ "OpenAI (independent controller of its own platform;"
        assert processors =~ "contacted only by the user's worker-local official client)"
        assert processors =~ "Authorized device worker under the operating-system boundary"

        assert records[activity].transfers =~
                 "No credential or provider identity is transferred to the control plane"
      end
    end
  end

  describe "cache and backup" do
    test "declares no cache or analytics-shaped storage for any AI-runtime table" do
      migrations =
        "priv/repo/migrations/*.exs"
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          content = File.read!(path)
          Enum.any?(@ai_runtime_tables, &String.contains?(content, ":" <> &1))
        end)

      assert length(migrations) >= length(@ai_runtime_tables)

      for path <- migrations, {line, number} <- Enum.with_index(read_lines(path), 1) do
        refute Regex.match?(@analytics_shaped, line),
               "#{path}:#{number} declares cache or analytics-shaped storage"
      end

      for table <- @ai_runtime_tables do
        refute Regex.match?(@analytics_shaped, table)
      end
    end

    test "keeps the encrypted backup lifecycle release-gated at 35 days" do
      contract = DeploymentPrivacyProfile.backup_lifecycle_contract()

      assert contract.encrypted == true
      assert contract.maximum_expiry_days == 35
      assert contract.restore_scope == :approved_recovery_only
      assert contract.deletion_propagation == :required
      assert contract.enforcement == :deployment_infrastructure
      assert contract.evidence_stage == :release

      assert DeploymentPrivacyProfile.retention_requirements() == %{
               operational_security_logs_days: 30,
               encrypted_rolling_backups_days: 35
             }
    end
  end

  describe "no analytics and no secondary use" do
    test "declares no analytics processing and no secondary-use purpose" do
      refute ProcessingInventory.analytics?()

      records = inventory()

      for activity <- @governed_classes do
        refute String.contains?(String.downcase(records[activity].purpose), [
                 "analytic",
                 "advertis",
                 "model training"
               ]),
               "#{activity} states a prohibited purpose"
      end

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
            :consumer,
            :content,
            :network,
            :stable_pseudonymous_identifier
          ] do
        assert identifier in boundary.prohibited_identifiers
      end
    end
  end

  describe "release-gate classification" do
    test "keeps unresolved AI-runtime deployment facts in the public release gate" do
      profile = DeploymentPrivacyProfile.new(%{})

      assert {:error, {:incomplete, missing}} =
               DeploymentPrivacyProfile.ensure_backup_release_ready(profile)

      assert :processors in missing
      assert :hosting_regions in missing
      assert :transfer_safeguards in missing
      assert :privacy_notice in missing
      assert :incident_path in missing
      assert :retention_enforcement in missing
      assert :reviews in missing
      assert :encrypted_backup_configuration in missing

      contract = DeploymentPrivacyProfile.backup_lifecycle_contract()
      assert contract.evidence_stage == :release
      assert contract.enforcement == :deployment_infrastructure

      # Release-gated evidence never blocks the implemented contract: the
      # inventory records that stage explicitly rather than leaving it implied.
      records = inventory()

      for activity <- [
            :personal_ai_connection,
            :ai_runtime_session,
            :ai_runtime_cost_ledger,
            :agent_runtime_observation
          ] do
        assert records[activity].review =~ "remain release gates"
      end
    end
  end

  describe "capability contract" do
    test "serves a downstream consumer through the public API alone" do
      # A consumer holds only a data class, a purpose, and a recipient.
      assert {:authorize, 3} in Policy.__info__(:functions)
      assert {:data_classes, 0} in Policy.__info__(:functions)
      assert {:records, 0} in ProcessingInventory.__info__(:functions)

      classes = Policy.data_classes()
      assert Enum.sort(classes) == Enum.sort(@governed_classes)

      records = inventory()

      for data_class <- classes do
        assert %DataProcessingRecord{activity: ^data_class} = Map.fetch!(records, data_class)

        assert Policy.authorize(data_class, :model_training, :connection_owner) ==
                 {:error, :secondary_use_prohibited}
      end

      # An unknown class is refused rather than defaulted to anything.
      assert Policy.authorize(:unknown_class, :runtime_pinning, :connection_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(:ai_runtime_session, :unknown_purpose, :connection_owner) ==
               {:error, :not_authorized}

      assert Policy.authorize(:ai_runtime_session, :runtime_pinning, :unknown_consumer) ==
               {:error, :not_authorized}

      # And a genuine downstream route is served, so the capability is usable.
      assert Policy.authorize(:ai_runtime_session, :runtime_pinning, :working_agent_runtime) ==
               :ok
    end
  end

  defp inventory do
    Map.new(ProcessingInventory.records(), &{&1.activity, &1})
  end

  defp reviewed_sources do
    Path.wildcard("lib/sdd_orchestrator/ai_runtime/**/*.ex") ++ @web_sources
  end

  defp read_lines(path) do
    path |> File.read!() |> String.split("\n")
  end

  defp review_price_snapshots do
    %{
      "review-2026-08-01" => %{
        version: "review-2026-08-01",
        source: "official published price schedule",
        published_at: ~U[2026-08-01 00:00:00Z],
        expires_at: ~U[2026-09-01 00:00:00Z],
        currency: "USD",
        models: %{"codex-test-model" => %{input: "1.25", output: "10.00"}}
      }
    }
  end

  defp decode_event!(log) do
    [json] =
      Regex.run(~r/\[ai_runtime_security\] (\{[^\n]*\})/, log, capture: :all_but_first)

    Jason.decode!(json)
  end
end
