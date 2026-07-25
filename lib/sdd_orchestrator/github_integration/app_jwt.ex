defmodule SddOrchestrator.GitHubIntegration.AppJwt do
  @moduledoc """
  Builds short-lived RS256 GitHub App JWTs for app-authenticated operations.

  Only app-level reads need this (the pending installation-request lookup); every
  user-facing repository read uses the user's access token instead. The token is
  minted from the runtime private key, is never logged, and lives for under ten
  minutes.

  Per the design contract: `iss` is the configured client ID, `iat` is backdated
  60 seconds to tolerate clock drift, and `exp` stays under GitHub's ten-minute
  ceiling.
  """

  alias SddOrchestrator.GitHubIntegration

  # 9 minutes, comfortably under GitHub's 10-minute maximum.
  @lifetime_seconds 540
  @clock_drift_seconds 60

  @doc """
  Generates a signed app JWT.

  Returns `{:error, :missing_private_key}` when no private key is configured (for
  example local development without a real GitHub App), so callers degrade
  gracefully instead of crashing.
  """
  @spec generate() :: {:ok, String.t()} | {:error, :missing_private_key | term()}
  def generate do
    cfg = GitHubIntegration.config()

    with pem when is_binary(pem) <- cfg[:app_private_key] || {:error, :missing_private_key},
         iss when is_binary(iss) <- cfg[:client_id] || {:error, :missing_client_id} do
      now = System.system_time(:second)

      claims = %{
        "iat" => now - @clock_drift_seconds,
        "exp" => now + @lifetime_seconds,
        "iss" => iss
      }

      signer = Joken.Signer.create("RS256", %{"pem" => pem})

      case Joken.generate_and_sign(%{}, claims, signer) do
        {:ok, token, _claims} -> {:ok, token}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
