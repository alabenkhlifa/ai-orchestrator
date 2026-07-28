defmodule SddOrchestrator.Portability.RestoreIntake do
  @moduledoc """
  Destination-authorized encrypted restore intake and terminal cleanup.

  The passphrase crosses only `begin_validation/3`, which decrypts the package in
  the current call. Incorrect passphrases and every explicit terminal outcome
  delete the encrypted upload and attempt immediately.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Portability.{ImportAttempt, PackageValidator, SecurityLog}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.Vault

  @ttl_seconds 24 * 60 * 60
  @opaque_error {:error, :invalid_package_or_passphrase}

  @spec start(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t(), binary()) ::
          {:ok, ImportAttempt.t()} | {:error, atom() | Ecto.Changeset.t()}
  def start(authority, destination, encrypted_package) do
    authority
    |> do_start(destination, encrypted_package)
    |> SecurityLog.audit(:restore_intake)
  end

  defp do_start(
         %PersonalWorkspace{id: workspace_id},
         "hosted",
         encrypted_package
       )
       when is_binary(encrypted_package) and encrypted_package != "" do
    %ImportAttempt{}
    |> ImportAttempt.hosted_changeset(%{
      workspace_id: workspace_id,
      destination: "hosted",
      status: "uploaded",
      encrypted_package: encrypted_package,
      expires_at: expires_at()
    })
    |> Repo.insert()
  end

  defp do_start(
         %DeviceWorkspace{id: device_workspace_id},
         "device",
         encrypted_package
       )
       when is_binary(encrypted_package) and encrypted_package != "" do
    with {:ok, %DeviceWorkspace{id: ^device_workspace_id}} <- Devices.get_workspace(),
         {:ok, attempt} <- device_attempt(device_workspace_id, encrypted_package),
         {:ok, sealed_package} <- Vault.encrypt(encrypted_package),
         {:ok, _stored} <-
           Devices.put_import_attempt(%{attempt | encrypted_package: sealed_package}) do
      {:ok, attempt}
    else
      _reason -> {:error, :unauthorized_destination}
    end
  end

  defp do_start(_authority, _destination, _encrypted_package),
    do: {:error, :unauthorized_destination}

  @doc "Returns one attempt only through its owning destination authority."
  @spec get(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, ImportAttempt.t()} | {:error, :not_found}
  def get(%PersonalWorkspace{id: workspace_id}, attempt_id) when is_binary(attempt_id) do
    case cast_id(attempt_id) do
      {:ok, id} ->
        case Repo.get_by(ImportAttempt, id: id, workspace_id: workspace_id, destination: "hosted") do
          nil -> {:error, :not_found}
          attempt -> {:ok, attempt}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def get(%DeviceWorkspace{id: authority_id}, attempt_id) when is_binary(attempt_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %ImportAttempt{device_workspace_id: ^authority_id} = stored} <-
           Devices.get_import_attempt(attempt_id),
         {:ok, encrypted_package} <- Vault.decrypt(stored.encrypted_package) do
      {:ok, %{stored | encrypted_package: encrypted_package}}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get(_authority, _attempt_id), do: {:error, :not_found}

  @doc """
  Authenticates and decrypts one intake for validation.

  Failure is deliberately opaque and terminal. Success retains only the
  encrypted upload while returning the decrypted value to the active caller.
  """
  @spec begin_validation(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          String.t(),
          String.t()
        ) :: {:ok, ImportAttempt.t(), struct()} | {:error, :invalid_package_or_passphrase}
  def begin_validation(authority, attempt_id, passphrase) do
    result =
      with {:ok, attempt} <- get(authority, attempt_id),
           {:ok, package} <-
             PackageValidator.decrypt_and_validate(attempt.encrypted_package, passphrase),
           {:ok, validating} <- mark_validating(authority, attempt) do
        {:ok, validating, package}
      else
        {:error, reason} ->
          _ = delete(authority, attempt_id)
          if reason == :invalid_package_or_passphrase, do: @opaque_error, else: {:error, reason}

        _reason ->
          _ = delete(authority, attempt_id)
          @opaque_error
      end

    SecurityLog.audit(result, :restore_validation)
  end

  @doc "Cancels one authorized attempt and immediately deletes its encrypted upload."
  def cancel(authority, attempt_id) do
    authority
    |> delete(attempt_id)
    |> SecurityLog.audit(:restore_cancellation)
  end

  @doc "Deletes one failed attempt and its encrypted upload."
  def fail(authority, attempt_id) do
    authority
    |> delete(attempt_id)
    |> SecurityLog.audit(:restore_failure_cleanup)
  end

  @doc "Deletes one successfully consumed attempt and its encrypted upload."
  def complete(authority, attempt_id) do
    authority
    |> delete(attempt_id)
    |> SecurityLog.audit(:restore_completion_cleanup)
  end

  defp mark_validating(%PersonalWorkspace{}, %ImportAttempt{} = attempt) do
    attempt |> ImportAttempt.validation_changeset() |> Repo.update()
  end

  defp mark_validating(%DeviceWorkspace{}, %ImportAttempt{} = attempt) do
    with {:ok, sealed_package} <- Vault.encrypt(attempt.encrypted_package),
         validating <- %{attempt | encrypted_package: sealed_package, status: "validating"},
         {:ok, _stored} <- Devices.put_import_attempt(validating) do
      {:ok, %{validating | encrypted_package: attempt.encrypted_package}}
    end
  end

  defp delete(%PersonalWorkspace{id: workspace_id}, attempt_id) do
    with {:ok, attempt} <- get(%PersonalWorkspace{id: workspace_id}, attempt_id),
         {:ok, _deleted} <- Repo.delete(attempt) do
      :ok
    else
      _reason -> :ok
    end
  end

  defp delete(%DeviceWorkspace{id: authority_id}, attempt_id) do
    case Devices.get_workspace() do
      {:ok, %DeviceWorkspace{id: ^authority_id}} ->
        _ = Devices.delete_import_attempt(attempt_id)
        :ok

      _reason ->
        :ok
    end
  end

  defp delete(_authority, _attempt_id), do: :ok

  defp device_attempt(device_workspace_id, encrypted_package) do
    now = now()

    %ImportAttempt{
      id: Ecto.UUID.generate(),
      device_workspace_id: device_workspace_id,
      destination: "device",
      status: "uploaded",
      encrypted_package: encrypted_package,
      expires_at: DateTime.add(now, @ttl_seconds, :second),
      inserted_at: now,
      updated_at: now
    }
    |> ImportAttempt.device_changeset(%{})
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp cast_id(id), do: Ecto.UUID.cast(id)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp expires_at, do: DateTime.add(now(), @ttl_seconds, :second)
end
