defmodule SddOrchestrator.AIRuntime.PersonalConnectionAdapter do
  @moduledoc """
  Provider-neutral boundary for linking and revoking one worker-local personal
  AI profile.

  Implementations receive only provider and authentication-mode choices. They
  return one exact, bounded safe result; unknown fields and values are rejected
  before the result can reach persistence.

  Revocation asks the worker to remove the credential it holds locally. The
  acknowledgement is deliberately the smallest fact that proves the outcome —
  which profile was addressed, and whether a local credential was removed or
  was already absent. There is no field a credential, provider identity, plan
  detail, or raw provider error could travel in.
  """

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.AIRuntime.PersonalAIConnection
  alias SddOrchestrator.Devices.LocalWorker

  @result_keys ~w(
    worker_profile_ref provider authentication_mode availability
    adapter_compatibility_version
  )

  @revocation_result_keys ~w(worker_profile_ref credential_removal)

  @credential_removals ~w(removed absent)

  @typedoc "Safe adapter failures exposed to the control plane."
  @type error ::
          :worker_unavailable
          | :timeout
          | :incompatible
          | :invalid_request
          | :invalid_response

  @type request :: %{
          provider: String.t(),
          authentication_mode: String.t()
        }

  @type result :: %{
          worker_profile_ref: String.t(),
          provider: String.t(),
          authentication_mode: String.t(),
          availability: String.t(),
          adapter_compatibility_version: String.t()
        }

  @type revocation_request :: %{worker_profile_ref: String.t()}

  @type revocation_result :: %{
          worker_profile_ref: String.t(),
          credential_removal: String.t()
        }

  @callback link(Account.t(), LocalWorker.t(), request(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback revoke(Account.t(), LocalWorker.t(), revocation_request(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Validates and normalizes an adapter result against the requested provider choice."
  @spec validate_result(map(), request()) :: {:ok, result()} | {:error, :invalid_response}
  def validate_result(result, request) when is_map(result) and is_map(request) do
    with {:ok, normalized} <- normalize_exact_result(result),
         true <- normalized.provider == request.provider,
         true <- normalized.authentication_mode == request.authentication_mode,
         :ok <- bounded_string(normalized.worker_profile_ref, profile_ref_max_length()),
         :ok <-
           bounded_string(normalized.adapter_compatibility_version, adapter_version_max_length()),
         true <- normalized.provider in PersonalAIConnection.providers(),
         true <- normalized.authentication_mode in PersonalAIConnection.authentication_modes(),
         true <- normalized.availability in PersonalAIConnection.availabilities() do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_result(_result, _request), do: {:error, :invalid_response}

  @doc "The bounded worker-local credential-removal outcomes an acknowledgement may report."
  @spec credential_removals() :: [String.t()]
  def credential_removals, do: @credential_removals

  @doc """
  Validates one worker-local credential-removal acknowledgement.

  The echoed profile reference must be the one that was addressed, so a reply
  can never acknowledge removal for a different worker-local profile.
  """
  @spec validate_revocation_result(map(), revocation_request()) ::
          {:ok, revocation_result()} | {:error, :invalid_response}
  def validate_revocation_result(result, request) when is_map(result) and is_map(request) do
    with {:ok, normalized} <- normalize_exact_revocation_result(result),
         :ok <- bounded_string(normalized.worker_profile_ref, profile_ref_max_length()),
         true <- normalized.worker_profile_ref == request[:worker_profile_ref],
         true <- normalized.credential_removal in @credential_removals do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_response}
    end
  end

  def validate_revocation_result(_result, _request), do: {:error, :invalid_response}

  @doc "Collapses arbitrary adapter failures to the small safe error vocabulary."
  @spec normalize_error(term()) :: error()
  def normalize_error(reason)
      when reason in [:worker_unavailable, :timeout, :incompatible, :invalid_request],
      do: reason

  def normalize_error(:worker_disconnected), do: :worker_unavailable
  def normalize_error(:unsupported_capability), do: :incompatible
  def normalize_error(_reason), do: :invalid_response

  defp normalize_exact_result(result) do
    cond do
      Enum.sort(Map.keys(result)) == Enum.sort(@result_keys) ->
        {:ok,
         %{
           worker_profile_ref: result["worker_profile_ref"],
           provider: result["provider"],
           authentication_mode: result["authentication_mode"],
           availability: result["availability"],
           adapter_compatibility_version: result["adapter_compatibility_version"]
         }}

      Enum.sort(Map.keys(result)) == Enum.sort(Enum.map(@result_keys, &String.to_atom/1)) ->
        {:ok,
         %{
           worker_profile_ref: result.worker_profile_ref,
           provider: result.provider,
           authentication_mode: result.authentication_mode,
           availability: result.availability,
           adapter_compatibility_version: result.adapter_compatibility_version
         }}

      true ->
        {:error, :invalid_response}
    end
  end

  defp normalize_exact_revocation_result(result) do
    cond do
      Enum.sort(Map.keys(result)) == Enum.sort(@revocation_result_keys) ->
        {:ok,
         %{
           worker_profile_ref: result["worker_profile_ref"],
           credential_removal: result["credential_removal"]
         }}

      Enum.sort(Map.keys(result)) ==
          Enum.sort(Enum.map(@revocation_result_keys, &String.to_atom/1)) ->
        {:ok,
         %{
           worker_profile_ref: result.worker_profile_ref,
           credential_removal: result.credential_removal
         }}

      true ->
        {:error, :invalid_response}
    end
  end

  defp bounded_string(value, max_length) when is_binary(value) do
    if value == String.trim(value) and byte_size(value) in 1..max_length,
      do: :ok,
      else: {:error, :invalid_response}
  end

  defp bounded_string(_value, _max_length), do: {:error, :invalid_response}

  defp profile_ref_max_length, do: PersonalAIConnection.worker_profile_ref_max_length()
  defp adapter_version_max_length, do: PersonalAIConnection.adapter_version_max_length()
end
