defmodule SddOrchestrator.Devices.DeviceStore.Local do
  @moduledoc """
  Development and verification `DeviceStore` adapter.

  Persists the accountless device workspace and its projects on the local host
  with DETS, standing in for the release-gated native worker. Durability makes
  "stable access under the same operating-system boundary" and "data loss"
  distinct events: a lost store (a deleted file) yields a fresh workspace with no
  projects, so reconnecting a repository starts new history rather than restoring
  it.

  All writes are serialized through this GenServer, so registration is atomic.
  Nothing here writes device-authoritative data to the hosted database.
  """

  @behaviour SddOrchestrator.Devices.DeviceStore

  use GenServer

  alias SddOrchestrator.Accounts.{DeviceWorkspace, Workspace}
  alias SddOrchestrator.Devices.{DeviceProject, DeviceTransaction}

  alias SddOrchestrator.Portability.{
    DeviceRestoreContribution,
    ImportAttempt,
    PackageProvenance
  }

  alias SddOrchestrator.Projects.Project

  alias SddOrchestrator.Specifications.{
    DeviceProjectSpecification,
    DeviceSpecificationRevision,
    SpecificationDocuments,
    SpecificationRestore
  }

  alias SddOrchestrator.Specifications.SpecificationRestore.{DeviceContribution, Entry}

  @workspace_key :device_workspace

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def establish_workspace, do: GenServer.call(__MODULE__, :establish_workspace)

  @impl SddOrchestrator.Devices.DeviceStore
  def get_workspace, do: GenServer.call(__MODULE__, :get_workspace)

  @impl SddOrchestrator.Devices.DeviceStore
  def register_project(attrs, opts),
    do: GenServer.call(__MODULE__, {:register_project, attrs, opts})

  @impl SddOrchestrator.Devices.DeviceStore
  def list_projects, do: GenServer.call(__MODULE__, :list_projects)

  @impl SddOrchestrator.Devices.DeviceStore
  def get_project(id), do: GenServer.call(__MODULE__, {:get_project, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def delete_project(id), do: GenServer.call(__MODULE__, {:delete_project, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def find_by_fingerprint(fingerprint),
    do: GenServer.call(__MODULE__, {:find_by_fingerprint, fingerprint})

  @impl SddOrchestrator.Devices.DeviceStore
  def create_specification(project_id, specification, revision) do
    GenServer.call(__MODULE__, {:create_specification, project_id, specification, revision})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def append_specification_revision(
        project_id,
        specification_id,
        expected_revision_id,
        revision,
        specification_attrs
      ) do
    GenServer.call(
      __MODULE__,
      {:append_specification_revision, project_id, specification_id, expected_revision_id,
       revision, specification_attrs}
    )
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_current_specification(project_id, specification_id) do
    GenServer.call(__MODULE__, {:get_current_specification, project_id, specification_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def specification_count(project_id) do
    GenServer.call(__MODULE__, {:specification_count, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def current_specifications(project_id) do
    GenServer.call(__MODULE__, {:current_specifications, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def put_import_attempt(%ImportAttempt{} = attempt) do
    GenServer.call(__MODULE__, {:put_import_attempt, attempt})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_import_attempt(id), do: GenServer.call(__MODULE__, {:get_import_attempt, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def delete_import_attempt(id), do: GenServer.call(__MODULE__, {:delete_import_attempt, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def get_package_provenance(project_id),
    do: GenServer.call(__MODULE__, {:get_package_provenance, project_id})

  @impl SddOrchestrator.Devices.DeviceStore
  def commit_transaction(%DeviceTransaction{} = transaction) do
    GenServer.call(__MODULE__, {:commit_transaction, transaction})
  end

  @impl GenServer
  # The store path is trusted application configuration — a fixed dev/config value
  # or a test-supplied temporary path — never web or user input, so `File.mkdir_p!`
  # here is not a directory-traversal vector. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    table = Keyword.get(opts, :table, __MODULE__)
    File.mkdir_p!(Path.dirname(path))
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path), type: :set)
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_call(:get_workspace, _from, state) do
    {:reply, fetch_workspace(state.table), state}
  end

  def handle_call(:establish_workspace, _from, state) do
    reply =
      case fetch_workspace(state.table) do
        {:ok, workspace} -> {:ok, workspace}
        {:error, :not_found} -> create_workspace(state.table)
      end

    {:reply, reply, state}
  end

  def handle_call(:list_projects, _from, state) do
    {:reply, all_projects(state.table), state}
  end

  def handle_call({:get_project, id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:project, id}) do
        [{{:project, ^id}, project}] -> {:ok, normalize_project(project, state.table)}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_project, id}, _from, state) do
    {:reply, do_delete_project(state.table, id), state}
  end

  def handle_call({:find_by_fingerprint, fingerprint}, _from, state) do
    reply =
      case Enum.find(all_projects(state.table), &(&1.repository_fingerprint == fingerprint)) do
        nil -> {:error, :not_found}
        project -> {:ok, project}
      end

    {:reply, reply, state}
  end

  def handle_call({:register_project, attrs, opts}, _from, state) do
    {:reply, do_register(state.table, attrs, opts), state}
  end

  def handle_call(
        {:create_specification, project_id, specification, revision},
        _from,
        state
      ) do
    {:reply, do_create_specification(state.table, project_id, specification, revision), state}
  end

  def handle_call(
        {:append_specification_revision, project_id, specification_id, expected_revision_id,
         revision, specification_attrs},
        _from,
        state
      ) do
    reply =
      do_append_specification_revision(
        state.table,
        project_id,
        specification_id,
        expected_revision_id,
        revision,
        specification_attrs
      )

    {:reply, reply, state}
  end

  def handle_call({:get_current_specification, project_id, specification_id}, _from, state) do
    {:reply, fetch_current_specification(state.table, project_id, specification_id), state}
  end

  def handle_call({:specification_count, project_id}, _from, state) do
    count =
      :dets.foldl(
        fn
          {{:specification, ^project_id, _specification_id}, _aggregate}, acc -> acc + 1
          _other, acc -> acc
        end,
        0,
        state.table
      )

    {:reply, count, state}
  end

  def handle_call({:current_specifications, project_id}, _from, state) do
    {:reply, current_specifications_from_table(state.table, project_id), state}
  end

  def handle_call({:put_import_attempt, %ImportAttempt{} = attempt}, _from, state) do
    :ok = :dets.insert(state.table, {{:import_attempt, attempt.id}, attempt})
    :ok = :dets.sync(state.table)
    {:reply, {:ok, attempt}, state}
  end

  def handle_call({:get_import_attempt, id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:import_attempt, id}) do
        [{{:import_attempt, ^id}, %ImportAttempt{} = attempt}] -> {:ok, attempt}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete_import_attempt, id}, _from, state) do
    :ok = :dets.delete(state.table, {:import_attempt, id})
    :ok = :dets.sync(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:get_package_provenance, project_id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:package_provenance, project_id}) do
        [
          {{:package_provenance, ^project_id},
           %PackageProvenance{project_id: ^project_id} = provenance}
        ] ->
          {:ok, provenance}

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:commit_transaction, transaction}, _from, state) do
    {:reply, do_commit_transaction(state.table, transaction), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = :dets.close(state.table)
    :ok
  end

  # ---- workspace ----

  defp fetch_workspace(table) do
    case :dets.lookup(table, @workspace_key) do
      [{@workspace_key, id}] -> {:ok, %DeviceWorkspace{id: id}}
      [] -> {:error, :not_found}
    end
  end

  defp create_workspace(table) do
    with {:ok, root} <- Workspace.device_root(),
         {:ok, workspace} <- DeviceWorkspace.from_workspace(root) do
      :ok = :dets.insert(table, {@workspace_key, workspace.id})
      :ok = :dets.sync(table)
      {:ok, workspace}
    end
  end

  # ---- projects ----

  defp all_projects(table) do
    fun = fn
      {{:project, _id}, %DeviceProject{} = project}, acc -> [project | acc]
      _other, acc -> acc
    end

    :dets.foldl(fun, [], table)
    |> Enum.map(&normalize_project(&1, table))
    |> Enum.sort_by(& &1.name)
  end

  defp do_register(table, attrs, opts) do
    name = get(attrs, :name)
    fingerprint = get(attrs, :repository_fingerprint)
    status = get(attrs, :status) || "connected"
    idempotency_key = get(attrs, :idempotency_key)
    projects = all_projects(table)
    {:ok, workspace} = fetch_or_create_workspace(table)

    # Idempotent commit and lost-acknowledgement reconciliation: a registration
    # carrying an already-committed attempt key resolves to the same project
    # rather than creating a duplicate. Checked before repository uniqueness so a
    # retry of the same registration is never mistaken for a duplicate link.
    case find_by_key(projects, idempotency_key) do
      {:ok, existing} ->
        {:ok, existing}

      :error ->
        with {:ok, valid_name} <- validate_name(name),
             :ok <- validate_fingerprint(fingerprint),
             :ok <- check_repository_unique(projects, fingerprint),
             {:ok, final_name} <-
               resolve_name(projects, valid_name, Keyword.get(opts, :allocate_suffix?, false)) do
          project = %DeviceProject{
            id: Ecto.UUID.generate(),
            workspace_id: workspace.id,
            name: final_name,
            name_key: Project.name_key(final_name),
            repository_provider: "local",
            repository_id: fingerprint,
            repository_fingerprint: fingerprint,
            status: status,
            storage_mode: "device",
            idempotency_key: idempotency_key,
            inserted_at: now()
          }

          :ok = :dets.insert(table, {{:project, project.id}, project})
          :ok = :dets.sync(table)
          {:ok, project}
        end
    end
  end

  defp do_delete_project(table, project_id) do
    case :dets.lookup(table, {:project, project_id}) do
      [] ->
        {:error, :not_found}

      [_project] ->
        specification_keys =
          :dets.foldl(
            fn
              {{:specification, ^project_id, _specification_id} = key, _aggregate}, keys ->
                [key | keys]

              _object, keys ->
                keys
            end,
            [],
            table
          )

        Enum.each([{:project, project_id} | specification_keys], &:dets.delete(table, &1))
        :ok = :dets.sync(table)

        {:ok,
         %{
           project_id: project_id,
           deleted_specifications: length(specification_keys)
         }}
    end
  end

  defp find_by_key(_projects, nil), do: :error

  defp find_by_key(projects, key) do
    case Enum.find(projects, &(&1.idempotency_key == key)) do
      nil -> :error
      project -> {:ok, project}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp validate_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> {:error, :invalid_name}
      Regex.match?(~r/\p{Cc}/u, trimmed) -> {:error, :invalid_name}
      true -> {:ok, trimmed}
    end
  end

  defp validate_name(_name), do: {:error, :invalid_name}

  defp validate_fingerprint(fingerprint) when is_binary(fingerprint) and fingerprint != "",
    do: :ok

  defp validate_fingerprint(_fingerprint), do: {:error, :fingerprint_required}

  defp check_repository_unique(projects, fingerprint) do
    case Enum.find(projects, &(canonical_repository_identity(&1) == {"local", fingerprint})) do
      nil -> :ok
      existing -> {:error, {:repository_already_linked, existing}}
    end
  end

  defp resolve_name(projects, name, allocate?) do
    keys = MapSet.new(projects, & &1.name_key)
    key = Project.name_key(name)

    cond do
      key not in keys -> {:ok, name}
      allocate? -> {:ok, next_suffixed(name, keys, 1)}
      true -> {:error, :name_taken}
    end
  end

  defp next_suffixed(base, keys, n) do
    candidate = "#{base}-#{n}"

    if Project.name_key(candidate) in keys,
      do: next_suffixed(base, keys, n + 1),
      else: candidate
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp normalize_project(%DeviceProject{} = project, table) do
    {:ok, workspace} = fetch_workspace(table)
    values = Map.from_struct(project)

    struct(
      DeviceProject,
      Map.merge(values, %{
        workspace_id: Map.get(values, :workspace_id) || workspace.id,
        repository_provider: Map.get(values, :repository_provider) || "local",
        repository_id: Map.get(values, :repository_id) || Map.get(values, :repository_fingerprint)
      })
    )
  end

  defp fetch_or_create_workspace(table) do
    case fetch_workspace(table) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, :not_found} -> create_workspace(table)
    end
  end

  defp canonical_repository_identity(project) do
    {
      Map.get(project, :repository_provider) || "local",
      Map.get(project, :repository_id) || Map.get(project, :repository_fingerprint)
    }
  end

  # ---- specifications ----

  defp do_commit_transaction(
         table,
         %DeviceTransaction{
           project_id: project_id,
           contributions:
             %{
               project_restore: %DeviceRestoreContribution{} = project_contribution,
               specification_restore: %DeviceContribution{} = specification_contribution
             } = contributions
         }
       )
       when map_size(contributions) == 2 do
    commit_device_project_restore(
      table,
      project_id,
      project_contribution,
      specification_contribution
    )
  end

  defp do_commit_transaction(
         table,
         %DeviceTransaction{
           project_id: project_id,
           contributions:
             %{specification_restore: %DeviceContribution{} = contribution} = contributions
         }
       )
       when map_size(contributions) == 1 do
    case :dets.lookup(table, {:project, project_id}) do
      [{{:project, ^project_id}, %{storage_mode: "device"}}] ->
        restore_device_entries(table, project_id, contribution)

      _other ->
        {:error, :not_found}
    end
  end

  defp do_commit_transaction(_table, %DeviceTransaction{}),
    do: {:error, :unsupported_transaction}

  defp commit_device_project_restore(
         table,
         project_id,
         %DeviceRestoreContribution{} = project_contribution,
         %DeviceContribution{} = specification_contribution
       ) do
    case :dets.lookup(table, {:project, project_id}) do
      [] ->
        insert_device_project_restore(
          table,
          project_id,
          project_contribution,
          specification_contribution
        )

      [{{:project, ^project_id}, existing_project}] ->
        reconcile_device_project_restore(
          table,
          normalize_project(existing_project, table),
          project_contribution,
          specification_contribution
        )
    end
  end

  defp insert_device_project_restore(
         table,
         project_id,
         %DeviceRestoreContribution{
           project: project,
           provenance: provenance,
           fault: project_fault
         },
         %DeviceContribution{entries: entries, fault: specification_fault}
       ) do
    projects = all_projects(table)

    with :ok <- validate_project_contribution(table, project_id, project, provenance),
         :ok <- ensure_device_project_conflicts_available(projects, project),
         :ok <- ensure_provenance_available(table, project_id),
         :ok <- ensure_device_restore_identities_available(table, entries),
         :ok <- restore_fault(project_fault, specification_fault),
         currents <- build_device_restore_entries(project_id, entries, project.inserted_at),
         :ok <-
           persist_device_restore(table, project, provenance, currents) do
      {:ok,
       %{
         project_restore: %{project: project, provenance: provenance, replay?: false},
         specification_restore: Enum.map(currents, & &1.current)
       }}
    end
  end

  defp reconcile_device_project_restore(
         table,
         existing_project,
         %DeviceRestoreContribution{
           project: expected_project,
           provenance: expected_provenance
         },
         %DeviceContribution{entries: entries}
       ) do
    with true <- restored_project_matches?(existing_project, expected_project),
         {:ok, provenance} <- fetch_package_provenance(table, existing_project.id),
         true <-
           provenance.payload_schema_version == expected_provenance.payload_schema_version,
         existing_specifications <-
           current_specifications_from_table(table, existing_project.id),
         true <- restored_device_entries_match?(existing_specifications, entries) do
      {:ok,
       %{
         project_restore: %{
           project: existing_project,
           provenance: provenance,
           replay?: true
         },
         specification_restore: existing_specifications
       }}
    else
      _reason -> {:error, :identity_conflict}
    end
  end

  defp validate_project_contribution(
         table,
         project_id,
         %DeviceProject{} = project,
         %PackageProvenance{} = provenance
       ) do
    with {:ok, workspace} <- fetch_workspace(table),
         {:ok, valid_name} <- validate_name(project.name),
         true <- project.id == project_id,
         true <- project.workspace_id == workspace.id,
         true <- project.storage_mode == "device",
         true <- project.status == "disconnected",
         true <- project.name == valid_name,
         true <- project.name_key == Project.name_key(valid_name),
         true <- project.repository_provider in ["github", "local"],
         true <- is_binary(project.repository_id) and project.repository_id != "",
         true <- provenance.project_id == project_id,
         true <- provenance.payload_schema_version > 0,
         true <- not is_nil(provenance.restored_at) do
      :ok
    else
      _reason -> {:error, :invalid_restore}
    end
  end

  defp validate_project_contribution(_table, _project_id, _project, _provenance),
    do: {:error, :invalid_restore}

  defp ensure_device_project_conflicts_available(projects, project) do
    cond do
      Enum.any?(
        projects,
        &(canonical_repository_identity(&1) ==
              {project.repository_provider, project.repository_id})
      ) ->
        {:error, :repository_conflict}

      Enum.any?(projects, &(&1.name_key == project.name_key)) ->
        {:error, :name_conflict}

      true ->
        :ok
    end
  end

  defp ensure_provenance_available(table, project_id) do
    case :dets.lookup(table, {:package_provenance, project_id}) do
      [] -> :ok
      _existing -> {:error, :identity_conflict}
    end
  end

  defp restore_fault(project_fault, specification_fault) do
    if project_fault in [:after_project, :after_provenance] or
         specification_fault == :after_specification,
       do: {:error, :injected_failure},
       else: :ok
  end

  defp build_device_restore_entries(project_id, entries, inserted_at) do
    Enum.map(entries, fn entry ->
      aggregate = restored_device_aggregate(project_id, entry, inserted_at)

      %{
        key: specification_key(project_id, entry.id),
        aggregate: aggregate,
        current: %{
          specification: aggregate.specification,
          revision: Map.fetch!(aggregate.revisions, entry.revision_id)
        }
      }
    end)
  end

  defp persist_device_restore(table, project, provenance, currents) do
    objects = [
      {{:project, project.id}, project},
      {{:package_provenance, project.id}, provenance}
      | Enum.map(currents, &{&1.key, &1.aggregate})
    ]

    :ok = :dets.insert(table, objects)
    :ok = :dets.sync(table)
  end

  defp restored_project_matches?(existing, expected) do
    Map.take(existing, [
      :id,
      :workspace_id,
      :name,
      :name_key,
      :repository_provider,
      :repository_id,
      :repository_fingerprint,
      :status,
      :storage_mode
    ]) ==
      Map.take(expected, [
        :id,
        :workspace_id,
        :name,
        :name_key,
        :repository_provider,
        :repository_id,
        :repository_fingerprint,
        :status,
        :storage_mode
      ])
  end

  defp fetch_package_provenance(table, project_id) do
    case :dets.lookup(table, {:package_provenance, project_id}) do
      [{{:package_provenance, ^project_id}, %PackageProvenance{} = provenance}] ->
        {:ok, provenance}

      [] ->
        {:error, :not_found}
    end
  end

  defp restore_device_entries(
         table,
         project_id,
         %DeviceContribution{entries: entries, fault: fault}
       ) do
    existing = current_specifications_from_table(table, project_id)

    cond do
      existing == [] ->
        with :ok <- ensure_device_restore_identities_available(table, entries),
             {:ok, currents} <- insert_device_restore_entries(table, project_id, entries, fault) do
          {:ok, %{specification_restore: currents}}
        end

      restored_device_entries_match?(existing, entries) ->
        {:ok, %{specification_restore: existing}}

      true ->
        {:error, :specification_conflict}
    end
  end

  defp ensure_device_restore_identities_available(table, entries) do
    requested_specification_ids = MapSet.new(entries, & &1.id)
    requested_revision_ids = MapSet.new(entries, & &1.revision_id)

    conflict? =
      :dets.foldl(
        fn
          {
            {:specification, _project_id, specification_id},
            %{revisions: revisions}
          },
          false ->
            MapSet.member?(requested_specification_ids, specification_id) or
              Enum.any?(Map.keys(revisions), &MapSet.member?(requested_revision_ids, &1))

          _object, conflict ->
            conflict
        end,
        false,
        table
      )

    if conflict?, do: {:error, :specification_conflict}, else: :ok
  end

  defp insert_device_restore_entries(table, project_id, entries, fault) do
    now = now()
    currents = build_device_restore_entries(project_id, entries, now)

    if fault == :after_specification and currents != [] do
      {:error, :injected_failure}
    else
      objects = Enum.map(currents, &{&1.key, &1.aggregate})
      :ok = :dets.insert(table, objects)
      :ok = :dets.sync(table)
      {:ok, Enum.map(currents, & &1.current)}
    end
  end

  defp restored_device_aggregate(project_id, %Entry{} = entry, inserted_at) do
    specification = %DeviceProjectSpecification{
      id: entry.id,
      project_id: project_id,
      title: entry.title,
      current_revision_id: entry.revision_id,
      inserted_at: inserted_at,
      updated_at: inserted_at
    }

    revision = %DeviceSpecificationRevision{
      id: entry.revision_id,
      specification_id: entry.id,
      project_id: project_id,
      sequence: 1,
      requirements_document: entry.documents.requirements,
      design_document: entry.documents.design,
      tasks_document: entry.documents.tasks,
      content_digest: SpecificationDocuments.digest(entry.documents),
      actor_ref: nil,
      inserted_at: inserted_at
    }

    %{specification: specification, revisions: %{revision.id => revision}}
  end

  defp restored_device_entries_match?(existing, entries)
       when length(existing) == length(entries) do
    Enum.zip(existing, entries)
    |> Enum.all?(fn {current, entry} ->
      SpecificationRestore.matches_current?(current, entry)
    end)
  end

  defp restored_device_entries_match?(_existing, _entries), do: false

  defp current_specifications_from_table(table, project_id) do
    :dets.foldl(
      fn
        {
          {:specification, ^project_id, _specification_id},
          %{specification: specification, revisions: revisions}
        },
        acc ->
          [
            %{
              specification: specification,
              revision: Map.fetch!(revisions, specification.current_revision_id)
            }
            | acc
          ]

        _other, acc ->
          acc
      end,
      [],
      table
    )
    |> Enum.sort_by(& &1.specification.id)
  end

  defp do_create_specification(
         table,
         project_id,
         %DeviceProjectSpecification{} = specification,
         %DeviceSpecificationRevision{} = revision
       ) do
    key = specification_key(project_id, specification.id)

    case {:dets.lookup(table, {:project, project_id}), :dets.lookup(table, key)} do
      {[], _specification} ->
        {:error, :not_found}

      {_project, [{^key, existing}]} ->
        if same_device_aggregate?(existing, specification, revision) do
          {:ok,
           %{
             specification: existing.specification,
             revision: Map.fetch!(existing.revisions, revision.id)
           }}
        else
          {:error, :specification_conflict}
        end

      {_project, []} ->
        aggregate = %{
          specification: specification,
          revisions: %{revision.id => revision}
        }

        :ok = :dets.insert(table, {key, aggregate})
        :ok = :dets.sync(table)
        {:ok, %{specification: specification, revision: revision}}
    end
  end

  defp same_device_aggregate?(
         %{specification: existing_specification, revisions: revisions},
         specification,
         revision
       ) do
    case Map.fetch(revisions, revision.id) do
      {:ok, existing_revision} ->
        %{
          specification_id: existing_specification.id,
          project_id: existing_specification.project_id,
          title: existing_specification.title,
          current_revision_id: existing_specification.current_revision_id,
          revision: semantic_revision(existing_revision)
        } ==
          %{
            specification_id: specification.id,
            project_id: specification.project_id,
            title: specification.title,
            current_revision_id: specification.current_revision_id,
            revision: semantic_revision(revision)
          }

      :error ->
        false
    end
  end

  defp semantic_revision(revision) do
    Map.take(revision, [
      :id,
      :specification_id,
      :project_id,
      :sequence,
      :requirements_document,
      :design_document,
      :tasks_document,
      :content_digest,
      :actor_ref
    ])
  end

  defp do_append_specification_revision(
         table,
         project_id,
         specification_id,
         expected_revision_id,
         %DeviceSpecificationRevision{} = revision,
         specification_attrs
       ) do
    key = specification_key(project_id, specification_id)

    case :dets.lookup(table, key) do
      [{^key, aggregate}] ->
        append_device_aggregate(
          table,
          key,
          aggregate,
          expected_revision_id,
          revision,
          specification_attrs
        )

      [] ->
        {:error, :not_found}
    end
  end

  defp append_device_aggregate(
         table,
         key,
         %{specification: specification, revisions: revisions} = aggregate,
         expected_revision_id,
         revision,
         specification_attrs
       ) do
    current_revision = Map.fetch!(revisions, specification.current_revision_id)

    cond do
      specification.current_revision_id == revision.id ->
        if current_revision == revision do
          {:ok, %{specification: specification, revision: current_revision}}
        else
          {:error, :revision_conflict}
        end

      specification.current_revision_id != expected_revision_id ->
        {:error, :stale_revision}

      Map.has_key?(revisions, revision.id) ->
        {:error, :revision_conflict}

      true ->
        updated_specification =
          %{
            specification
            | current_revision_id: revision.id,
              title: Map.get(specification_attrs, :title, specification.title),
              updated_at: now()
          }

        updated = %{
          aggregate
          | specification: updated_specification,
            revisions: Map.put(revisions, revision.id, revision)
        }

        :ok = :dets.insert(table, {key, updated})
        :ok = :dets.sync(table)
        {:ok, %{specification: updated_specification, revision: revision}}
    end
  end

  defp fetch_current_specification(table, project_id, specification_id) do
    key = specification_key(project_id, specification_id)

    case :dets.lookup(table, key) do
      [{^key, %{specification: specification, revisions: revisions}}] ->
        {:ok,
         %{
           specification: specification,
           revision: Map.fetch!(revisions, specification.current_revision_id)
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp specification_key(project_id, specification_id),
    do: {:specification, project_id, specification_id}
end
