defmodule SddOrchestrator.AIRuntime.ModelCatalogs do
  @moduledoc """
  Account-scoped refresh, persistence, and selection boundary for live catalogs.

  A refresh re-authorizes the connection, validates one exact adapter result,
  and stores only minimized compatibility and provenance facts. Reads and
  selection checks refuse expired snapshots and unknown compatibility.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    ModelCatalogAdapter,
    ModelCatalogSnapshot,
    PersonalAIConnection
  }

  alias SddOrchestrator.AIRuntime.ModelCatalogAdapter.RPC
  alias SddOrchestrator.Repo

  @default_ttl_seconds 300
  @max_ttl_seconds 3_600
  @max_clock_skew_seconds 60

  @doc "Refreshes one authenticated connection and persists its minimized catalog."
  @spec refresh(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()}
          | {:error,
             :account_unavailable
             | :not_found
             | :unavailable
             | :incompatible
             | :revoking
             | :revoked
             | :stale
             | ModelCatalogAdapter.error()}
  def refresh(account_or_id, connection_id, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, RPC)

    with {:ok, account_id} <- entity_id(account_or_id),
         {:ok, connection_id} <- cast_id(connection_id),
         {:ok, {account, connection}} <- prepare_refresh(account_id, connection_id),
         {:ok, result} <- call_adapter(adapter, account, connection, opts),
         {:ok, result} <- ModelCatalogAdapter.validate_result(result, connection.provider),
         false <- contains_value?(result, connection.worker_profile_ref),
         {:ok, now} <- normalized_now(opts),
         {:ok, ttl_seconds} <- ttl_seconds(opts),
         {:ok, expires_at} <- validate_retrieval_time(result.retrieved_at, now, ttl_seconds),
         {:ok, snapshot} <- persist(account_id, connection_id, result, expires_at),
         {:ok, projection} <- project(snapshot, now) do
      {:ok, projection}
    else
      true -> {:error, :invalid_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the latest unexpired safe catalog projection for one owned connection."
  @spec current_catalog(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, :account_unavailable | :not_found | :unknown | :stale}
  def current_catalog(account_or_id, connection_id, opts \\ []) do
    with {:ok, account_id} <- entity_id(account_or_id),
         {:ok, _account} <- fetch_active_account(account_id),
         {:ok, connection_id} <- cast_id(connection_id),
         {:ok, _connection} <- fetch_scoped_connection(account_id, connection_id),
         %ModelCatalogSnapshot{} = snapshot <- latest_snapshot(account_id, connection_id),
         {:ok, now} <- normalized_now(opts),
         {:ok, projection} <- project(snapshot, now) do
      {:ok, projection}
    else
      nil -> {:error, :unknown}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Requires an explicit proven model and compatible reasoning effort."
  @spec validate_selection(
          Account.t() | Ecto.UUID.t(),
          Ecto.UUID.t(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()}
          | {:error,
             :account_unavailable
             | :not_found
             | :unavailable
             | :incompatible
             | :revoking
             | :revoked
             | :unknown
             | :stale
             | :invalid_selection
             | :unknown_compatibility}
  def validate_selection(account_or_id, connection_id, model, effort, opts \\ []) do
    with :ok <- valid_selection_input(model, effort),
         {:ok, account_id} <- entity_id(account_or_id),
         {:ok, connection_id} <- cast_id(connection_id),
         {:ok, now} <- normalized_now(opts) do
      validate_selection_transaction(account_id, connection_id, model, effort, now)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def latest_snapshot(account_id, connection_id) do
    Repo.one(
      from snapshot in ModelCatalogSnapshot,
        where: snapshot.account_id == ^account_id and snapshot.connection_id == ^connection_id,
        order_by: [desc: snapshot.retrieved_at, desc: snapshot.inserted_at, desc: snapshot.id],
        limit: 1
    )
  end

  defp call_adapter(adapter, account, connection, opts) do
    adapter_opts = Keyword.delete(opts, :adapter)

    try do
      case adapter.fetch(account, connection, adapter_opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, ModelCatalogAdapter.normalize_error(reason)}
        _other -> {:error, :invalid_response}
      end
    rescue
      _exception -> {:error, :invalid_response}
    catch
      _kind, _reason -> {:error, :invalid_response}
    end
  end

  defp prepare_refresh(account_id, connection_id) do
    Repo.transaction(fn ->
      account =
        active_account(account_id, lock: true) ||
          Repo.rollback(:account_unavailable)

      connection =
        scoped_connection(account_id, connection_id, lock: true) ||
          Repo.rollback(:not_found)

      case eligible(connection) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      Repo.delete_all(
        from snapshot in ModelCatalogSnapshot,
          where: snapshot.account_id == ^account_id and snapshot.connection_id == ^connection_id
      )

      {account, connection}
    end)
    |> unwrap_transaction()
  end

  defp persist(account_id, connection_id, result, expires_at) do
    Repo.transaction(fn ->
      with %Account{} <- active_account(account_id, lock: true),
           %PersonalAIConnection{} = connection <-
             scoped_connection(account_id, connection_id, lock: true),
           :ok <- eligible(connection) do
        attrs = %{
          account_id: account_id,
          connection_id: connection_id,
          provider: result.provider,
          status: result.status,
          source: result.source,
          source_method: result.source_method,
          source_version: result.source_version,
          retrieved_at: result.retrieved_at,
          expires_at: expires_at,
          models: %{"items" => encode_models(result.models)}
        }

        case %ModelCatalogSnapshot{}
             |> ModelCatalogSnapshot.create_changeset(attrs)
             |> Repo.insert() do
          {:ok, snapshot} -> snapshot
          {:error, _changeset} -> Repo.rollback(:invalid_response)
        end
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction()
  end

  defp project(snapshot, now) do
    if DateTime.compare(snapshot.expires_at, now) == :gt do
      with %{"items" => items} when is_list(items) <- snapshot.models,
           {:ok, result} <-
             ModelCatalogAdapter.validate_result(
               %{
                 provider: snapshot.provider,
                 status: snapshot.status,
                 source: snapshot.source,
                 source_method: snapshot.source_method,
                 source_version: snapshot.source_version,
                 retrieved_at: snapshot.retrieved_at,
                 models: items
               },
               snapshot.provider
             ) do
        {:ok,
         %{
           snapshot_id: snapshot.id,
           connection_id: snapshot.connection_id,
           provider: result.provider,
           status: result.status,
           provenance: %{
             source: result.source,
             method: result.source_method,
             version: result.source_version,
             retrieved_at: result.retrieved_at
           },
           expires_at: snapshot.expires_at,
           models: result.models
         }}
      else
        _ -> {:error, :unknown}
      end
    else
      {:error, :stale}
    end
  end

  defp encode_models(models) do
    Enum.map(models, fn model ->
      %{
        "id" => model.id,
        "model" => model.model,
        "display_name" => model.display_name,
        "current" => model.current,
        "default" => model.default,
        "default_reasoning_effort" => model.default_reasoning_effort,
        "supported_reasoning_efforts" =>
          Enum.map(model.supported_reasoning_efforts, fn effort ->
            %{
              "reasoning_effort" => effort.reasoning_effort,
              "description" => effort.description
            }
          end)
      }
    end)
  end

  defp validate_retrieval_time(retrieved_at, now, ttl_seconds) do
    future_limit = DateTime.add(now, @max_clock_skew_seconds, :second)
    expires_at = DateTime.add(retrieved_at, ttl_seconds, :second)

    cond do
      DateTime.compare(retrieved_at, future_limit) == :gt -> {:error, :stale}
      DateTime.compare(expires_at, now) != :gt -> {:error, :stale}
      true -> {:ok, expires_at}
    end
  end

  defp ttl_seconds(opts) do
    configured =
      Application.get_env(
        :sdd_orchestrator,
        :model_catalog_ttl_seconds,
        @default_ttl_seconds
      )

    case Keyword.get(opts, :ttl_seconds, configured) do
      value when is_integer(value) and value > 0 and value <= @max_ttl_seconds -> {:ok, value}
      _other -> {:error, :invalid_request}
    end
  end

  defp normalized_now(opts) do
    case Keyword.get(opts, :now, DateTime.utc_now()) do
      %DateTime{} = now -> {:ok, DateTime.truncate(now, :second)}
      _other -> {:error, :invalid_request}
    end
  end

  defp valid_selection_input(model, effort)
       when is_binary(model) and is_binary(effort) do
    if model == String.trim(model) and effort == String.trim(effort) and
         byte_size(model) in 1..255 and byte_size(effort) in 1..64,
       do: :ok,
       else: {:error, :invalid_selection}
  end

  defp valid_selection_input(_model, _effort), do: {:error, :invalid_selection}

  defp validate_selection_transaction(account_id, connection_id, model, effort, now) do
    Repo.transaction(fn ->
      active_account(account_id, lock: true) || Repo.rollback(:account_unavailable)

      connection =
        scoped_connection(account_id, connection_id, lock: true) ||
          Repo.rollback(:not_found)

      case eligible(connection) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      snapshot = latest_snapshot(account_id, connection_id) || Repo.rollback(:unknown)

      catalog =
        case project(snapshot, now) do
          {:ok, projection} -> projection
          {:error, reason} -> Repo.rollback(reason)
        end

      model_entry =
        Enum.find(catalog.models, &(&1.model == model)) ||
          Repo.rollback(:unknown_compatibility)

      effort_entry =
        Enum.find(
          model_entry.supported_reasoning_efforts,
          &(&1.reasoning_effort == effort)
        ) || Repo.rollback(:unknown_compatibility)

      %{
        snapshot_id: catalog.snapshot_id,
        connection_id: catalog.connection_id,
        model: model_entry.model,
        effort: effort_entry.reasoning_effort,
        provenance: catalog.provenance,
        expires_at: catalog.expires_at
      }
    end)
    |> unwrap_transaction()
  end

  defp eligible(%{revocation_state: "requested"}), do: {:error, :revoking}
  defp eligible(%{revocation_state: "acknowledged"}), do: {:error, :revoked}
  defp eligible(%{availability: "unavailable"}), do: {:error, :unavailable}
  defp eligible(%{availability: "incompatible"}), do: {:error, :incompatible}
  defp eligible(%{revocation_state: "active", availability: "available"}), do: :ok

  defp active_account(account_id, opts \\ []) do
    query = from account in Account, where: account.id == ^account_id and account.state == :active
    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp fetch_active_account(account_id) do
    case active_account(account_id) do
      %Account{} = account -> {:ok, account}
      nil -> {:error, :account_unavailable}
    end
  end

  defp scoped_connection(account_id, connection_id, opts \\ []) do
    query =
      from connection in PersonalAIConnection,
        where: connection.account_id == ^account_id and connection.id == ^connection_id,
        preload: [:worker]

    Repo.one(if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query)
  end

  defp fetch_scoped_connection(account_id, connection_id) do
    case scoped_connection(account_id, connection_id) do
      %PersonalAIConnection{} = connection -> {:ok, connection}
      nil -> {:error, :not_found}
    end
  end

  defp entity_id(%Account{id: id}), do: cast_id(id)
  defp entity_id(id), do: cast_id(id)

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_id), do: {:error, :not_found}

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp contains_value?(value, forbidden) when is_binary(value),
    do: String.contains?(value, forbidden)

  defp contains_value?(value, forbidden) when is_list(value),
    do: Enum.any?(value, &contains_value?(&1, forbidden))

  defp contains_value?(value, forbidden) when is_map(value),
    do: Enum.any?(Map.values(value), &contains_value?(&1, forbidden))

  defp contains_value?(_value, _forbidden), do: false
end
