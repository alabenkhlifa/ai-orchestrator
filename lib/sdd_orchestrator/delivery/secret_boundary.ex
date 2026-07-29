defmodule SddOrchestrator.Delivery.SecretBoundary do
  @moduledoc """
  Rejects raw credential material inside worker protocol values.

  Repository, agent, model, and preview secrets resolve inside the worker's
  own configured boundary. Commands, manifests, events, and snapshots carry
  only opaque configured references, so a field named `credential_ref` is
  allowed while a field named `credential` is not.
  """

  @forbidden_keys ~w(
    access_token
    api_key
    apikey
    authorization
    client_secret
    cookie
    credential
    credentials
    id_token
    passphrase
    password
    private_key
    refresh_token
    secret
    secret_key
    session_token
    ssh_key
    token
  )

  @forbidden_value_markers ["-----BEGIN "]

  @spec forbidden_keys() :: [String.t()]
  def forbidden_keys, do: @forbidden_keys

  @doc """
  Walks one decoded JSON value and rejects raw credential fields or material.
  """
  @spec validate(term()) :: :ok | {:error, atom()}
  def validate(value) when is_map(value) and not is_struct(value) do
    if Enum.any?(Map.keys(value), &forbidden_key?/1) do
      {:error, :secret_field_rejected}
    else
      value |> Map.values() |> validate_each()
    end
  end

  def validate(value) when is_list(value), do: validate_each(value)

  def validate(value) when is_binary(value) do
    if Enum.any?(@forbidden_value_markers, &String.contains?(value, &1)) do
      {:error, :secret_material_rejected}
    else
      :ok
    end
  end

  def validate(_value), do: :ok

  defp validate_each(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate(value) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp forbidden_key?(key) when is_binary(key), do: String.downcase(key) in @forbidden_keys
  defp forbidden_key?(key) when is_atom(key), do: forbidden_key?(Atom.to_string(key))
  defp forbidden_key?(_key), do: false
end
