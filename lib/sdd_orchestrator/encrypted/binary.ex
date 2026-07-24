defmodule SddOrchestrator.Encrypted.Binary do
  @moduledoc """
  Ecto type for a database column encrypted at rest with `SddOrchestrator.Vault`.
  Used for GitHub access/refresh tokens and PKCE verifiers so plaintext secrets
  never touch the database, logs, or backups.
  """
  use Cloak.Ecto.Binary, vault: SddOrchestrator.Vault
end
