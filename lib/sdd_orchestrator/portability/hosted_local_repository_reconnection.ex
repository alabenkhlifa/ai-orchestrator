defmodule SddOrchestrator.Portability.HostedLocalRepositoryReconnection do
  @moduledoc """
  Explicit hosted local-repository reconnection through two authority boundaries.

  The owning personal workspace authorizes the restored hosted project. The
  explicitly selected device workspace and current worker credential separately
  authorize worker-local validation. Only the shared exact-match result reaches
  the minimized hosted binding transaction.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices.LocalRepositoryValidation

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBindings,
    RepositoryReconnection,
    SecurityLog
  }

  alias SddOrchestrator.Portability.RepositoryReconnection.Request

  @type success :: %{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          status: :connected
        }

  @type state :: %{
          project_id: Ecto.UUID.t(),
          state: HostedLocalRepositoryBindings.state(),
          last_validated_at: DateTime.t() | nil
        }

  @type error ::
          :authorization_required
          | :destination_unavailable
          | :invalid_repository_identity
          | :invalid_request
          | :legacy_repository_identity
          | :not_found
          | :repository_mismatch
          | :repository_unavailable
          | :worker_unavailable
          | :worker_validation_failed
          | Ecto.Changeset.t()

  @doc """
  Connects or replaces one hosted local-worker binding after exact validation.

  The worker matcher executes inside the selected worker boundary and receives
  only the project-held portable identity. Every authority or validation failure
  returns before the current binding can be inserted, replaced, or refreshed.
  """
  @spec connect(
          PersonalWorkspace.t(),
          DeviceWorkspace.t(),
          Request.t(),
          String.t(),
          LocalRepositoryValidation.matcher(),
          keyword()
        ) :: {:ok, success()} | {:error, error()}
  def connect(
        personal_workspace,
        device_workspace,
        request,
        worker_credential,
        worker_matcher,
        opts \\ []
      )

  def connect(
        personal_workspace,
        device_workspace,
        request,
        worker_credential,
        worker_matcher,
        opts
      ) do
    personal_workspace
    |> do_connect(device_workspace, request, worker_credential, worker_matcher, opts)
    |> SecurityLog.audit(:repository_reconnection)
  end

  defp do_connect(
         %PersonalWorkspace{} = personal_workspace,
         %DeviceWorkspace{} = device_workspace,
         %Request{method: :local_worker_validation} = request,
         worker_credential,
         worker_matcher,
         opts
       )
       when is_binary(worker_credential) and is_function(worker_matcher, 1) do
    with {:ok, ^request} <-
           RepositoryReconnection.required(personal_workspace, request.project_id),
         {:ok, validation} <-
           LocalRepositoryValidation.validate(
             device_workspace,
             worker_credential,
             request.repository_id,
             worker_matcher,
             opts
           ),
         {:ok, %{binding: _binding}} <-
           HostedLocalRepositoryBindings.put_validated_binding(
             personal_workspace,
             request.project_id,
             device_workspace,
             validation.worker_id,
             validation.repository_id,
             validated_at: validation.validated_at
           ) do
      {:ok, connected_result(request)}
    else
      {:ok, %Request{}} ->
        {:error, :invalid_request}

      {:error, :unauthorized_worker} ->
        {:error, :authorization_required}

      {:error, :invalid_project_provider} ->
        {:error, :invalid_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_connect(
         _personal_workspace,
         _device_workspace,
         _request,
         _worker_credential,
         _worker_matcher,
         _opts
       ),
       do: {:error, :invalid_request}

  @doc """
  Returns a minimized owner-scoped connection state without worker or device data.

  An unparseable stored repository identity passes through as
  `:invalid_repository_identity`, matching the shared binding boundary.
  """
  @spec connection_state(PersonalWorkspace.t(), String.t(), keyword()) ::
          {:ok, state()}
          | {:error, :not_found | :invalid_request | :invalid_repository_identity}
  def connection_state(personal_workspace, project_id, opts \\ [])

  def connection_state(%PersonalWorkspace{} = personal_workspace, project_id, opts)
      when is_binary(project_id) do
    case HostedLocalRepositoryBindings.connection_state(
           personal_workspace,
           project_id,
           opts
         ) do
      {:ok, %{binding: binding, state: state}} ->
        {:ok,
         %{
           project_id: project_id,
           state: state,
           last_validated_at: binding && binding.last_validated_at
         }}

      {:error, :invalid_project_provider} ->
        {:error, :invalid_request}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connection_state(_personal_workspace, _project_id, _opts), do: {:error, :not_found}

  @doc "Explicitly disconnects the owning hosted project's local worker."
  @spec disconnect(PersonalWorkspace.t(), String.t()) ::
          {:ok, :disconnected} | {:error, :not_found}
  def disconnect(%PersonalWorkspace{} = personal_workspace, project_id) do
    personal_workspace
    |> HostedLocalRepositoryBindings.disconnect(project_id)
    |> SecurityLog.audit(:repository_disconnection)
  end

  def disconnect(_personal_workspace, _project_id) do
    SecurityLog.audit({:error, :not_found}, :repository_disconnection)
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
