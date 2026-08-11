defmodule SddOrchestrator.RepositoryInitialization.SupportDispatchTest do
  @moduledoc """
  Task 2 proof (AC-02): the read-only initialization-support turn negotiates
  only `plan_discovery` and is structurally refused a `staging_write`
  manifest, mirroring `initialization_dispatch_test.exs`'s pattern. It also
  proves the account-scoped pin/dispatch round trip against
  `AgentAdapterDouble`, and that a turn is skipped (never raised) whenever no
  signed-in account or no eligible connection is available.

  Task 3 proof (AC-04): `provider_preview/1` reports what a turn would use
  without ever pinning a runtime session or dispatching anything — proved
  directly by asserting no `AIRuntimeSession` row exists and no dispatch
  double request was recorded after each call.
  """
  use SddOrchestrator.DataCase, async: false

  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.AgentAdapterDouble, as: Double
  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.Delivery.InitializationDispatch
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.SupportDispatch

  setup do
    restore = Double.install()
    on_exit(restore)
    :ok
  end

  describe "negotiated_grants/0" do
    test "is exactly plan_discovery, never staging_write" do
      assert SupportDispatch.negotiated_grants() == ["plan_discovery"]
    end
  end

  describe "capability-grant denial (AC-02)" do
    test "a staging_write manifest is refused on the support-conversation code path" do
      attrs = %{
        "manifest_version" => 1,
        "device_workspace_id" => Ecto.UUID.generate(),
        "dispatch_id" => SddOrchestrator.Delivery.WorkerProtocol.generate_id(),
        "capability_grant" => "staging_write",
        "agent_ref" => %{"provider_ref" => "openai_codex", "model_ref" => "codex-test-model"},
        "instructions" => %{"kind" => "plan_discovery_turn"}
      }

      assert {:error, :capability_grant_denied} =
               InitializationDispatch.dispatch(attrs, SupportDispatch.negotiated_grants())

      assert Double.requests() == []
    end
  end

  describe "dispatch_turn/3" do
    test "skips without raising when no account is signed in" do
      plan = plan_fixture()

      assert {:skip, :no_account} = SupportDispatch.dispatch_turn(plan, nil)
      assert Double.requests() == []
    end

    test "skips when the account has no eligible personal AI connection" do
      account = SddOrchestrator.AccountsFixtures.account_fixture()
      plan = plan_fixture()

      assert {:skip, :no_eligible_connection} = SupportDispatch.dispatch_turn(plan, account)
      assert Double.requests() == []
    end

    test "a successful plan_discovery round trip against AgentAdapterDouble returns a typed response" do
      context = runtime_session_context_fixture(%{now: DateTime.utc_now()})
      plan = plan_fixture()

      Double.script(%{
        events: [
          Double.progress_event(%{"payload" => %{"summary" => "What are you building?"}})
        ]
      })

      assert {:ok, %{text: text, dispatch_id: dispatch_id}} =
               SupportDispatch.dispatch_turn(plan, context.account)

      assert text == "What are you building?"
      assert SddOrchestrator.Delivery.WorkerProtocol.valid_id?(dispatch_id)

      assert [%{agent_input: agent_input}] = Double.requests()
      assert agent_input["device_workspace_id"] == plan.device_workspace_id
      assert agent_input["capability_grant"] == "plan_discovery"
      assert agent_input["instructions"]["current_field"] == "purpose"
      refute Map.has_key?(agent_input, "working_directory")
    end

    test "the dispatched manifest has no field a real target path could ever be carried in" do
      # `dispatch_turn/3` only ever receives the plan (which has no path
      # field at all — see the opaque-path proof in
      # `RepositoryInitializationTest`) and the account, so there is no
      # argument through which a real selected-folder path could reach a
      # manifest. This proves the manifest's own shape carries that
      # structural guarantee forward: `agent_ref` and `instructions` are
      # exactly the small allowlisted keys this module builds — nothing an
      # answer or the caller supplies can add another field.
      context = runtime_session_context_fixture(%{now: DateTime.utc_now()})
      plan = plan_fixture()
      {:ok, plan} = RepositoryInitialization.answer_field(plan, "purpose", "A CLI tool")

      assert {:ok, _result} = SupportDispatch.dispatch_turn(plan, context.account)

      assert [%{agent_input: agent_input}] = Double.requests()
      assert Map.keys(agent_input["agent_ref"]) |> Enum.sort() == ["model_ref", "provider_ref"]

      assert Map.keys(agent_input["instructions"]) |> Enum.sort() == [
               "answers",
               "current_field",
               "kind",
               "latest_answer"
             ]
    end

    test "falls back to :skip (never raises) when pinning needs a spending ceiling that was not supplied" do
      context =
        runtime_session_context_fixture(%{
          authentication_mode: "api_key",
          label: "API Key Codex",
          worker_profile_ref: "profile-api-key",
          now: DateTime.utc_now()
        })

      plan = plan_fixture()

      assert {:skip, :spending_ceiling_required} =
               SupportDispatch.dispatch_turn(plan, context.account)

      assert Double.requests() == []
    end
  end

  describe "provider_preview/1" do
    test "skips without raising when no account is signed in" do
      assert {:skip, :no_account} = SupportDispatch.provider_preview(nil)
      assert Double.requests() == []
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "skips when the account has no eligible personal AI connection" do
      account = SddOrchestrator.AccountsFixtures.account_fixture()

      assert {:skip, :no_eligible_connection} = SupportDispatch.provider_preview(account)
      assert Double.requests() == []
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end

    test "reports the provider and model dispatch_turn/3 would use, without pinning a session" do
      context = runtime_session_context_fixture(%{now: DateTime.utc_now()})

      assert {:ok, %{provider: provider, model: model}} =
               SupportDispatch.provider_preview(context.account)

      assert provider == "openai_codex"
      assert model == "codex-test-model"

      assert Double.requests() == []
      assert Repo.aggregate(AIRuntimeSession, :count) == 0
    end
  end

  defp plan_fixture do
    {:ok, plan} =
      RepositoryInitialization.create_plan(%{
        device_workspace_id: Ecto.UUID.generate(),
        target_reference: SddOrchestrator.Delivery.WorkerProtocol.generate_id(),
        eligibility: "empty_directory"
      })

    plan
  end
end
