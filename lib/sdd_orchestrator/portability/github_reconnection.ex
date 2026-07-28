defmodule SddOrchestrator.Portability.GitHubReconnection do
  @moduledoc """
  Explicit GitHub reconnection through the existing account credential and
  metadata-read provider flow.

  The package contributes only the canonical repository id. Current account
  authorization must independently expose that exact repository before a
  connection is recorded. No repository content, branch, remote, setting, Git
  configuration, or packaged credential is read or changed.
  """

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{Account, DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.GitHubIntegration

  alias SddOrchestrator.Portability.RepositoryReconnection
  alias SddOrchestrator.Portability.RepositoryReconnection.Request
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.RepositoryConnection
  alias SddOrchestrator.Repo

  @type success :: %{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          status: :connected
        }

  @spec connect(Account.t(), PersonalWorkspace.t() | DeviceWorkspace.t(), Request.t()) ::
          {:ok, success()}
          | {:error,
             :authorization_required
             | :canonical_repository_mismatch
             | :destination_unavailable
             | :invalid_request
             | :not_found
             | :provider_unavailable
             | Ecto.Changeset.t()}
  def connect(
        %Account{state: :active} = account,
        authority,
        %Request{method: :github_authorization} = request
      ) do
    with :ok <- authorize_destination(account, authority),
         :not_connected <- existing_connection(authority, request),
         {:ok, ^request} <- RepositoryReconnection.required(authority, request.project_id),
         {:ok, access_token} <- current_access_token(account),
         {:ok, github_user_id} <- github_user_id(account),
         {:ok, installations} <- installations(access_token, github_user_id),
         {:ok, repositories} <-
           GitHubIntegration.list_accessible_repositories(access_token, installations),
         {:ok, repository} <- exact_repository(repositories, request.repository_id),
         {:ok, _connected} <- persist_connection(authority, request, repository) do
      {:ok, connected_result(request)}
    else
      {:connected, result} ->
        {:ok, result}

      {:ok, %Request{}} ->
        {:error, :invalid_request}

      {:error, reason} when reason in [:rate_limited, :org_restricted, :provider_failure] ->
        {:error, :provider_unavailable}

      {:error, reason} when reason in [:unauthorized, :none, :pending, :no_credential] ->
        {:error, :authorization_required}

      {:error, _reason} = error ->
        error

      _reason ->
        {:error, :invalid_request}
    end
  end

  def connect(_account, _authority, _request), do: {:error, :invalid_request}

  defp authorize_destination(
         %Account{id: account_id},
         %PersonalWorkspace{account_id: account_id}
       ),
       do: :ok

  defp authorize_destination(%Account{}, %PersonalWorkspace{}),
    do: {:error, :not_found}

  defp authorize_destination(%Account{}, %DeviceWorkspace{id: authority_id}) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         :detected <- Devices.worker_status(authority_id) do
      :ok
    else
      _reason -> {:error, :destination_unavailable}
    end
  end

  defp authorize_destination(_account, _authority), do: {:error, :not_found}

  defp existing_connection(%PersonalWorkspace{} = authority, request) do
    case Projects.get_project(authority, request.project_id) do
      %{
        repository_provider: "github",
        canonical_repository_id: repository_id,
        repository_connection: %RepositoryConnection{state: "connected"}
      }
      when repository_id == request.repository_id ->
        {:connected, connected_result(request)}

      _project ->
        :not_connected
    end
  end

  defp existing_connection(%DeviceWorkspace{}, request) do
    case Devices.get_project(request.project_id) do
      {:ok,
       %{
         repository_provider: "github",
         repository_id: repository_id,
         status: "connected"
       }}
      when repository_id == request.repository_id ->
        {:connected, connected_result(request)}

      _project ->
        :not_connected
    end
  end

  defp current_access_token(account) do
    case Accounts.valid_access_token(account.id) do
      {:ok, token} ->
        {:ok, token}

      {:error, reason} when reason in [:no_credential, {:refresh_failed, :unauthorized}] ->
        {:error, :no_credential}

      {:error, _reason} ->
        {:error, :authorization_required}
    end
  end

  defp github_user_id(account) do
    case Accounts.get_github_identity(account.id) do
      %{github_user_id: id} when is_integer(id) -> {:ok, id}
      _identity -> {:error, :authorization_required}
    end
  end

  defp installations(access_token, github_user_id) do
    case GitHubIntegration.check_repository_access(access_token, github_user_id) do
      {:ok, :granted, installations} -> {:ok, installations}
      {:ok, :pending, _organization} -> {:error, :pending}
      {:ok, :none} -> {:error, :none}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exact_repository(repositories, repository_id) do
    case Enum.find(repositories, &(Integer.to_string(&1.id) == repository_id)) do
      nil -> {:error, :canonical_repository_mismatch}
      repository -> {:ok, repository}
    end
  end

  defp persist_connection(%PersonalWorkspace{} = authority, request, repository) do
    case Projects.get_project(authority, request.project_id) do
      nil ->
        {:error, :not_found}

      project ->
        %RepositoryConnection{}
        |> RepositoryConnection.create_changeset(%{
          project_id: project.id,
          workspace_id: authority.id,
          provider: "github",
          provider_repository_id: repository.id,
          owner: repository.owner,
          name: repository.name,
          full_name: repository.full_name,
          html_url: repository.html_url,
          visibility: repository.visibility,
          private: repository.private,
          organization: repository.organization,
          state: "connected",
          last_validated_at: now()
        })
        |> Repo.insert()
    end
  end

  defp persist_connection(%DeviceWorkspace{}, request, _repository) do
    Devices.connect_repository(request.project_id, "github", request.repository_id)
  end

  defp connected_result(request) do
    %{
      project_id: request.project_id,
      repository_provider: "github",
      repository_id: request.repository_id,
      status: :connected
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
