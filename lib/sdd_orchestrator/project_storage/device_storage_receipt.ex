defmodule SddOrchestrator.ProjectStorage.DeviceStorageReceipt do
  @moduledoc """
  A bound, minimized, expiring device-storage readiness receipt.

  The local-device boundary (`specs/02-local-project-onboarding/`) supplies a
  one-time raw proof after the user prepares on-device storage. It only marks
  device storage as ready for one onboarding attempt; it grants no repository or
  control-plane access and carries no credential.

  Only the minimum, non-reversible binding persists. `issue/1` hashes the raw
  proof with its nonce into a `digest` and the raw proof is discarded — it is
  never stored. The persisted form (on the attempt's `device_setup` jsonb) holds
  only the digest, nonce, the bound onboarding attempt id, the bound device
  workspace id, and the issue and expiry times. No raw proof, device label,
  operating-system username, path, or hardware identifier is retained.

  A receipt is valid only for the attempt and device it was issued for and only
  before it expires, so an expired, mismatched, or cross-workspace receipt fails
  closed.
  """
  @enforce_keys [:digest, :nonce, :attempt_id, :device_workspace_id, :issued_at, :expires_at]
  defstruct [:digest, :nonce, :attempt_id, :device_workspace_id, :issued_at, :expires_at]

  @type t :: %__MODULE__{
          digest: String.t(),
          nonce: String.t(),
          attempt_id: Ecto.UUID.t(),
          device_workspace_id: Ecto.UUID.t(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @doc """
  Builds a minimized, bound receipt from the worker's raw one-time proof. The raw
  proof is hashed with the nonce and never retained.
  """
  @spec issue(%{
          required(:token) => String.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:nonce) => String.t(),
          required(:issued_at) => DateTime.t(),
          required(:expires_at) => DateTime.t()
        }) :: t()
  def issue(%{
        token: token,
        attempt_id: attempt_id,
        device_workspace_id: device_workspace_id,
        nonce: nonce,
        issued_at: issued_at,
        expires_at: expires_at
      })
      when is_binary(token) and is_binary(nonce) do
    %__MODULE__{
      digest: digest(token, nonce),
      nonce: nonce,
      attempt_id: attempt_id,
      device_workspace_id: device_workspace_id,
      issued_at: issued_at,
      expires_at: expires_at
    }
  end

  @doc "Builds a receipt from an onboarding attempt's stored `device_setup` map."
  @spec from_attempt(map()) :: {:ok, t()} | :error
  def from_attempt(%{device_setup: setup}), do: from_map(setup)
  def from_attempt(_), do: :error

  @doc "Builds a receipt from its persisted string-keyed map form."
  @spec from_map(map() | nil) :: {:ok, t()} | :error
  def from_map(
        %{
          "digest" => digest,
          "nonce" => nonce,
          "attempt_id" => attempt_id,
          "device_workspace_id" => device_workspace_id,
          "issued_at" => issued_at,
          "expires_at" => expires_at
        } = _map
      )
      when is_binary(digest) and is_binary(nonce) and is_binary(issued_at) and
             is_binary(expires_at) do
    with {:ok, issued, _} <- DateTime.from_iso8601(issued_at),
         {:ok, expiry, _} <- DateTime.from_iso8601(expires_at) do
      {:ok,
       %__MODULE__{
         digest: digest,
         nonce: nonce,
         attempt_id: attempt_id,
         device_workspace_id: device_workspace_id,
         issued_at: issued,
         expires_at: expiry
       }}
    else
      _ -> :error
    end
  end

  def from_map(_), do: :error

  @doc "Whether the receipt is present, well-formed, and not expired."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{
        digest: digest,
        nonce: nonce,
        device_workspace_id: dws,
        expires_at: expiry
      }) do
    is_binary(digest) and byte_size(digest) > 0 and is_binary(nonce) and is_binary(dws) and
      DateTime.compare(expiry, DateTime.utc_now()) == :gt
  end

  @doc """
  Whether the receipt is valid and bound to the given onboarding attempt. A
  device-origin attempt additionally requires the receipt's device workspace to
  match the attempt's, so a receipt issued for another device fails closed.
  """
  @spec valid_for?(t(), map()) :: boolean()
  def valid_for?(%__MODULE__{} = receipt, %{id: attempt_id} = attempt) do
    valid?(receipt) and receipt.attempt_id == attempt_id and device_bound?(receipt, attempt)
  end

  defp device_bound?(%__MODULE__{device_workspace_id: dws}, %{
         origin_kind: "device",
         device_workspace_id: attempt_dws
       }),
       do: dws == attempt_dws

  defp device_bound?(_receipt, _attempt), do: true

  @doc "Serializes a receipt to its persisted, minimized string-keyed map form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      "digest" => receipt.digest,
      "nonce" => receipt.nonce,
      "attempt_id" => receipt.attempt_id,
      "device_workspace_id" => receipt.device_workspace_id,
      "issued_at" => DateTime.to_iso8601(receipt.issued_at),
      "expires_at" => DateTime.to_iso8601(receipt.expires_at)
    }
  end

  defp digest(token, nonce) do
    :crypto.hash(:sha256, nonce <> ":" <> token) |> Base.encode16(case: :lower)
  end
end
