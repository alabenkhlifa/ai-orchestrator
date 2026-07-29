defmodule SddOrchestrator.Participation.EmailDigest do
  @moduledoc """
  Runtime-keyed comparison digest for invited email addresses.

  Invitations need indexed project-and-email uniqueness without storing a
  reusable identifier. The digest is an HMAC over the established normalized
  comparison key, so equal addresses collide inside one deployment while the
  stored value cannot be reversed or correlated with another deployment.

  The key is derived from the deployment's field-encryption key unless an
  explicit `:email_digest_key` is configured, which keeps this secret in the
  same runtime boundary as the vault instead of adding a second one.
  """

  alias SddOrchestrator.Accounts.ExternalIdentity

  @derivation_context "participation.email_digest.v1"

  @doc """
  Returns the comparison digest for one submitted address, or an error when the
  address is not a usable email.
  """
  @spec compute(term()) :: {:ok, binary()} | {:error, :invalid_email}
  def compute(email) do
    with {:ok, %{subject_key: subject_key}} <- ExternalIdentity.normalize_email(email) do
      {:ok, :crypto.mac(:hmac, :sha256, key(), subject_key)}
    end
  end

  @doc "Returns the comparison digest for an already normalized comparison key."
  @spec from_subject_key(String.t()) :: binary()
  def from_subject_key(subject_key) when is_binary(subject_key),
    do: :crypto.mac(:hmac, :sha256, key(), subject_key)

  defp key do
    case Application.get_env(:sdd_orchestrator, :participation, []) do
      config when is_list(config) -> Keyword.get_lazy(config, :email_digest_key, &derived_key/0)
      _other -> derived_key()
    end
  end

  defp derived_key do
    :crypto.mac(:hmac, :sha256, vault_key(), @derivation_context)
  end

  defp vault_key do
    :sdd_orchestrator
    |> Application.fetch_env!(SddOrchestrator.Vault)
    |> Keyword.fetch!(:ciphers)
    |> Keyword.fetch!(:default)
    |> elem(1)
    |> Keyword.fetch!(:key)
  end
end
