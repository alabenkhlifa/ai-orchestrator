defmodule SddOrchestrator.Devices.LocalRepositoryValidation do
  @moduledoc """
  Shared authorization and exact-match boundary for local repository reconnection.

  The control plane authenticates one active paired worker and supplies only the
  project-held portable identifier. The worker-side matcher keeps the repository
  path and Git data inside the device boundary and returns only whether that
  identifier matched. Successful results are minimized for device reconnection
  and the hosted binding adapter.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.Devices.{
    Pairing,
    PortableRepositoryIdentity,
    WorkerDiscovery
  }

  defmodule Result do
    @moduledoc false

    @enforce_keys [:worker_id, :repository_id, :validated_at]
    @derive {Inspect, only: [:validated_at]}
    defstruct [:worker_id, :repository_id, :validated_at]

    @type t :: %__MODULE__{
            worker_id: Ecto.UUID.t(),
            repository_id: String.t(),
            validated_at: DateTime.t()
          }
  end

  @type matcher :: (String.t() -> {:ok, boolean()} | {:error, term()})

  @type error ::
          :authorization_required
          | :invalid_repository_identity
          | :legacy_repository_identity
          | :repository_mismatch
          | :repository_unavailable
          | :worker_unavailable
          | :worker_validation_failed

  @doc """
  Authenticates and authorizes one worker before requesting an exact local match.

  The matcher receives only the already parsed portable identifier. It executes
  in the worker boundary and must not return a path, credential, Git object, or
  other device data.
  """
  @spec validate(
          DeviceWorkspace.t(),
          String.t(),
          String.t(),
          matcher(),
          keyword()
        ) :: {:ok, Result.t()} | {:error, error()}
  def validate(device_workspace, worker_credential, repository_id, matcher, opts \\ [])

  def validate(
        %DeviceWorkspace{id: device_workspace_id},
        worker_credential,
        repository_id,
        matcher,
        opts
      )
      when is_binary(worker_credential) and is_function(matcher, 1) do
    validated_at =
      opts
      |> Keyword.get(:validated_at, DateTime.utc_now())
      |> DateTime.truncate(:second)

    with :ok <- validate_identifier(repository_id),
         {:ok, worker} <- authenticate(worker_credential),
         :ok <- authorize(worker, device_workspace_id),
         :ok <- available(worker, validated_at),
         {:ok, true} <- invoke_matcher(matcher, repository_id) do
      {:ok,
       %Result{
         worker_id: worker.id,
         repository_id: repository_id,
         validated_at: validated_at
       }}
    else
      {:ok, false} -> {:error, :repository_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate(%DeviceWorkspace{}, _credential, _repository_id, _matcher, _opts),
    do: {:error, :authorization_required}

  defp validate_identifier(repository_id) do
    case PortableRepositoryIdentity.parse(repository_id) do
      {:ok, _identity} -> :ok
      {:error, :legacy_identifier} -> {:error, :legacy_repository_identity}
      {:error, :invalid_identifier} -> {:error, :invalid_repository_identity}
    end
  end

  defp authenticate(credential) do
    case Pairing.authenticate_worker(credential) do
      {:ok, worker} -> {:ok, worker}
      {:error, :unauthorized} -> {:error, :authorization_required}
    end
  end

  defp authorize(worker, device_workspace_id) do
    case Pairing.authorize_for_workspace(worker, device_workspace_id) do
      :ok -> :ok
      {:error, :cross_workspace} -> {:error, :authorization_required}
    end
  end

  defp available(worker, now) do
    if WorkerDiscovery.status([worker], now: now) == :detected,
      do: :ok,
      else: {:error, :worker_unavailable}
  end

  defp invoke_matcher(matcher, repository_id) do
    case matcher.(repository_id) do
      {:ok, matched?} when is_boolean(matched?) ->
        {:ok, matched?}

      {:error, reason}
      when reason in [:inaccessible, :not_a_git_repository, :empty_repository] ->
        {:error, :repository_unavailable}

      {:error, _reason} ->
        {:error, :worker_validation_failed}

      _other ->
        {:error, :worker_validation_failed}
    end
  rescue
    _error -> {:error, :worker_validation_failed}
  catch
    _kind, _reason -> {:error, :worker_validation_failed}
  end
end
