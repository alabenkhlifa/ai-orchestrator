defmodule SddOrchestratorWeb.PairingCodeController do
  @moduledoc """
  Anonymous issuance of a pairing code that belongs to no workspace yet.

  A worker app that has never been paired holds no credential and knows no
  workspace, because acquiring one is what pairing does. It therefore cannot
  authenticate to ask for a code, and this endpoint does not ask it to.

  What makes that safe is not who calls it but what the call produces: an
  attempt bound to nothing. It names no person, no machine, and no workspace,
  and it authorizes nothing anywhere until an owner redeems its code against
  their own workspace in the dashboard. A code intercepted here is worth
  nothing to whoever intercepts it.

  The request body is ignored entirely. A caller cannot name a workspace, a
  project, an identity, or its own secret, so nothing it sends can widen what it
  gets back. The only bound is the throttle, keyed on the caller's address and
  HMAC'd before it is stored.

  The issued code is returned once and never logged. The audit entry records
  that a code was issued or refused and nothing about who asked.
  """
  use SddOrchestratorWeb, :controller

  alias SddOrchestrator.Devices.Pairing

  @doc """
  Issues one unbound pairing code, or refuses when the caller is over its rate.

  Answers `429` for a throttled caller and `503` when the code could not be
  created at all. Neither answer says anything about a code the caller obtained
  earlier, because neither reads one.
  """
  def create(conn, _params) do
    case Pairing.issue_unbound_code(caller(conn)) do
      {:ok, %{code: code, attempt: attempt}} ->
        conn
        |> private_response()
        |> put_status(:created)
        |> json(%{code: code, expires_at: attempt.expires_at})

      {:error, :throttled} ->
        conn
        |> private_response()
        |> put_status(:too_many_requests)
        |> json(%{error: "refused"})

      {:error, _reason} ->
        conn
        |> private_response()
        |> put_status(:service_unavailable)
        |> json(%{error: "refused"})
    end
  end

  # The peer address only ever becomes an HMAC key inside the throttle, and is
  # never stored, logged, or returned.
  defp caller(conn), do: conn.remote_ip

  defp private_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
