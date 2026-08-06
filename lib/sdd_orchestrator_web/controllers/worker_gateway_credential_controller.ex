defmodule SddOrchestratorWeb.WorkerGatewayCredentialController do
  @moduledoc """
  The paired worker's authenticated exchange for a project-scoped gateway credential.

  This is the first caller of `WorkerSocket.issue/3`: a worker that already holds
  a per-worker pairing credential presents it alongside the project it wants to
  run, and receives the short-lived, project- and execution-target-scoped
  credential the delivery gateway already verifies. No second credential concept
  is introduced.

  A project's local-repository binding names the worker whose device workspace
  was proven to control it (`specs/06-project-portability`); this exchange
  re-checks that the requesting credential's own device workspace still matches
  it, so a revoked or rotated-away worker, one paired to a different device, and
  an unknown or unbound project are all refused identically — telling them apart
  would itself be a disclosure.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Devices.{LocalWorker, Pairing}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.WorkerSocket

  @doc "Exchanges an authenticated worker credential for a project-scoped gateway credential."
  def create(conn, %{"project_id" => project_id}) when is_binary(project_id) do
    case conn |> bearer() |> exchange(project_id) do
      {:ok, token} -> issued(conn, token)
      {:error, _reason} -> refuse(conn)
    end
  end

  def create(conn, _params), do: refuse(conn)

  defp exchange(nil, _project_id), do: {:error, :unauthorized}

  defp exchange(credential, project_id) do
    with {:ok, worker} <- Pairing.authenticate_worker(credential),
         %HostedLocalRepositoryBinding{} = binding <-
           Repo.get(HostedLocalRepositoryBinding, project_id),
         %LocalWorker{} = owner <- Repo.get(LocalWorker, binding.worker_id),
         :ok <- Pairing.authorize_for_workspace(worker, owner.device_workspace_id) do
      {:ok, WorkerSocket.issue(binding.project_id, worker.id)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  defp issued(conn, token) do
    conn
    |> private_response()
    |> put_status(:ok)
    |> json(%{token: token})
  end

  defp refuse(conn) do
    conn
    |> private_response()
    |> put_status(:forbidden)
    |> json(%{error: "refused"})
  end

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp bearer(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> credential()
  end

  defp credential(header) when is_binary(header) do
    with [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      token
    else
      _malformed -> nil
    end
  end

  defp credential(_header), do: nil
end
