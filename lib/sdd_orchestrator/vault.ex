defmodule SddOrchestrator.Vault do
  @moduledoc """
  Authenticated field-encryption vault (AES-256-GCM) for provider credentials
  and PKCE verifiers.

  The encryption key is supplied at runtime (`config/runtime.exs` in production,
  a fixed non-production key in dev/test). Encrypted database columns therefore
  never hold plaintext secrets, and the key never lives in the repository for a
  real deployment.
  """
  use Cloak.Vault, otp_app: :sdd_orchestrator
end
