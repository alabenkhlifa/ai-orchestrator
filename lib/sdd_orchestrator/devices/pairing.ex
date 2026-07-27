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
