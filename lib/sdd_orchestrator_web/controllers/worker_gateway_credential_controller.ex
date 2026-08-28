defmodule SddOrchestratorWeb.WorkerGatewayCredentialController do
  @moduledoc """
  The paired worker's authenticated exchange for a gateway credential.

  This is the first caller of `WorkerSocket.issue/3`: a worker that already holds
  a per-worker pairing credential presents it and receives the short-lived
  gateway credential the delivery gateway already verifies. No second credential
  concept is introduced.

  Two exchanges exist because a worker is authorized for its Mac before it is
  authorized for any project.

  A request naming a project asks for the project- and execution-target-scoped
  credential. A project's local-repository binding names the worker whose device
  workspace was proven to control it (`specs/06-project-portability`); that
  exchange re-checks that the requesting credential's own device workspace still
  matches it.

  A request naming no project asks only for the device workspace the pairing
  credential already proves. A worker paired from the app's menu bar has no
  project yet, so without this it could hold no gateway credential at all and
  could never connect. Naming no project cannot widen what is issued: this
  exchange reads no binding and no project, so it can neither return a
  project-scoped credential nor reveal whether any project or binding exists.

  Every failure of either exchange is answered identically, so a revoked or
  rotated-away worker, one paired to a different device, and an unknown or
  unbound project cannot be told apart — telling them apart would itself be a
  disclosure.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Devices.{LocalWorker, Pairing}
  alias SddOrchestrator.Portability.HostedLocalRepositoryBinding
  alias SddOrchestrator.Repo
  alias SddOrchestratorWeb.WorkerSocket

  @doc "Exchanges an authenticated worker credential for a gateway credential."
  def create(conn, %{"project_id" => project_id}) when is_binary(project_id) do
    case conn |> bearer() |> exchange(project_id) do
      {:ok, token} -> issued(conn, token)
      {:error, _reason} -> refuse(conn)
    end
  end

  # Only a request that names no project at all takes the workspace exchange. A
  # request that names a project it cannot express is still asking about that
  # project, so it is refused rather than quietly answered with a different
  # scope than the caller asked for.
  def create(conn, params) when is_map(params) and not is_map_key(params, "project_id") do
    case conn |> bearer() |> exchange() do
      {:ok, token} -> issued(conn, token)
      {:error, _reason} -> refuse(conn)
    end
  end

  def create(conn, _params), do: refuse(conn)

  defp exchange(nil), do: {:error, :unauthorized}

  # The pairing credential already proves this worker's device workspace, so
  # nothing else has to be looked up — and nothing else is, which is why this
  # exchange cannot answer a question about a project.
  defp exchange(credential) do
    case Pairing.authenticate_worker(credential) do
      {:ok, worker} ->
        {:ok, WorkerSocket.issue({:device_workspace, worker.device_workspace_id}, worker.id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
