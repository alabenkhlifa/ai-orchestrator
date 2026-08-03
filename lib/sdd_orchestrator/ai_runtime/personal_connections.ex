defmodule SddOrchestrator.AIRuntime.PersonalConnections do
  @moduledoc """
  Account-scoped lifecycle boundary for personal AI connections.

  Linking re-authorizes the current account and paired worker, validates an
  exact adapter projection, and persists only the minimized opaque binding.
  Consumer resolution always requires an explicit connection id; this module
  has no funded or implicit fallback path.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    PersonalAIConnection,
    PersonalConnectionAdapter
  }

  alias SddOrchestrator.AIRuntime.PersonalConnectionAdapter.RPC
  alias SddOrchestrator.Devices.LocalWorker
  alias SddOrchestrator.Repo

  @consumer_kinds [:support_assistant, :working_agent]
  @link_keys [:label, :provider, :authentication_mode]

  @doc "Links one labelled worker-local profile after current authority checks."
  @spec link_personal_connection(
          Account.t() | Ecto.UUID.t(),
          LocalWorker.t() | Ecto.UUID.t(),
          map(),
          keyword()
        ) ::
          {:ok, PersonalAIConnection.t()}
          | {:error,
             :account_unavailable
             | :worker_unavailable
             | :invalid_connection
             | :binding_mismatch
             | :label_taken
             | :profile_already_linked
             | PersonalConnectionAdapter.error()}
  def link_personal_connection(account_or_id, worker_or_id, attrs, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, RPC)

    with {:ok, account_id} <- entity_id(account_or_id, Account),
         {:ok, worker_id} <- entity_id(worker_or_id, LocalWorker),
         {:ok, request} <- normalize_link_request(attrs),
         %Account{} = account <- active_account(account_id),
         %LocalWorker{} = worker <- active_worker(worker_id),
         {:ok, result} <- call_adapter(adapter, account, worker, request, opts),
         {:ok, safe_result} <- PersonalConnectionAdapter.validate_result(result, request) do
      persist_link(account_id, worker_id, request.label, safe_result)
    else
      nil -> {:error, :account_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Short alias for `link_personal_connection/4`."
  def link_connection(account_or_id, worker_or_id, attrs, opts \\ []),
    do: link_personal_connection(account_or_id, worker_or_id, attrs, opts)

  @doc "Lists only records owned by the supplied currently active account."
  @spec list_personal_connections(Account.t() | Ecto.UUID.t()) :: [PersonalAIConnection.t()]
  def list_personal_connections(account_or_id) do
    with {:ok, account_id} <- entity_id(account_or_id, Account),
         %Account{} <- active_account(account_id) do
      PersonalAIConnection
      |> where([connection], connection.account_id == ^account_id)
      |> order_by([connection], asc: fragment("lower(?)", connection.label), asc: connection.id)
      |> Repo.all()
    else
      _ -> []
    end
  end

  @doc "Short alias for `list_personal_connections/1`."
  def list_connections(account_or_id), do: list_personal_connections(account_or_id)

  @doc "Gets one record only through its owning active-account scope."
  @spec get_personal_connection(Account.t() | Ecto.UUID.t(), Ecto.UUID.t()) ::
          PersonalAIConnection.t() | nil
  def get_personal_connection(account_or_id, connection_id) do
    with {:ok, account_id} <- entity_id(account_or_id, Account),
         {:ok, connection_id} <- cast_id(connection_id),
         %Account{} <- active_account(account_id) do
      Repo.one(
        from connection in PersonalAIConnection,
          where: connection.account_id == ^account_id and connection.id == ^connection_id
      )
    else
      _ -> nil
    end
  end

  @doc "Short alias for `get_personal_connection/2`."
  def get_connection(account_or_id, connection_id),
    do: get_personal_connection(account_or_id, connection_id)

  @doc "Renames one connection inside its active owning-account scope."
  @spec rename_personal_connection(
          Account.t() | Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t()
        ) ::
          {:ok, PersonalAIConnection.t()}
          | {:error, :not_found | :invalid_label | :label_taken}
  def rename_personal_connection(account_or_id, connection_id, label) do
    with {:ok, label} <- normalize_label(label),
         {:ok, account_id} <- entity_id(account_or_id, Account),
         {:ok, connection_id} <- cast_id(connection_id),
         %Account{} <- active_account(account_id) do
      Repo.transaction(fn ->
        case locked_scoped_connection(account_id, connection_id) do
          nil -> Repo.rollback(:not_found)
          connection -> update_label(connection, label)
        end
      end)
      |> unwrap_transaction()
    else
      {:error, :invalid_label} -> {:error, :invalid_label}
      _ -> {:error, :not_found}
    end
  end

  @doc "Short alias for `rename_personal_connection/3`."
  def rename_connection(account_or_id, connection_id, label),
    do: rename_personal_connection(account_or_id, connection_id, label)

  @doc "Resolves one explicitly selected eligible connection for either runtime consumer."
  @spec resolve_for_consumer(
          Account.t() | Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          :support_assistant | :working_agent | String.t()
        ) ::
          {:ok, map()}
          | {:error,
             :connection_required
             | :invalid_consumer
             | :not_found
             | :unavailable
             | :incompatible
             | :revoking
             | :revoked}
  def resolve_for_consumer(_account_or_id, nil, _consumer),
    do: {:error, :connection_required}

  def resolve_for_consumer(account_or_id, connection_id, consumer) do
    with {:ok, _consumer} <- normalize_consumer(consumer),
         %PersonalAIConnection{} = connection <-
           get_personal_connection(account_or_id, connection_id),
         :ok <- eligible(connection) do
      {:ok, stable_reference(connection)}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resolves an explicit support-assistant connection selection."
  def resolve_support_connection(account_or_id, connection_id),
    do: resolve_for_consumer(account_or_id, connection_id, :support_assistant)

  @doc "Resolves an explicit working-agent connection selection."
  def resolve_working_agent_connection(account_or_id, connection_id),
    do: resolve_for_consumer(account_or_id, connection_id, :working_agent)

  @doc "Idempotently records that the owning account requested revocation."
  @spec request_revocation(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, PersonalAIConnection.t()} | {:error, :not_found}
  def request_revocation(account_or_id, connection_id, opts \\ []) do
    transition_revocation(account_or_id, connection_id, :request, opts)
  end

  @doc "Idempotently acknowledges a previously requested worker-local revocation."
  @spec acknowledge_revocation(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, PersonalAIConnection.t()}
          | {:error, :not_found | :revocation_not_requested}
  def acknowledge_revocation(account_or_id, connection_id, opts \\ []) do
    transition_revocation(account_or_id, connection_id, :acknowledge, opts)
  end

  defp persist_link(account_id, worker_id, label, result) do
    Repo.transaction(fn ->
      with %Account{} <- active_account(account_id, lock: true),
           %LocalWorker{} <- active_worker(worker_id, lock: true) do
        case connection_for_profile(worker_id, result.worker_profile_ref) do
          %PersonalAIConnection{account_id: ^account_id} = existing ->
            if same_binding?(existing, result),
              do: existing,
              else: Repo.rollback(:binding_mismatch)

          %PersonalAIConnection{} ->
            Repo.rollback(:profile_already_linked)

          nil ->
            insert_connection(account_id, worker_id, label, result)
        end
      else
        nil -> Repo.rollback(:account_unavailable)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp insert_connection(account_id, worker_id, label, result) do
    attrs = %{
      account_id: account_id,
      worker_id: worker_id,
      worker_profile_ref: result.worker_profile_ref,
      label: label,
      provider: result.provider,
      authentication_mode: result.authentication_mode,
      availability: result.availability,
      adapter_compatibility_version: result.adapter_compatibility_version,
      revocation_state: "active"
    }

    case %PersonalAIConnection{}
         |> PersonalAIConnection.create_changeset(attrs)
         |> Repo.insert() do
      {:ok, connection} ->
        connection

      {:error, changeset} ->
        resolve_insert_conflict(changeset, account_id, worker_id, result)
    end
  end

  defp resolve_insert_conflict(changeset, account_id, worker_id, result) do
    cond do
      Keyword.has_key?(changeset.errors, :worker_profile_ref) ->
        case connection_for_profile(worker_id, result.worker_profile_ref) do
          %PersonalAIConnection{account_id: ^account_id} = existing ->
            if same_binding?(existing, result),
              do: existing,
              else: Repo.rollback(:binding_mismatch)

          %PersonalAIConnection{} ->
            Repo.rollback(:profile_already_linked)

          nil ->
            Repo.rollback(:invalid_connection)
        end

      Keyword.has_key?(changeset.errors, :label) ->
        Repo.rollback(:label_taken)

      true ->
        Repo.rollback(:invalid_connection)
    end
  end

  defp transition_revocation(account_or_id, connection_id, transition, opts) do
    with {:ok, account_id} <- entity_id(account_or_id, Account),
         {:ok, connection_id} <- cast_id(connection_id) do
      requested_at = Keyword.get(opts, :at, now()) |> DateTime.truncate(:second)

      Repo.transaction(fn ->
        case locked_scoped_connection(account_id, connection_id) do
          nil ->
            Repo.rollback(:not_found)

          connection ->
            apply_revocation_transition(connection, transition, requested_at)
        end
      end)
      |> unwrap_transaction()
    else
      _ -> {:error, :not_found}
    end
  end

  defp update_label(connection, label) do
    case connection
         |> PersonalAIConnection.update_changeset(%{label: label})
         |> Repo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        if Enum.any?(changeset.errors, fn
             {:label, {_message, metadata}} -> metadata[:constraint] == :unique
             _other -> false
           end) do
          Repo.rollback(:label_taken)
        else
          Repo.rollback(:invalid_label)
        end
    end
  end

  defp normalize_label(label) when is_binary(label) do
    label = String.trim(label)

    if String.length(label) in 1..PersonalAIConnection.label_max_length(),
      do: {:ok, label},
      else: {:error, :invalid_label}
  end

  defp normalize_label(_label), do: {:error, :invalid_label}

  defp apply_revocation_transition(%{revocation_state: "active"} = connection, :request, at) do
    connection
    |> PersonalAIConnection.update_changeset(%{
      revocation_state: "requested",
      revocation_requested_at: at
    })
    |> Repo.update!()
  end

  defp apply_revocation_transition(%{revocation_state: state} = connection, :request, _at)
       when state in ["requested", "acknowledged"],
       do: connection

  defp apply_revocation_transition(
         %{revocation_state: "requested"} = connection,
         :acknowledge,
         at
       ) do
    connection
    |> PersonalAIConnection.update_changeset(%{
      revocation_state: "acknowledged",
      revocation_acknowledged_at: at
    })
    |> Repo.update!()
  end

  defp apply_revocation_transition(
         %{revocation_state: "acknowledged"} = connection,
         :acknowledge,
         _at
       ),
       do: connection

  defp apply_revocation_transition(%{revocation_state: "active"}, :acknowledge, _at),
    do: Repo.rollback(:revocation_not_requested)

  defp call_adapter(adapter, account, worker, request, opts) do
    adapter_opts = Keyword.delete(opts, :adapter)

    try do
      case adapter.link(
             account,
             worker,
             Map.take(request, [:provider, :authentication_mode]),
             adapter_opts
           ) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, PersonalConnectionAdapter.normalize_error(reason)}
        _other -> {:error, :invalid_response}
      end
    rescue
      _exception -> {:error, :invalid_response}
    catch
      _kind, _reason -> {:error, :invalid_response}
    end
  end

  defp normalize_link_request(attrs) when is_map(attrs) do
    with {:ok, normalized} <- exact_link_fields(attrs),
         true <- is_binary(normalized.label),
         label = String.trim(normalized.label),
         true <- String.length(label) in 1..PersonalAIConnection.label_max_length(),
         true <- normalized.provider in PersonalAIConnection.providers(),
         true <- normalized.authentication_mode in PersonalAIConnection.authentication_modes() do
      {:ok, %{normalized | label: label}}
    else
      _ -> {:error, :invalid_connection}
    end
  end

  defp normalize_link_request(_attrs), do: {:error, :invalid_connection}

  defp exact_link_fields(attrs) do
    cond do
      Enum.sort(Map.keys(attrs)) == Enum.sort(@link_keys) ->
        {:ok,
         %{
           label: attrs.label,
           provider: attrs.provider,
           authentication_mode: attrs.authentication_mode
         }}

      Enum.sort(Map.keys(attrs)) == Enum.sort(Enum.map(@link_keys, &Atom.to_string/1)) ->
        {:ok,
         %{
           label: attrs["label"],
           provider: attrs["provider"],
           authentication_mode: attrs["authentication_mode"]
         }}

      true ->
        {:error, :invalid_connection}
    end
  end

  defp normalize_consumer(consumer) when consumer in @consumer_kinds, do: {:ok, consumer}
  defp normalize_consumer("support_assistant"), do: {:ok, :support_assistant}
  defp normalize_consumer("support-assistant"), do: {:ok, :support_assistant}
  defp normalize_consumer("working_agent"), do: {:ok, :working_agent}
  defp normalize_consumer("working-agent"), do: {:ok, :working_agent}
  defp normalize_consumer(_consumer), do: {:error, :invalid_consumer}

  defp eligible(%{revocation_state: "requested"}), do: {:error, :revoking}
  defp eligible(%{revocation_state: "acknowledged"}), do: {:error, :revoked}
  defp eligible(%{availability: "unavailable"}), do: {:error, :unavailable}
  defp eligible(%{availability: "incompatible"}), do: {:error, :incompatible}
  defp eligible(%{revocation_state: "active", availability: "available"}), do: :ok

  defp stable_reference(connection) do
    %{
      connection_id: connection.id,
      worker_id: connection.worker_id,
      provider: connection.provider,
      authentication_mode: connection.authentication_mode,
      availability: connection.availability,
      adapter_compatibility_version: connection.adapter_compatibility_version
    }
  end

  defp active_account(account_id, opts \\ []) do
    query = from account in Account, where: account.id == ^account_id and account.state == :active
    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp active_worker(worker_id, opts \\ []) do
    query =
      from worker in LocalWorker,
        where: worker.id == ^worker_id and worker.state == "active"

    case Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query) do
      nil -> {:error, :worker_unavailable}
      worker -> worker
    end
  end

  defp connection_for_profile(worker_id, worker_profile_ref) do
    Repo.one(
      from connection in PersonalAIConnection,
        where:
          connection.worker_id == ^worker_id and
            connection.worker_profile_ref == ^worker_profile_ref
    )
  end

  defp same_binding?(connection, result) do
    connection.provider == result.provider and
      connection.authentication_mode == result.authentication_mode
  end

  defp locked_scoped_connection(account_id, connection_id) do
    Repo.one(
      from connection in PersonalAIConnection,
        where: connection.account_id == ^account_id and connection.id == ^connection_id,
        lock: "FOR UPDATE"
    )
  end

  defp entity_id(%{__struct__: module, id: id}, module), do: cast_id(id)
  defp entity_id(id, _module), do: cast_id(id)

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_connection}
    end
  end

  defp cast_id(_id), do: {:error, :invalid_connection}

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
