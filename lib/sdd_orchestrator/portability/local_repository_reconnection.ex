defmodule SddOrchestrator.Portability.LocalRepositoryReconnection do
  @moduledoc """
  Explicit device-authoritative local repository reconnection.

  Package control contributes only the project-held portable identity. A current
  paired worker must independently authenticate, authorize the destination device
  workspace, and prove the exact identity through the shared worker boundary
  before the device store marks the project connected.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.LocalRepositoryValidation
  alias SddOrchestrator.Portability.{RepositoryReconnection, SecurityLog}
  alias SddOrchestrator.Portability.RepositoryReconnection.Request

  @type success :: %{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          status: :connected
        }

  @type error ::
          :authorization_required
          | :canonical_repository_mismatch
          | :destination_unavailable
          | :invalid_repository_identity
          | :invalid_request
          | :legacy_repository_identity
          | :not_found
          | :repository_mismatch
          | :repository_unavailable
          | :worker_unavailable
          | :worker_validation_failed

  @doc """
  Reconnects one restored device project after exact current-worker validation.

  `worker_matcher` executes inside the worker boundary and receives only the
  project-held portable identity. No path or credential is accepted from the
  package request or retained in the device project.
  """
  @spec connect(
          DeviceWorkspace.t(),
          Request.t(),
          String.t(),
          LocalRepositoryValidation.matcher(),
          keyword()
        ) :: {:ok, success()} | {:error, error()}
  def connect(authority, request, worker_credential, worker_matcher, opts \\ [])

  def connect(authority, request, worker_credential, worker_matcher, opts) do
    authority
    |> do_connect(request, worker_credential, worker_matcher, opts)
    |> SecurityLog.audit(:repository_reconnection)
  end

  defp do_connect(
         %DeviceWorkspace{} = authority,
         %Request{method: :local_worker_validation} = request,
         worker_credential,
         worker_matcher,
         opts
       )
       when is_binary(worker_credential) and is_function(worker_matcher, 1) do
    with :ok <- authorize_destination(authority),
         :not_connected <- existing_connection(request),
         {:ok, ^request} <- RepositoryReconnection.required(authority, request.project_id),
         {:ok, _validation} <-
           LocalRepositoryValidation.validate(
             authority,
             worker_credential,
             request.repository_id,
             worker_matcher,
             opts
           ),
         {:ok, _project} <-
           Devices.connect_repository(
             request.project_id,
             request.repository_provider,
             request.repository_id
           ) do
      {:ok, connected_result(request)}
    else
      {:connected, result} ->
        {:ok, result}

      {:ok, %Request{}} ->
        {:error, :invalid_request}

      {:error, :canonical_repository_mismatch} ->
        {:error, :canonical_repository_mismatch}

      {:error, reason} ->
        {:error, reason}

      _reason ->
        {:error, :invalid_request}
    end
  end

  defp do_connect(_authority, _request, _worker_credential, _worker_matcher, _opts),
    do: {:error, :invalid_request}

  defp authorize_destination(%DeviceWorkspace{id: authority_id}) do
    case Devices.get_workspace() do
      {:ok, %DeviceWorkspace{id: ^authority_id}} -> :ok
      _reason -> {:error, :destination_unavailable}
    end
  end

  defp existing_connection(request) do
    case Devices.get_project(request.project_id) do
      {:ok,
       %{
         repository_provider: "local",
         repository_id: repository_id,
         status: "connected"
       }}
      when repository_id == request.repository_id ->
        {:connected, connected_result(request)}

      _project ->
        :not_connected
    end
  end

  defp connected_result(request) do
    %{
      project_id: request.project_id,
      repository_provider: "local",
      repository_id: request.repository_id,
      status: :connected
    }
  end
end
