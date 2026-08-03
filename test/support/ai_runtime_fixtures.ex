defmodule SddOrchestrator.AIRuntimeFixtures do
  @moduledoc "Test fixtures for account-owned personal AI connections."

  import SddOrchestrator.AccountsFixtures

  alias SddOrchestrator.AIRuntime.PersonalConnections
  alias SddOrchestrator.Devices.Pairing
  alias SddOrchestrator.PersonalConnectionAdapterDouble

  @doc "Creates one active paired local worker through the real pairing boundary."
  def personal_ai_worker_fixture(attrs \\ %{}) do
    device_workspace_id =
      Map.get_lazy(attrs, :device_workspace_id, fn -> Ecto.UUID.generate() end)

    {:ok, %{code: code}} = Pairing.start_pairing(device_workspace_id)

    {:ok, %{worker: worker}} =
      Pairing.complete_pairing(code, %{
        os_family: Map.get(attrs, :os_family, "macos"),
        app_version: Map.get(attrs, :app_version, "1.0.0"),
        protocol_version: Map.get(attrs, :protocol_version, "personal-ai/1")
      })

    worker
  end

  @doc "Builds the exact safe result shape accepted from a connection adapter."
  def personal_connection_adapter_result(attrs \\ %{}) do
    %{
      worker_profile_ref:
        Map.get_lazy(attrs, :worker_profile_ref, fn ->
          "profile-#{System.unique_integer([:positive])}"
        end),
      provider: Map.get(attrs, :provider, "openai_codex"),
      authentication_mode: Map.get(attrs, :authentication_mode, "chatgpt"),
      availability: Map.get(attrs, :availability, "available"),
      adapter_compatibility_version:
        Map.get(attrs, :adapter_compatibility_version, "connection/1")
    }
  end

  @doc "Creates one personal connection through the public lifecycle boundary."
  def personal_ai_connection_fixture(attrs \\ %{}) do
    account = Map.get_lazy(attrs, :account, &account_fixture/0)
    worker = Map.get_lazy(attrs, :worker, &personal_ai_worker_fixture/0)
    authentication_mode = Map.get(attrs, :authentication_mode, "chatgpt")

    result =
      attrs
      |> Map.take([
        :worker_profile_ref,
        :provider,
        :authentication_mode,
        :availability,
        :adapter_compatibility_version
      ])
      |> Map.put_new(:authentication_mode, authentication_mode)
      |> personal_connection_adapter_result()

    link_attrs = %{
      label: Map.get(attrs, :label, "Personal Codex"),
      provider: Map.get(attrs, :provider, "openai_codex"),
      authentication_mode: authentication_mode
    }

    {:ok, connection} =
      PersonalConnections.link_personal_connection(account, worker, link_attrs,
        adapter: PersonalConnectionAdapterDouble,
        adapter_result: {:ok, result}
      )

    %{connection: connection, account: account, worker: worker}
  end
end
