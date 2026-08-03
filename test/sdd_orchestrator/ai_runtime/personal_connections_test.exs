defmodule SddOrchestrator.AIRuntime.PersonalConnectionsTest do
  @moduledoc "Task 1 proof for minimized account-owned personal AI connections."

  use SddOrchestrator.DataCase, async: true

  import SddOrchestrator.AccountsFixtures
  import SddOrchestrator.AIRuntimeFixtures

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    PersonalAIConnection,
    PersonalConnections
  }

  alias SddOrchestrator.AIRuntime.PersonalConnectionAdapter.RPC
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.PersonalConnectionAdapterDouble

  setup do
    %{account: account_fixture(), worker: personal_ai_worker_fixture()}
  end

  describe "minimized persistence and scoping" do
    test "persists only the approved control-plane fields and hides the opaque profile reference",
         context do
      assert {:ok, connection} = link(context)

      assert PersonalAIConnection.__schema__(:fields) |> Enum.sort() ==
               [
                 :account_id,
                 :adapter_compatibility_version,
                 :authentication_mode,
                 :availability,
                 :id,
                 :inserted_at,
                 :label,
                 :provider,
                 :revocation_acknowledged_at,
                 :revocation_requested_at,
                 :revocation_state,
                 :updated_at,
                 :worker_id,
                 :worker_profile_ref
               ]

      assert PersonalAIConnection.__schema__(:associations) |> Enum.sort() == [:account, :worker]

      forbidden = [
        :credential,
        :credentials,
        :api_key,
        :access_token,
        :refresh_token,
        :provider_email,
        :provider_account_id,
        :provider_workspace_id,
        :plan,
        :plan_detail,
        :raw_error,
        :project_id,
        :run_id
      ]

      for field <- forbidden, do: refute(field in PersonalAIConnection.__schema__(:fields))

      inspected = inspect(connection)
      refute inspected =~ connection.worker_profile_ref
      refute inspected =~ "worker_profile_ref"
    end

    test "trims labels, enforces account-local case-insensitive uniqueness, and allows multiple profiles",
         context do
      assert {:ok, first} = link(context, %{label: "  Work Codex  ", profile: "profile-work"})
      assert first.label == "Work Codex"

      assert {:error, :label_taken} =
               link(context, %{label: "work codex", profile: "profile-other"})

      assert {:ok, second} =
               link(context, %{label: "Personal Codex", profile: "profile-personal"})

      assert second.id != first.id

      assert Enum.map(PersonalConnections.list_connections(context.account), & &1.id) == [
               second.id,
               first.id
             ]
    end

    test "account-scoped list and get never expose another account's record", context do
      assert {:ok, connection} = link(context)
      other = account_fixture()

      assert PersonalConnections.list_connections(other) == []
      assert PersonalConnections.get_connection(other, connection.id) == nil

      assert PersonalConnections.get_connection(context.account, connection.id).id ==
               connection.id
    end

    test "requires freshly loaded active account and active paired worker", context do
      disabled =
        context.account
        |> Account.changeset(%{state: :disabled})
        |> Repo.update!()

      assert {:error, :account_unavailable} = link(%{context | account: disabled})

      active_account = account_fixture()
      assert {:ok, revoked_worker} = Pairing.revoke_worker(context.worker)

      assert {:error, :worker_unavailable} =
               link(%{account: active_account, worker: revoked_worker})

      assert Repo.aggregate(PersonalAIConnection, :count) == 0
    end

    test "repeating the same account worker and profile is idempotent without renaming",
         context do
      assert {:ok, original} = link(context, %{label: "Original", profile: "same-profile"})

      assert {:ok, repeated} =
               link(context, %{label: "Replacement", profile: "same-profile"})

      assert repeated.id == original.id
      assert repeated.label == "Original"
      assert Repo.aggregate(PersonalAIConnection, :count) == 1
    end

    test "repeating a profile with a different immutable provider binding fails", context do
      assert {:ok, _original} = link(context, %{profile: "bound-profile"})

      assert {:error, :binding_mismatch} =
               link(context, %{
                 label: "Different Auth",
                 profile: "bound-profile",
                 authentication_mode: "api_key"
               })

      assert Repo.aggregate(PersonalAIConnection, :count) == 1
    end

    test "one worker-local profile cannot be shared across accounts", context do
      assert {:ok, _connection} = link(context, %{profile: "private-profile"})

      assert {:error, :profile_already_linked} =
               link(%{context | account: account_fixture()}, %{profile: "private-profile"})

      assert Repo.aggregate(PersonalAIConnection, :count) == 1
    end

    test "account worker profile provider and authentication bindings are immutable", context do
      assert {:ok, connection} = link(context)

      changeset =
        PersonalAIConnection.update_changeset(connection, %{
          account_id: account_fixture().id,
          worker_id: personal_ai_worker_fixture().id,
          worker_profile_ref: "another-profile",
          provider: "another-provider",
          authentication_mode: "api_key"
        })

      refute changeset.valid?

      for field <- [:account_id, :worker_id, :worker_profile_ref, :provider, :authentication_mode] do
        assert "cannot be changed" in errors_on(changeset)[field]
      end

      assert_raise Ecto.ConstraintError, fn ->
        connection
        |> Ecto.Changeset.change(authentication_mode: "api_key")
        |> Repo.update!()
      end
    end
  end

  describe "adapter allowlists and first-provider modes" do
    test "admits both worker-local ChatGPT and API-key authentication modes", context do
      assert {:ok, chatgpt} =
               link(context, %{label: "ChatGPT", profile: "chatgpt-profile"})

      assert {:ok, api_key} =
               link(context, %{
                 label: "API Key",
                 profile: "api-profile",
                 authentication_mode: "api_key"
               })

      assert chatgpt.provider == "openai_codex"
      assert chatgpt.authentication_mode == "chatgpt"
      assert api_key.authentication_mode == "api_key"
    end

    test "rejects unknown input fields and unsupported provider values before calling an adapter",
         context do
      assert {:error, :invalid_connection} =
               PersonalConnections.link_connection(
                 context.account,
                 context.worker,
                 %{
                   label: "Unsafe",
                   provider: "openai_codex",
                   authentication_mode: "api_key",
                   api_key: "must-not-cross"
                 },
                 adapter: PersonalConnectionAdapterDouble,
                 notify: self()
               )

      assert {:error, :invalid_connection} =
               PersonalConnections.link_connection(
                 context.account,
                 context.worker,
                 %{label: "Other", provider: "other", authentication_mode: "chatgpt"},
                 adapter: PersonalConnectionAdapterDouble,
                 notify: self()
               )

      refute_received {:adapter_link, _, _, _}
      assert Repo.aggregate(PersonalAIConnection, :count) == 0
    end

    test "rejects unknown or oversized adapter-result fields and persists nothing", context do
      safe = personal_connection_adapter_result(%{worker_profile_ref: "strict-profile"})

      unsafe_results = [
        Map.put(safe, :provider_email, "identity@example.test"),
        Map.put(safe, :provider_account_id, "acct-1"),
        Map.put(safe, :provider_workspace_id, "workspace-1"),
        Map.put(safe, :plan_detail, "pro"),
        Map.put(safe, :credential, "secret"),
        Map.put(safe, :raw_error, "provider said too much"),
        %{safe | worker_profile_ref: String.duplicate("x", 256)}
      ]

      for result <- unsafe_results do
        assert {:error, :invalid_response} =
                 PersonalConnections.link_connection(
                   context.account,
                   context.worker,
                   %{
                     label: "Strict",
                     provider: "openai_codex",
                     authentication_mode: "chatgpt"
                   },
                   adapter: PersonalConnectionAdapterDouble,
                   adapter_result: {:ok, result}
                 )
      end

      assert Repo.aggregate(PersonalAIConnection, :count) == 0
    end

    test "normalizes arbitrary adapter failures without returning raw text", context do
      assert {:error, :invalid_response} =
               PersonalConnections.link_connection(
                 context.account,
                 context.worker,
                 %{label: "Safe Error", provider: "openai_codex", authentication_mode: "chatgpt"},
                 adapter: PersonalConnectionAdapterDouble,
                 adapter_result: {:error, {:provider_error, "raw provider text"}}
               )

      assert Repo.aggregate(PersonalAIConnection, :count) == 0
    end

    test "the production RPC adapter sends and accepts only the connection/1 safe contract",
         context do
      request = %{provider: "openai_codex", authentication_mode: "chatgpt"}

      rpc_result =
        {:ok,
         %{
           "worker_profile_ref" => "rpc-profile",
           "provider" => "openai_codex",
           "authentication_mode" => "chatgpt",
           "availability" => "available",
           "adapter_compatibility_version" => "connection/1"
         }}

      assert {:ok, normalized} =
               RPC.link(context.account, context.worker, request,
                 rpc: PersonalConnectionAdapterDouble,
                 rpc_result: rpc_result,
                 notify: self()
               )

      assert normalized.worker_profile_ref == "rpc-profile"

      assert_received {:rpc_request, account_id, workspace_id, worker_id, "connection/1", params}
      assert account_id == context.account.id
      assert workspace_id == context.worker.device_workspace_id
      assert worker_id == context.worker.id

      assert params == %{
               "operation" => "link",
               "provider" => "openai_codex",
               "authentication_mode" => "chatgpt"
             }

      refute Map.has_key?(params, "credential")
      refute Map.has_key?(params, "provider_email")

      assert {:error, :invalid_response} =
               RPC.link(context.account, context.worker, request,
                 rpc: PersonalConnectionAdapterDouble,
                 rpc_result: {:ok, Map.put(elem(rpc_result, 1), "plan", "pro")}
               )
    end
  end

  describe "consumer resolution and revocation" do
    test "requires explicit selection and resolves the same minimal reference for both consumers",
         context do
      assert {:ok, connection} = link(context)

      assert {:error, :connection_required} =
               PersonalConnections.resolve_for_consumer(
                 context.account,
                 nil,
                 :support_assistant
               )

      assert {:ok, support} =
               PersonalConnections.resolve_support_connection(context.account, connection.id)

      assert {:ok, working} =
               PersonalConnections.resolve_working_agent_connection(
                 context.account,
                 connection.id
               )

      assert support == working

      assert Map.keys(support) |> Enum.sort() ==
               [
                 :adapter_compatibility_version,
                 :authentication_mode,
                 :availability,
                 :connection_id,
                 :provider,
                 :worker_id
               ]

      refute Map.has_key?(support, :worker_profile_ref)

      assert {:error, :invalid_consumer} =
               PersonalConnections.resolve_for_consumer(
                 context.account,
                 connection.id,
                 :funded_fallback
               )

      assert {:error, :not_found} =
               PersonalConnections.resolve_support_connection(account_fixture(), connection.id)
    end

    test "unavailable and incompatible connections persist safely but cannot fund work",
         context do
      assert {:ok, unavailable} =
               link(context, %{
                 label: "Offline",
                 profile: "offline-profile",
                 availability: "unavailable"
               })

      assert {:ok, incompatible} =
               link(context, %{
                 label: "Old Worker",
                 profile: "old-profile",
                 availability: "incompatible"
               })

      assert unavailable.availability == "unavailable"
      assert incompatible.availability == "incompatible"

      assert {:error, :unavailable} =
               PersonalConnections.resolve_support_connection(context.account, unavailable.id)

      assert {:error, :incompatible} =
               PersonalConnections.resolve_working_agent_connection(
                 context.account,
                 incompatible.id
               )
    end

    test "request and acknowledgement are scoped idempotent state transitions", context do
      assert {:ok, connection} = link(context)
      requested_at = ~U[2026-08-03 11:00:00Z]
      later = DateTime.add(requested_at, 60, :second)

      assert {:error, :revocation_not_requested} =
               PersonalConnections.acknowledge_revocation(context.account, connection.id,
                 at: requested_at
               )

      assert {:ok, requested} =
               PersonalConnections.request_revocation(context.account, connection.id,
                 at: requested_at
               )

      assert requested.revocation_state == "requested"
      assert requested.revocation_requested_at == requested_at
      assert requested.revocation_acknowledged_at == nil

      assert {:ok, repeated_request} =
               PersonalConnections.request_revocation(context.account, connection.id, at: later)

      assert repeated_request.revocation_requested_at == requested_at

      assert {:error, :revoking} =
               PersonalConnections.resolve_support_connection(context.account, connection.id)

      assert {:ok, acknowledged} =
               PersonalConnections.acknowledge_revocation(context.account, connection.id,
                 at: later
               )

      assert acknowledged.revocation_state == "acknowledged"
      assert acknowledged.revocation_requested_at == requested_at
      assert acknowledged.revocation_acknowledged_at == later

      assert {:ok, repeated_acknowledgement} =
               PersonalConnections.acknowledge_revocation(
                 context.account,
                 connection.id,
                 at: DateTime.add(later, 60, :second)
               )

      assert repeated_acknowledgement.revocation_acknowledged_at == later

      assert {:error, :revoked} =
               PersonalConnections.resolve_working_agent_connection(
                 context.account,
                 connection.id
               )

      assert {:error, :not_found} =
               PersonalConnections.request_revocation(account_fixture(), connection.id)
    end

    test "active state rejects revocation timestamps before the database", context do
      assert {:ok, connection} = link(context)

      changeset =
        PersonalAIConnection.update_changeset(connection, %{
          revocation_requested_at: ~U[2026-08-03 11:00:00Z]
        })

      refute changeset.valid?
      assert "does not match state" in errors_on(changeset).revocation_requested_at
    end
  end

  defp link(context, overrides \\ %{}) do
    label = Map.get(overrides, :label, "Personal Codex")
    profile = Map.get(overrides, :profile, "profile-primary")
    provider = Map.get(overrides, :provider, "openai_codex")
    authentication_mode = Map.get(overrides, :authentication_mode, "chatgpt")
    availability = Map.get(overrides, :availability, "available")

    result =
      personal_connection_adapter_result(%{
        worker_profile_ref: profile,
        provider: provider,
        authentication_mode: authentication_mode,
        availability: availability
      })

    PersonalConnections.link_connection(
      context.account,
      context.worker,
      %{
        label: label,
        provider: provider,
        authentication_mode: authentication_mode
      },
      adapter: PersonalConnectionAdapterDouble,
      adapter_result: {:ok, result}
    )
  end
end
