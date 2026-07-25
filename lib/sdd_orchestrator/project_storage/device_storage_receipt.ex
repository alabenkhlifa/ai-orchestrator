defmodule SddOrchestrator.ProjectStorage.DeviceStorageReceipt do
  @moduledoc """
  An opaque, expiring device-storage readiness receipt.

  The local-device boundary (`specs/02-local-project-onboarding/`) supplies this
  after the user prepares on-device storage. It only marks device storage as
  ready for this onboarding attempt; it grants no repository or control-plane
  access and carries no credential. It is stored on the onboarding attempt's
  `device_setup` map (string-keyed for jsonb) and validated here.
  """
  @enforce_keys [:token, :expires_at]
  defstruct [:token, :expires_at, :device_label]

  @type t :: %__MODULE__{
          token: String.t(),
          expires_at: DateTime.t(),
          device_label: String.t() | nil
        }

  @doc "Builds a receipt from an onboarding attempt's stored `device_setup` map."
  @spec from_attempt(map()) :: {:ok, t()} | :error
  def from_attempt(%{device_setup: setup}), do: from_map(setup)
  def from_attempt(_), do: :error

  @doc "Builds a receipt from its persisted string-keyed map form."
  @spec from_map(map() | nil) :: {:ok, t()} | :error
  def from_map(%{"token" => token, "expires_at" => expires_at} = map)
      when is_binary(token) and is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} ->
        {:ok, %__MODULE__{token: token, expires_at: datetime, device_label: map["device_label"]}}

      _ ->
        :error
    end
  end

  def from_map(_), do: :error

  @doc "Whether the receipt is present and not expired."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{token: token, expires_at: expires_at}) do
    is_binary(token) and byte_size(token) > 0 and
      DateTime.compare(expires_at, DateTime.utc_now()) == :gt
  end

  @doc "Serializes a receipt to its persisted string-keyed map form."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = receipt) do
    %{
      "token" => receipt.token,
      "expires_at" => DateTime.to_iso8601(receipt.expires_at),
      "device_label" => receipt.device_label
    }
  end
end
