defmodule SddOrchestrator.GitHubIntegration.LiveSmokeTest do
  @moduledoc """
  Live GitHub App smoke proof — the real network round trip the deterministic
  `Req.Test` contract proof cannot make.

  It signs a real RS256 app JWT from the secret-backed GitHub App private key and
  confirms that `api.github.com` accepts the app's own credentials on an
  app-authenticated read. This is the tagged proof referenced by the Slice 01
  verification gate: environment-blocked locally (no secret-backed GitHub App),
  it runs in the secret-backed staging environment.

  Run it explicitly with `mix test --include live`. It is excluded from the
  standard deterministic gate by the `:live` tag (see `test/test_helper.exs`).
  Opting in without the staging secrets skips the module with a reason rather
  than failing, so a missing credential never masquerades as a defect.
  """
  use ExUnit.Case, async: false

  alias SddOrchestrator.GitHubIntegration.ReqProvider

  @moduletag :live

  # Skip (do not fail) when opted into `:live` without the staging secrets: the
  # whole point of this proof is the real credentialed round trip, so with no
  # credentials there is nothing meaningful to assert. Evaluated at compile time,
  # where the staging environment already exposes the secrets.
  if System.get_env("GITHUB_CLIENT_ID") in [nil, ""] or
       System.get_env("GITHUB_APP_PRIVATE_KEY") in [nil, ""] do
    @moduletag skip:
                 "live GitHub App smoke requires GITHUB_CLIENT_ID and GITHUB_APP_PRIVATE_KEY " <>
                   "(secret-backed staging environment)"
  end

  setup do
    # Test config points the provider at the deterministic fake; override it to
    # the real Req adapter and the real GitHub App credentials for this proof,
    # preserving the shared api_base_url/api_version and restoring afterward.
    original = Application.get_env(:sdd_orchestrator, :github)

    Application.put_env(
      :sdd_orchestrator,
      :github,
      Keyword.merge(original,
        provider: ReqProvider,
        client_id: System.get_env("GITHUB_CLIENT_ID"),
        app_private_key: System.get_env("GITHUB_APP_PRIVATE_KEY")
      )
    )

    on_exit(fn -> Application.put_env(:sdd_orchestrator, :github, original) end)
    :ok
  end

  test "the real GitHub App key authenticates an app-JWT read against api.github.com" do
    # A valid RS256 app JWT (iss = client id, signed by the real private key) is
    # accepted by GitHub on the app-authenticated pending-request read. A missing
    # or wrong key would surface as {:error, {:app_jwt, _}} or {:error, {:http, 401}}.
    assert {:ok, requests} = ReqProvider.list_pending_installation_requests()
    assert is_list(requests)
  end
end
