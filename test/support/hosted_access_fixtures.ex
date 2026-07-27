defmodule SddOrchestrator.HostedAccessFixtures do
  @moduledoc "Test fixtures for passwordless hosted identities and workspaces."

  alias SddOrchestrator.HostedAccess

  @doc "Creates or restores a hosted identity for a unique verified email."
  def hosted_identity_fixture(attrs \\ %{}) do
    email =
      Map.get_lazy(attrs, :email, fn ->
        "hosted-#{System.unique_integer([:positive])}@example.com"
      end)

    {:ok, result} = HostedAccess.restore_or_create_identity(email)
    result
  end
end
