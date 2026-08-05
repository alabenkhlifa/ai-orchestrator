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

  alias SddOrchestrator.Devices.{
    DeviceProject,
    DeviceTransaction,
    PortableRepositoryIdentity
  }

  alias SddOrchestrator.Portability.{
    DeviceRestoreContribution,
    ImportAttempt,
    PackageProvenance
  }

  alias SddOrchestrator.Projects.Project

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal,
    RepositoryExecutionProfileProposalEnvelope
  }

  alias SddOrchestrator.RepositoryPilots.RepositoryPilotSelection

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
  def rename_project(id, name), do: GenServer.call(__MODULE__, {:rename_project, id, name})

  @impl SddOrchestrator.Devices.DeviceStore
  def delete_project(id), do: GenServer.call(__MODULE__, {:delete_project, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def find_by_fingerprint(fingerprint),
    do: GenServer.call(__MODULE__, {:find_by_fingerprint, fingerprint})

  @impl SddOrchestrator.Devices.DeviceStore
  def connect_repository(project_id, provider, repository_id),
    do: GenServer.call(__MODULE__, {:connect_repository, project_id, provider, repository_id})

  @impl SddOrchestrator.Devices.DeviceStore
  def replace_repository_identity(
        project_id,
        expected_identity,
        replacement_identity,
        comparison_snapshot
      ) do
    GenServer.call(
      __MODULE__,
      {:replace_repository_identity, project_id, expected_identity, replacement_identity,
       comparison_snapshot}
    )
  end

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
  def put_repository_assessment(project_id, assessment_id, value) do
    GenServer.call(
      __MODULE__,
      {:put_repository_assessment, project_id, assessment_id, value}
    )
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def transition_repository_assessment(
        project_id,
        assessment_id,
        expected_state,
        value,
        envelope_value
      ) do
    GenServer.call(
      __MODULE__,
      {:transition_repository_assessment, project_id, assessment_id, expected_state, value,
       envelope_value}
    )
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_repository_assessment(project_id, assessment_id) do
    GenServer.call(__MODULE__, {:get_repository_assessment, project_id, assessment_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_repository_assessment_proposal_envelope(project_id, assessment_id) do
    GenServer.call(
      __MODULE__,
      {:get_repository_assessment_proposal_envelope, project_id, assessment_id}
    )
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def repository_assessment_count(project_id) do
    GenServer.call(__MODULE__, {:repository_assessment_count, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def latest_repository_assessment(project_id) do
    GenServer.call(__MODULE__, {:latest_repository_assessment, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def latest_completed_repository_assessment(project_id) do
    GenServer.call(__MODULE__, {:latest_completed_repository_assessment, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def append_repository_execution_profile(
        project_id,
        assessment_id,
        proposal,
        approval_actor_ref,
        approved_at
      ) do
    GenServer.call(
      __MODULE__,
      {:append_repository_execution_profile, project_id, assessment_id, proposal,
       approval_actor_ref, approved_at}
    )
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def list_repository_execution_profiles(project_id) do
    GenServer.call(__MODULE__, {:list_repository_execution_profiles, project_id})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def put_repository_pilot_selection(project_id, value) do
    GenServer.call(__MODULE__, {:put_repository_pilot_selection, project_id, value})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_repository_pilot_selection(project_id) do
    GenServer.call(__MODULE__, {:get_repository_pilot_selection, project_id})
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
  def prune_import_attempts(%DateTime{} = now) do
    GenServer.call(__MODULE__, {:prune_import_attempts, DateTime.truncate(now, :second)})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def get_package_provenance(project_id),
    do: GenServer.call(__MODULE__, {:get_package_provenance, project_id})

  @impl SddOrchestrator.Devices.DeviceStore
  def commit_transaction(%DeviceTransaction{} = transaction) do
    GenServer.call(__MODULE__, {:commit_transaction, transaction})
  end

  @impl SddOrchestrator.Devices.DeviceStore
  def commit_delivery(project_id, writes),
    do: GenServer.call(__MODULE__, {:commit_delivery, project_id, writes})

  @impl SddOrchestrator.Devices.DeviceStore
  def get_delivery(project_id, kind, id),
    do: GenServer.call(__MODULE__, {:get_delivery, project_id, kind, id})

  @impl SddOrchestrator.Devices.DeviceStore
  def list_delivery(project_id, kind),
    do: GenServer.call(__MODULE__, {:list_delivery, project_id, kind})

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

  def handle_call({:rename_project, id, name}, _from, state) do
    {:reply, do_rename_project(state.table, id, name), state}
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

  def handle_call({:connect_repository, project_id, provider, repository_id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:project, project_id}) do
        [{{:project, ^project_id}, stored}] ->
          project = normalize_project(stored, state.table)

          if canonical_repository_identity(project) == {provider, repository_id} do
            connected = %{project | status: "connected"}
            :ok = :dets.insert(state.table, {{:project, project_id}, connected})
            :ok = :dets.sync(state.table)
            {:ok, connected}
          else
            {:error, :canonical_repository_mismatch}
          end

        [] ->
          {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:replace_repository_identity, project_id, expected_identity, replacement_identity,
         comparison_snapshot},
        _from,
        state
      ) do
    reply =
      do_replace_repository_identity(
        state.table,
        project_id,
        expected_identity,
        replacement_identity,
        comparison_snapshot
      )

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

  def handle_call(
        {:put_repository_assessment, project_id, assessment_id, value},
        _from,
        state
      ) do
    reply =
      put_repository_assessment(state.table, project_id, assessment_id, value)

    {:reply, reply, state}
  end

  def handle_call(
        {:transition_repository_assessment, project_id, assessment_id, expected_state, value,
         envelope_value},
        _from,
        state
      ) do
    reply =
      transition_repository_assessment(
        state.table,
        project_id,
        assessment_id,
        expected_state,
        value,
        envelope_value
      )

    {:reply, reply, state}
  end

  def handle_call({:get_repository_assessment, project_id, assessment_id}, _from, state) do
    reply =
      case :dets.lookup(state.table, {:repository_assessment, project_id, assessment_id}) do
        [{{:repository_assessment, ^project_id, ^assessment_id}, value}] -> {:ok, value}
        [] -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:get_repository_assessment_proposal_envelope, project_id, assessment_id},
        _from,
        state
      ) do
    {:reply, repository_assessment_proposal_envelope(state.table, project_id, assessment_id),
     state}
  end

  def handle_call({:repository_assessment_count, project_id}, _from, state) do
    count =
      :dets.foldl(
        fn
          {{:repository_assessment, ^project_id, _assessment_id}, _value}, acc -> acc + 1
          _other, acc -> acc
        end,
        0,
        state.table
      )

    {:reply, count, state}
  end

  def handle_call({:latest_repository_assessment, project_id}, _from, state) do
    {:reply, latest_repository_assessment(state.table, project_id), state}
  end

  def handle_call({:latest_completed_repository_assessment, project_id}, _from, state) do
    {:reply, latest_completed_repository_assessment(state.table, project_id), state}
  end

  def handle_call(
        {:append_repository_execution_profile, project_id, assessment_id, proposal,
         approval_actor_ref, approved_at},
        _from,
        state
      ) do
    reply =
      append_repository_execution_profile(
        state.table,
        project_id,
        assessment_id,
        proposal,
        approval_actor_ref,
        approved_at
      )

    {:reply, reply, state}
  end

  def handle_call({:list_repository_execution_profiles, project_id}, _from, state) do
    {:reply, repository_execution_profile_values(state.table, project_id), state}
  end

  def handle_call({:put_repository_pilot_selection, project_id, value}, _from, state) do
    {:reply, put_repository_pilot_selection(state.table, project_id, value), state}
  end

  def handle_call({:get_repository_pilot_selection, project_id}, _from, state) do
    {:reply, fetch_repository_pilot_selection(state.table, project_id), state}
  end

  def handle_call({:commit_delivery, project_id, writes}, _from, state) do
    {:reply, apply_delivery_writes(state.table, project_id, writes), state}
  end

  def handle_call({:get_delivery, project_id, kind, id}, _from, state) do
    {:reply, fetch_delivery(state.table, project_id, kind, id), state}
  end

  def handle_call({:list_delivery, project_id, kind}, _from, state) do
    {:reply, collect_delivery(state.table, project_id, kind), state}
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

  def handle_call({:prune_import_attempts, now}, _from, state) do
    cutoff = DateTime.add(now, -(24 * 60 * 60), :second)

    expired_ids =
      :dets.foldl(
        fn
          {{:import_attempt, id}, %ImportAttempt{} = attempt}, ids ->
            if import_attempt_expired?(attempt, cutoff, now), do: [id | ids], else: ids

          _other, ids ->
            ids
        end,
        [],
        state.table
      )

    Enum.each(expired_ids, &:dets.delete(state.table, {:import_attempt, &1}))
    :ok = :dets.sync(state.table)
    {:reply, {:ok, length(expired_ids)}, state}
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

        provenance_key = {:package_provenance, project_id}
        deleted_provenance? = :dets.member(table, provenance_key)

        Enum.each(
          [{:project, project_id}, provenance_key | specification_keys],
          &:dets.delete(table, &1)
        )

        :ok = :dets.sync(table)

        {:ok,
         %{
           project_id: project_id,
           deleted_provenance: deleted_provenance?,
           deleted_specifications: length(specification_keys)
         }}
    end
  end

  defp do_rename_project(table, project_id, name) do
    case :dets.lookup(table, {:project, project_id}) do
      [] ->
        {:error, :not_found}

      [{{:project, ^project_id}, stored}] ->
        project = normalize_project(stored, table)

        changeset =
          Project.rename_changeset(
            %Project{name: project.name, name_key: project.name_key},
            %{name: name}
          )

        with {:ok, renamed} <- Ecto.Changeset.apply_action(changeset, :update),
             :ok <- ensure_device_name_available(table, project_id, renamed.name_key, changeset) do
          updated = %{project | name: renamed.name, name_key: renamed.name_key}
          :ok = :dets.insert(table, {{:project, project_id}, updated})
          :ok = :dets.sync(table)
          {:ok, updated}
        end
    end
  end

  defp ensure_device_name_available(table, project_id, name_key, changeset) do
    if Enum.any?(
         all_projects(table),
         &(&1.id != project_id and &1.name_key == name_key)
       ) do
      {:error, Ecto.Changeset.add_error(changeset, :name, "has already been taken")}
    else
      :ok
    end
  end

  defp do_replace_repository_identity(
         table,
         project_id,
         expected_identity,
         replacement_identity,
         comparison_snapshot
       ) do
    projects = all_projects(table)

    with {:ok, project} <- fetch_project(projects, project_id),
         :ok <- identity_unchanged(project, expected_identity),
         :ok <- validate_portable_identity(replacement_identity),
         :ok <- comparison_unchanged(projects, project_id, comparison_snapshot),
         :ok <- check_repository_unique_except(projects, project_id, replacement_identity) do
      updated = %{
        project
        | repository_id: replacement_identity,
          repository_fingerprint: replacement_identity
      }

      :ok = :dets.insert(table, {{:project, project_id}, updated})
      :ok = :dets.sync(table)
      {:ok, updated}
    end
  end

  defp fetch_project(projects, project_id) do
    case Enum.find(projects, &(&1.id == project_id)) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp identity_unchanged(%DeviceProject{repository_fingerprint: expected}, expected), do: :ok
  defp identity_unchanged(%DeviceProject{}, _expected), do: {:error, :identity_changed}

  defp validate_portable_identity(identity) do
    case PortableRepositoryIdentity.parse(identity) do
      {:ok, _portable} -> :ok
      {:error, _reason} -> {:error, :invalid_repository_identity}
    end
  end

  defp comparison_unchanged(projects, project_id, expected_snapshot)
       when is_map(expected_snapshot) do
    current_snapshot =
      projects
      |> Enum.reject(&(&1.id == project_id))
      |> Map.new(&{&1.id, &1.repository_fingerprint})

    if current_snapshot == expected_snapshot, do: :ok, else: {:error, :identity_race}
  end

  defp comparison_unchanged(_projects, _project_id, _snapshot),
    do: {:error, :identity_race}

  defp check_repository_unique_except(projects, project_id, fingerprint) do
    case Enum.find(
           projects,
           &(&1.id != project_id and &1.repository_fingerprint == fingerprint)
         ) do
      nil -> :ok
      existing -> {:error, {:repository_already_linked, existing}}
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

  defp import_attempt_expired?(%ImportAttempt{} = attempt, cutoff, now) do
    on_or_before?(attempt.inserted_at, cutoff) or on_or_before?(attempt.expires_at, now)
  end

  defp on_or_before?(%DateTime{} = value, %DateTime{} = boundary),
    do: DateTime.compare(value, boundary) in [:lt, :eq]

  defp on_or_before?(_value, _boundary), do: false

  # ---- repository assessments ----

  defp put_repository_assessment(table, project_id, assessment_id, value)
       when is_map(value) do
    key = {:repository_assessment, project_id, assessment_id}

    with {:ok, assessment} <- RepositoryAssessment.from_value(value),
         true <- RepositoryAssessment.strict?(assessment),
         true <- assessment.state == RepositoryAssessment.pending_state(),
         [
           {{:project, ^project_id}, %{storage_mode: "device", status: "connected"} = project}
         ] <-
           :dets.lookup(table, {:project, project_id}),
         ^project_id <- assessment.project_id,
         ^assessment_id <- assessment.id,
         true <-
           canonical_repository_identity(project) ==
             {assessment.repository_provider, assessment.repository_id},
         false <- :dets.member(table, key) do
      normalized = RepositoryAssessment.to_value(assessment)
      :ok = :dets.insert(table, {key, normalized})
      :ok = :dets.sync(table)
      {:ok, normalized}
    else
      true -> {:error, :already_exists}
      [] -> {:error, :not_found}
      _invalid -> {:error, :invalid_assessment}
    end
  end

  defp put_repository_assessment(_table, _project_id, _assessment_id, _value),
    do: {:error, :invalid_assessment}

  defp transition_repository_assessment(
         table,
         project_id,
         assessment_id,
         expected_state,
         value,
         envelope_value
       )
       when is_binary(expected_state) and is_map(value) do
    key = {:repository_assessment, project_id, assessment_id}

    with true <- expected_state == RepositoryAssessment.pending_state(),
         {:ok, terminal} <- RepositoryAssessment.from_value(value),
         true <- RepositoryAssessment.strict?(terminal),
         true <- RepositoryAssessment.terminal_state?(terminal.state),
         [{{:project, ^project_id}, %{storage_mode: "device", status: "connected"} = project}] <-
           :dets.lookup(table, {:project, project_id}),
         [{{:repository_assessment, ^project_id, ^assessment_id}, current_value}] <-
           :dets.lookup(table, key),
         {:ok, current} <- RepositoryAssessment.from_value(current_value),
         ^expected_state <- current.state,
         ^project_id <- terminal.project_id,
         ^assessment_id <- terminal.id,
         true <- RepositoryAssessment.same_binding?(current, terminal),
         true <-
           canonical_repository_identity(project) ==
             {terminal.repository_provider, terminal.repository_id},
         {:ok, envelope} <- repository_assessment_envelope(table, terminal, envelope_value) do
      normalized = RepositoryAssessment.to_value(terminal)
      insert_repository_assessment_envelope(table, project_id, assessment_id, envelope)
      :ok = :dets.insert(table, {key, normalized})
      :ok = :dets.sync(table)
      {:ok, normalized}
    else
      [] -> {:error, :not_found}
      {:error, :invalid_assessment} -> {:error, :invalid_assessment}
      {:error, :invalid_proposal_envelope} -> {:error, :invalid_proposal_envelope}
      _stale_or_mismatch -> {:error, :stale}
    end
  end

  defp transition_repository_assessment(
         _table,
         _project_id,
         _assessment_id,
         _expected_state,
         _value,
         _envelope_value
       ),
       do: {:error, :invalid_assessment}

  defp repository_assessment_envelope(
         table,
         %RepositoryAssessment{state: "completed"} = terminal,
         envelope_value
       )
       when is_map(envelope_value) do
    with {:ok, envelope} <- RepositoryExecutionProfileProposalEnvelope.from_value(envelope_value),
         {:ok, verified} <-
           RepositoryExecutionProfileProposalEnvelope.verify(envelope, terminal),
         :ok <- unclaimed_proposal_envelope(table, terminal, verified) do
      {:ok, verified}
    else
      _invalid -> {:error, :invalid_proposal_envelope}
    end
  end

  defp repository_assessment_envelope(_table, %RepositoryAssessment{state: "completed"}, _value),
    do: {:error, :invalid_proposal_envelope}

  defp repository_assessment_envelope(_table, %RepositoryAssessment{}, nil), do: {:ok, nil}

  defp repository_assessment_envelope(_table, %RepositoryAssessment{}, _value),
    do: {:error, :invalid_proposal_envelope}

  defp unclaimed_proposal_envelope(table, terminal, verified) do
    case repository_assessment_proposal_envelope(table, terminal.project_id, terminal.id) do
      {:error, :not_found} ->
        :ok

      {:ok, value} ->
        if Map.get(value, "envelope_digest") == verified.envelope_digest,
          do: :ok,
          else: {:error, :invalid_proposal_envelope}
    end
  end

  defp insert_repository_assessment_envelope(_table, _project_id, _assessment_id, nil), do: :ok

  defp insert_repository_assessment_envelope(table, project_id, assessment_id, envelope) do
    :ok =
      :dets.insert(
        table,
        {{:repository_assessment_proposal_envelope, project_id, assessment_id},
         RepositoryExecutionProfileProposalEnvelope.to_value(envelope)}
      )
  end

  defp repository_assessment_proposal_envelope(table, project_id, assessment_id) do
    case :dets.lookup(
           table,
           {:repository_assessment_proposal_envelope, project_id, assessment_id}
         ) do
      [{{:repository_assessment_proposal_envelope, ^project_id, ^assessment_id}, value}] ->
        {:ok, value}

      [] ->
        {:error, :not_found}
    end
  end

  defp latest_repository_assessment(table, project_id) do
    table
    |> repository_assessment_values(project_id)
    |> Enum.max_by(
      fn assessment -> {DateTime.to_iso8601(assessment.inserted_at), assessment.id} end,
      fn -> nil end
    )
    |> case do
      %RepositoryAssessment{} = assessment ->
        {:ok, RepositoryAssessment.to_value(assessment)}

      nil ->
        {:error, :not_found}
    end
  end

  defp latest_completed_repository_assessment(table, project_id) do
    table
    |> repository_assessment_values(project_id)
    |> Enum.filter(&(&1.state == "completed"))
    |> Enum.max_by(
      fn assessment -> {DateTime.to_iso8601(assessment.inserted_at), assessment.id} end,
      fn -> nil end
    )
    |> case do
      %RepositoryAssessment{} = assessment ->
        {:ok, RepositoryAssessment.to_value(assessment)}

      nil ->
        {:error, :not_found}
    end
  end

  defp repository_assessment_values(table, project_id) do
    :dets.foldl(
      fn
        {{:repository_assessment, ^project_id, _assessment_id}, value}, assessments ->
          case RepositoryAssessment.from_value(value) do
            {:ok, assessment} -> [assessment | assessments]
            {:error, :invalid_assessment} -> assessments
          end

        _other, assessments ->
          assessments
      end,
      [],
      table
    )
  end

  # ---- repository execution profiles ----

  defp append_repository_execution_profile(
         table,
         project_id,
         assessment_id,
         proposal_value,
         approval_actor_ref,
         approved_at
       )
       when is_map(proposal_value) and is_binary(approval_actor_ref) and
              is_binary(approved_at) do
    with {:ok, %DeviceWorkspace{id: ^approval_actor_ref}} <- fetch_workspace(table),
         [{{:project, ^project_id}, %{storage_mode: "device", status: "connected"} = project}] <-
           :dets.lookup(table, {:project, project_id}),
         true <- project.workspace_id == approval_actor_ref,
         [{{:repository_assessment, ^project_id, ^assessment_id}, assessment_value}] <-
           :dets.lookup(table, {:repository_assessment, project_id, assessment_id}),
         {:ok, assessment} <- RepositoryAssessment.from_value(assessment_value),
         true <- assessment.state == "completed",
         true <- RepositoryAssessment.cache_provenance_complete?(assessment),
         {:ok, latest_value} <- latest_repository_assessment(table, project_id),
         {:ok, latest} <- RepositoryAssessment.from_value(latest_value),
         true <- latest.id == assessment.id,
         true <-
           canonical_repository_identity(project) ==
             {assessment.repository_provider, assessment.repository_id},
         {:ok, proposal} <- RepositoryExecutionProfileProposal.from_value(proposal_value),
         true <- RepositoryExecutionProfileProposal.matches_assessment?(proposal, assessment),
         {:ok, approved_at, 0} <- DateTime.from_iso8601(approved_at) do
      case existing_repository_execution_profile(table, project_id, proposal.proposal_digest) do
        {:ok, existing} ->
          {:ok, existing}

        :error ->
          insert_repository_execution_profile(
            table,
            project_id,
            proposal,
            approval_actor_ref,
            approved_at
          )
      end
    else
      [] -> {:error, :not_found}
      false -> {:error, :stale_assessment}
      {:error, :invalid_profile} -> {:error, :invalid_profile}
      {:error, :invalid_proposal} -> {:error, :invalid_proposal}
      _invalid -> {:error, :stale_assessment}
    end
  end

  defp append_repository_execution_profile(
         _table,
         _project_id,
         _assessment_id,
         _proposal,
         _approval_actor_ref,
         _approved_at
       ),
       do: {:error, :invalid_profile}

  defp insert_repository_execution_profile(
         table,
         project_id,
         proposal,
         approval_actor_ref,
         approved_at
       ) do
    version = next_repository_execution_profile_version(table, project_id)

    with {:ok, profile} <-
           RepositoryExecutionProfile.approved(
             proposal,
             approval_actor_ref,
             version,
             approved_at
           ) do
      value = RepositoryExecutionProfile.to_value(profile)

      :ok = :dets.insert(table, {{:repository_execution_profile, project_id, profile.id}, value})
      :ok = :dets.sync(table)
      {:ok, value}
    end
  end

  defp existing_repository_execution_profile(table, project_id, proposal_digest) do
    case Enum.find(
           repository_execution_profile_values(table, project_id),
           &(&1["proposal_digest"] == proposal_digest)
         ) do
      nil -> :error
      existing -> {:ok, existing}
    end
  end

  defp next_repository_execution_profile_version(table, project_id) do
    table
    |> repository_execution_profile_values(project_id)
    |> Enum.map(& &1["version"])
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp repository_execution_profile_values(table, project_id) do
    :dets.foldl(
      fn
        {{:repository_execution_profile, ^project_id, _profile_id}, value}, values ->
          [value | values]

        _other, values ->
          values
      end,
      [],
      table
    )
    |> Enum.sort_by(& &1["version"])
  end

  # ---- repository pilot selection ----

  # One pilot per project, so a plain insert replaces the prior selection. The
  # value is revalidated before it is stored and again when it is read, so an
  # unreadable record fails closed instead of returning a partial pilot.
  defp put_repository_pilot_selection(table, project_id, value) do
    with {:ok, selection} <- RepositoryPilotSelection.from_value(value),
         true <- selection.project_id == project_id do
      stored = RepositoryPilotSelection.to_value(selection)

      :ok = :dets.insert(table, {{:repository_pilot_selection, project_id}, stored})
      :ok = :dets.sync(table)
      {:ok, stored}
    else
      _invalid -> {:error, :invalid_pilot_selection}
    end
  end

  defp fetch_repository_pilot_selection(table, project_id) do
    case :dets.lookup(table, {:repository_pilot_selection, project_id}) do
      [{_key, value}] -> revalidate_repository_pilot_selection(value)
      _missing -> {:error, :not_found}
    end
  end

  defp revalidate_repository_pilot_selection(value) do
    case RepositoryPilotSelection.from_value(value) do
      {:ok, selection} -> {:ok, RepositoryPilotSelection.to_value(selection)}
      {:error, :invalid_pilot_selection} -> {:error, :not_found}
    end
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

  # Feature-delivery records are plain values keyed by project, kind, and id.
  # The worker process is the serialization boundary, so a batch either applies
  # completely or leaves the store untouched — the device equivalent of one
  # hosted transaction.
  defp apply_delivery_writes(table, project_id, writes) do
    with :ok <- check_expected_versions(table, project_id, writes) do
      applied =
        Map.new(writes, fn {:put, kind, id, value, _expected} ->
          :ok = :dets.insert(table, {delivery_key(project_id, kind, id), value})
          {{kind, id}, value}
        end)

      :ok = :dets.sync(table)
      {:ok, applied}
    end
  end

  defp check_expected_versions(table, project_id, writes) do
    Enum.reduce_while(writes, :ok, fn {:put, kind, id, _value, expected}, :ok ->
      case stored_version(table, project_id, kind, id) do
        ^expected -> {:cont, :ok}
        _mismatch -> {:halt, {:error, :stale_state}}
      end
    end)
  end

  # A record that does not exist yet has no version, which is what an insert
  # declares by passing `nil`.
  defp stored_version(table, project_id, kind, id) do
    case :dets.lookup(table, delivery_key(project_id, kind, id)) do
      [{_key, %{"state_version" => version}}] -> version
      [{_key, _value}] -> nil
      [] -> nil
    end
  end

  defp fetch_delivery(table, project_id, kind, id) do
    key = delivery_key(project_id, kind, id)

    case :dets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> {:error, :not_found}
    end
  end

  defp collect_delivery(table, project_id, kind) do
    :dets.foldl(
      fn
        {{:delivery, ^project_id, ^kind, _id}, value}, acc -> [value | acc]
        _other, acc -> acc
      end,
      [],
      table
    )
  end

  defp delivery_key(project_id, kind, id), do: {:delivery, project_id, kind, id}
end
