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

  alias SddOrchestrator.Devices.{
    LocalWorker,
    PairingAttempt,
    PairingIssuanceThrottle,
    PairingSecurityLog
  }

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
  Issues a single-use pairing code that belongs to no device workspace yet.

  This is what a worker app calls for itself (`specs/38`). It has never been
  paired, so it has no workspace to name — acquiring one is what pairing does.
  The attempt it creates authorizes nothing: every worker-authorizing path needs
  a bound workspace, and this record has none until an authorized owner redeems
  its code through `redeem_pairing/3`.

  Takes no caller-supplied identity, workspace, project, or secret. The only
  input is the caller key the throttle bounds, and that key is HMAC'd before it
  enters any state.
  """
  @spec issue_unbound_code(:inet.ip_address() | String.t() | nil, keyword()) ::
          {:ok, %{attempt: PairingAttempt.t(), code: String.t()}}
          | {:error, :throttled | Ecto.Changeset.t()}
  def issue_unbound_code(caller, opts \\ []) do
    if PairingIssuanceThrottle.allow?(caller) do
      ttl = Keyword.get(opts, :ttl_seconds, @code_ttl_seconds)
      {secret, salt, digest} = new_secret()

      %PairingAttempt{}
      |> PairingAttempt.create_unbound_changeset(%{
        code_digest: digest,
        code_salt: salt,
        expires_at: seconds_from_now(ttl)
      })
      |> Repo.insert()
      |> case do
        {:ok, attempt} -> {:ok, %{attempt: attempt, code: encode(attempt.id, secret)}}
        {:error, _changeset} = error -> error
      end
    else
      {:error, :throttled}
    end
    |> PairingSecurityLog.audit(:issue_code)
  end

  @doc """
  Binds a pairing code to the workspace the redeemer owns.

  This is the path an authorized owner takes in the dashboard (`specs/38`). It
  is the moment an unbound attempt — one a worker app obtained for itself, with
  no workspace to name — stops being inert and becomes attached to exactly one
  owner.

  Binding is where this stops. It does not create the worker, because the
  dashboard is not the worker: only the app knows its operating-system and
  protocol versions, and only the app should hold its credential. The app
  finishes afterwards through `complete_pairing/2`, exactly as a worker paired
  from a dashboard-issued code already does. An attempt that is bound and not
  yet completed is the ordinary waiting state of every pairing, not a loose
  credential — the code is what completes it, and only its holder has one.

  The bind is a conditional update rather than a read followed by a write, so
  two concurrent redemptions of one code cannot both succeed.

  A code that was issued already bound, by `start_pairing/2` for the dashboard or
  the deep link, is accepted here too, but only against the same workspace it was
  issued for. That is what makes this safe to expose: possessing a code for
  someone else's workspace does not let a redeemer pull it into their own.

  Every refusal answers `{:error, :invalid_code}`. Expired, canceled, already
  bound, belonging to another workspace, malformed, and never existed are
  deliberately indistinguishable, so no answer reveals whether a code was ever
  real. Callers that need the older, more specific reasons keep using
  `complete_pairing/2`, whose contract is unchanged.
  """
  @spec bind_pairing(String.t(), Ecto.UUID.t()) :: :ok | {:error, :invalid_code}
  def bind_pairing(code, device_workspace_id)
      when is_binary(code) and is_binary(device_workspace_id) do
    now = now()

    with {:ok, attempt_id, secret} <- decode(code),
         %PairingAttempt{} = attempt <- Repo.get(PairingAttempt, attempt_id),
         :ok <- bindable(attempt, secret, device_workspace_id, now),
         1 <- claim_attempt(attempt.id, device_workspace_id, now) do
      :ok
    else
      _refused -> {:error, :invalid_code}
    end
  end

  def bind_pairing(_code, _device_workspace_id), do: {:error, :invalid_code}

  # The guard lives in the WHERE clause, so the database decides the winner. An
  # attempt already confirmed, canceled, or bound elsewhere matches no row. An
  # attempt already bound to this same workspace matches and is left as it is,
  # which keeps a repeated submission of a dashboard-issued code harmless.
  defp claim_attempt(attempt_id, device_workspace_id, now) do
    {claimed, _} =
      PairingAttempt
      |> where([a], a.id == ^attempt_id and is_nil(a.confirmed_at) and is_nil(a.canceled_at))
      |> where(
        [a],
        is_nil(a.device_workspace_id) or a.device_workspace_id == ^device_workspace_id
      )
      |> Repo.update_all(set: [device_workspace_id: device_workspace_id, updated_at: now])

    claimed
  end

  defp bindable(
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

  defp bindable(%PairingAttempt{}, _secret, _device_workspace_id, _now), do: :error

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
