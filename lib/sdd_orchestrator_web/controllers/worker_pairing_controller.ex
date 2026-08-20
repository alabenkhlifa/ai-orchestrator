defmodule SddOrchestratorWeb.WorkerPairingController do
  @moduledoc """
  The network-facing completion of a dashboard-issued pairing code.

  A native worker is a genuinely separate process with no local database and,
  before this exchange, no credential of any kind — only the single-use code a
  dashboard operator typed in or scanned. This is therefore the one endpoint in
  the control plane that authenticates a caller by nothing but that code, and it
  exists precisely so a worker never needs to run this repository's own
  application (compare `Mix.Tasks.Worker.Pair`, the developer-run form factor
  that completes the same exchange in-process).

  `SddOrchestrator.Devices.Pairing.complete_pairing/2` is called unchanged. Every
  refusal — an expired code, an already-used code, an unknown or malformed code,
  and a malformed request — is answered identically, so none of them can be told
  apart from outside; the pairing secret is already a 32-byte random value
  compared in constant time, so this is the only defense the endpoint needs. The
  raw code is never logged, matching `Mix.Tasks.Worker.Pair`'s own convention of
  never printing pairing material.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Devices.Pairing

  @worker_attr_keys ~w(os_family os_major protocol_version app_version)

  @doc """
  Completes pairing from a raw code and the caller's own worker attributes
  (`os_family`, `os_major`, `protocol_version`, `app_version` — a real worker
  reports these about itself; nothing here is read from this application's own
  build). Issues the worker credential and identity on success.
  """
  def create(conn, %{"code" => code} = params) when is_binary(code) do
    case worker_attrs(params) do
      {:ok, attrs} ->
        case Pairing.complete_pairing(code, attrs) do
          {:ok, pairing_result} -> completed(conn, pairing_result)
          {:error, _reason} -> refuse(conn)
        end

      :error ->
        refuse(conn)
    end
  end

  def create(conn, _params), do: refuse(conn)

  # Every optional descriptor is taken only when the caller sent it as a string;
  # anything else about the request shape is treated as malformed rather than
  # coerced, so a badly typed request is refused instead of silently accepted
  # with a dropped field.
  defp worker_attrs(params) do
    Enum.reduce_while(@worker_attr_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(params, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, value} when is_binary(value) ->
          {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), value)}}

        {:ok, _other} ->
          {:halt, :error}
      end
    end)
  end

  defp completed(conn, %{worker: worker, credential: credential}) do
    conn
    |> private_response()
    |> put_status(:created)
    |> json(%{
      credential: credential,
      worker: %{
        id: worker.id,
        device_workspace_id: worker.device_workspace_id,
        os_family: worker.os_family,
        os_major: worker.os_major,
        protocol_version: worker.protocol_version,
        app_version: worker.app_version,
        state: worker.state
      }
    })
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
end
