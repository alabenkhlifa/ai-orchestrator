defmodule SddOrchestrator.Devices.Pairing do
  @moduledoc """
  Workspace-bound pairing between the control plane and a device worker.

  A dashboard issues a single-use, attempt-bound pairing code for one device
  workspace; the worker completes pairing to receive a per-worker credential
  returned exactly once. A credential authorizes exactly one workspace and is
  rotatable and revocable. Only authorization metadata is persisted — the raw
  code and credential exist transiently and, on the worker, in its keychain.

  Codes and credentials are transported as `"<id>.<secret>"`: the id selects the
  row, the secret is verified in constant time against a per-row salted digest.
  """
  import Ecto.Query, warn: false

  alias SddOrchestrator.Devices.{LocalWorker, PairingAttempt}
  alias SddOrchestrator.Repo

  @code_ttl_seconds 10 * 60
  @secret_bytes 32
  @salt_bytes 16

  @doc "Issues a single-use pairing code for a device workspace. Returns the raw code once."
  @spec start_pairing(Ecto.UUID.t(), keyword()) ::
          {:ok, %{attempt: PairingAttempt.t(), code: String.t()}} | {:error, term()}
  def start_pairing(device_workspace_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_seconds, @code_ttl_seconds)
    {secret, salt, digest} = new_secret()

    attrs = %{
      device_workspace_id: device_workspace_id,
      code_digest: digest,
      code_salt: salt,
      expires_at: seconds_from_now(ttl)
    }

    with {:ok, attempt} <-
           %PairingAttempt{} |> PairingAttempt.create_changeset(attrs) |> Repo.insert() do
      {:ok, %{attempt: attempt, code: encode(attempt.id, secret)}}
    end
  end

  @doc """
  Completes a pairing from a raw code, issuing a per-worker credential (returned
  once). Rejects expired, already-used, canceled, or invalid codes.
  """
  @spec complete_pairing(String.t(), map()) ::
          {:ok, %{worker: LocalWorker.t(), credential: String.t()}} | {:error, term()}
  def complete_pairing(code, worker_attrs \\ %{}) do
    now = now()

    with {:ok, attempt_id, secret} <- decode(code),
         %PairingAttempt{} = attempt <- Repo.get(PairingAttempt, attempt_id),
         :ok <- verify_attempt(attempt, secret, now) do
      {credential, salt, digest} = new_secret()

      Repo.transaction(fn ->
        worker =
          %LocalWorker{}
          |> LocalWorker.create_changeset(
            Map.merge(worker_attrs, %{
              device_workspace_id: attempt.device_workspace_id,
              credential_digest: digest,
              credential_salt: salt,
              state: "active"
            })
          )
          |> Repo.insert!()

        attempt
        |> Ecto.Changeset.change(confirmed_at: now, worker_id: worker.id)
        |> Repo.update!()

        %{worker: worker, credential: encode(worker.id, credential)}
      end)
    else
      nil -> {:error, :invalid_or_used}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Redeems a pairing code against the workspace the redeemer owns.

  This is the path an authorized owner takes in the dashboard (`specs/38`). It
  is the moment an unbound attempt — one a worker app obtained for itself, with
  no workspace to name — stops being inert. Binding the workspace and creating
  the worker happen in one transaction, because an attempt that is bound but not
  completed would be a workspace-attached credential nobody is holding.

  The claim is a conditional update rather than a read followed by a write, so
  two concurrent redemptions of one code cannot both succeed. The loser's worker
  row is rolled back with the transaction.

  A code that was issued already bound, by `start_pairing/2` for the dashboard or
  the deep link, is redeemable here too, but only against the same workspace it
  was issued for. That is what makes this safe to expose: possessing a code for
  someone else's workspace does not let a redeemer pull it into their own.

  Every refusal answers `{:error, :invalid_code}`. Expired, canceled, already
  redeemed, belonging to another workspace, malformed, and never existed are
  deliberately indistinguishable, so no answer reveals whether a code was ever
  real. Callers that need the older, more specific reasons keep using
  `complete_pairing/2`, whose contract is unchanged.
  """
  @spec redeem_pairing(String.t(), Ecto.UUID.t(), map()) ::
          {:ok, %{worker: LocalWorker.t(), credential: String.t()}} | {:error, :invalid_code}
  def redeem_pairing(code, device_workspace_id, worker_attrs \\ %{})

  def redeem_pairing(code, device_workspace_id, worker_attrs)
      when is_binary(code) and is_binary(device_workspace_id) do
    now = now()

    with {:ok, attempt_id, secret} <- decode(code),
         %PairingAttempt{} = attempt <- Repo.get(PairingAttempt, attempt_id),
         :ok <- redeemable(attempt, secret, device_workspace_id, now),
         {:ok, result} <-
           Repo.transaction(fn ->
             bind_and_pair(attempt, device_workspace_id, worker_attrs, now)
           end) do
      {:ok, result}
    else
      _refused -> {:error, :invalid_code}
    end
  end

  def redeem_pairing(_code, _device_workspace_id, _worker_attrs), do: {:error, :invalid_code}

  # Creates the worker first so the claim can name it, then claims the attempt.
  # Losing the claim rolls the worker back, so a lost race leaves nothing behind.
  defp bind_and_pair(attempt, device_workspace_id, worker_attrs, now) do
    {credential, salt, digest} = new_secret()

    worker =
      %LocalWorker{}
      |> LocalWorker.create_changeset(
        Map.merge(worker_attrs, %{
          device_workspace_id: device_workspace_id,
          credential_digest: digest,
          credential_salt: salt,
          state: "active"
        })
      )
      |> Repo.insert!()

    case claim_attempt(attempt.id, device_workspace_id, worker.id, now) do
      1 -> %{worker: worker, credential: encode(worker.id, credential)}
      _lost -> Repo.rollback(:invalid_code)
    end
  end

  # The guard lives in the WHERE clause, so the database decides the winner. An
  # attempt already confirmed, canceled, or bound elsewhere matches no row.
  defp claim_attempt(attempt_id, device_workspace_id, worker_id, now) do
    {claimed, _} =
      PairingAttempt
      |> where([a], a.id == ^attempt_id and is_nil(a.confirmed_at) and is_nil(a.canceled_at))
      |> where(
        [a],
        is_nil(a.device_workspace_id) or a.device_workspace_id == ^device_workspace_id
      )
      |> Repo.update_all(
        set: [
          device_workspace_id: device_workspace_id,
          confirmed_at: now,
          worker_id: worker_id,
          updated_at: now
        ]
      )

    claimed
  end

  defp redeemable(
         %PairingAttempt{confirmed_at: nil, canceled_at: nil} = attempt,
         secret,
         device_workspace_id,
         now
       ) do
    cond do
      DateTime.compare(now, attempt.expires_at) != :lt -> :error
      not secret_matches?(attempt.code_digest, attempt.code_salt, secret) -> :error
      not bindable_to?(attempt, device_workspace_id) -> :error
      true -> :ok
    end
  end

  defp redeemable(%PairingAttempt{}, _secret, _device_workspace_id, _now), do: :error

  defp bindable_to?(%PairingAttempt{device_workspace_id: nil}, _device_workspace_id), do: true

  defp bindable_to?(%PairingAttempt{device_workspace_id: bound}, device_workspace_id),
    do: bound == device_workspace_id

  @doc """
  Lists the active (non-revoked) workers paired to one device workspace.

  Worker discovery reads this set to decide whether a compatible, reachable
  worker is available. Revoked workers are excluded because they can no longer
  authorize filesystem access.
  """
  @spec active_workers(Ecto.UUID.t()) :: [LocalWorker.t()]
  def active_workers(device_workspace_id) do
    LocalWorker
    |> where([w], w.device_workspace_id == ^device_workspace_id and w.state == "active")
    |> Repo.all()
  end

  @doc """
  Records a worker heartbeat by stamping `last_seen_at`.

  Worker liveness is modeled through this timestamp: the native worker refreshes
  it over its outbound transport (release-gated), and discovery treats a recent
  value as reachable. Returns the worker unchanged if it is not active.
  """
  @spec mark_seen(LocalWorker.t()) :: {:ok, LocalWorker.t()} | {:error, Ecto.Changeset.t()}
  def mark_seen(%LocalWorker{state: "active"} = worker) do
    worker |> Ecto.Changeset.change(last_seen_at: now()) |> Repo.update()
  end

  def mark_seen(%LocalWorker{} = worker), do: {:ok, worker}

  @doc "Authenticates an inbound worker by its credential. Only active workers pass."
  @spec authenticate_worker(String.t()) :: {:ok, LocalWorker.t()} | {:error, :unauthorized}
  def authenticate_worker(credential) do
    with {:ok, worker_id, secret} <- decode(credential),
         %LocalWorker{state: "active"} = worker <- Repo.get(LocalWorker, worker_id),
         true <- secret_matches?(worker.credential_digest, worker.credential_salt, secret) do
      {:ok, worker}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Confirms a worker credential authorizes the given workspace and no other."
  @spec authorize_for_workspace(LocalWorker.t(), Ecto.UUID.t()) ::
          :ok | {:error, :cross_workspace}
  def authorize_for_workspace(%LocalWorker{state: "active", device_workspace_id: id}, id), do: :ok
  def authorize_for_workspace(%LocalWorker{}, _workspace_id), do: {:error, :cross_workspace}

  @doc "Revokes a worker credential; future authentication fails."
  @spec revoke_worker(LocalWorker.t()) :: {:ok, LocalWorker.t()} | {:error, Ecto.Changeset.t()}
  def revoke_worker(%LocalWorker{} = worker) do
    worker |> LocalWorker.revoke_changeset(now()) |> Repo.update()
  end

  @doc "Rotates an active worker's credential in place, returning the new raw credential once."
  @spec rotate_credential(LocalWorker.t()) ::
          {:ok, %{worker: LocalWorker.t(), credential: String.t()}} | {:error, term()}
  def rotate_credential(%LocalWorker{state: "active"} = worker) do
    {secret, salt, digest} = new_secret()

    with {:ok, rotated} <-
           worker
           |> LocalWorker.rotate_changeset(%{credential_digest: digest, credential_salt: salt})
           |> Repo.update() do
      {:ok, %{worker: rotated, credential: encode(rotated.id, secret)}}
    end
  end

  def rotate_credential(%LocalWorker{}), do: {:error, :revoked}

  # ---- internals ----

  defp verify_attempt(%PairingAttempt{confirmed_at: nil, canceled_at: nil} = attempt, secret, now) do
    cond do
      DateTime.compare(now, attempt.expires_at) != :lt ->
        {:error, :expired}

      not secret_matches?(attempt.code_digest, attempt.code_salt, secret) ->
        {:error, :invalid_or_used}

      true ->
        :ok
    end
  end

  defp verify_attempt(%PairingAttempt{}, _secret, _now), do: {:error, :invalid_or_used}

  defp new_secret do
    secret = :crypto.strong_rand_bytes(@secret_bytes)
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    {Base.url_encode64(secret, padding: false), salt, :crypto.hash(:sha256, salt <> secret)}
  end

  defp secret_matches?(digest, salt, secret_b64) do
    case Base.url_decode64(secret_b64, padding: false) do
      {:ok, secret} -> Plug.Crypto.secure_compare(digest, :crypto.hash(:sha256, salt <> secret))
      :error -> false
    end
  end

  defp encode(id, secret_b64), do: "#{id}.#{secret_b64}"

  defp decode(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [id, secret] when byte_size(id) > 0 and byte_size(secret) > 0 ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> {:ok, uuid, secret}
          :error -> {:error, :invalid_or_used}
        end

      _ ->
        {:error, :invalid_or_used}
    end
  end

  defp decode(_value), do: {:error, :invalid_or_used}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp seconds_from_now(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end
end
