defmodule SddOrchestrator.RepositoryPilots do
  @moduledoc """
  Owner-controlled selection of one authoritative pilot specification revision.

  A pilot bounds adoption to one current Orchestrator feature. It references the
  specification store's identity, revision, and content digest together with the
  approved repository execution profile version it runs under; it copies no
  specification document, so the specification store stays the only authority for
  specification content.

  Selecting a pilot writes nothing to the repository and imports or changes no
  repository backlog item. Staleness is decided at commit: the submitted revision
  must still be the current head, otherwise nothing is stored. Participants may
  read the stored pointer but never reach the specification store or commit a
  selection, and an unsupported authority fails closed rather than falling back
  to another authority.
  """

  alias SddOrchestrator.Accounts
  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Participation
  alias SddOrchestrator.RepositoryAssessments
  alias SddOrchestrator.RepositoryPilots.{PilotStore, RepositoryPilotSelection}
  alias SddOrchestrator.RepositoryPilots.SelectableSpecification
  alias SddOrchestrator.SpecificationStore

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}
  @type viewer :: authority() | {:participant, Ecto.UUID.t() | nil, Ecto.UUID.t()}

  @type error ::
          :unauthorized
          | :unsupported_authority
          | :not_found
          | :no_approved_profile
          | :stale_revision
          | :invalid_selection
          | :invalid_pilot_selection
          | :persistence_failed

  @doc """
  Lists the current authoritative specifications this owner may pilot.

  The specification snapshot's `requirements`, `design`, and `tasks` documents
  are stripped here, so no specification document ever leaves this context.
  """
  @spec selectable_specifications(authority(), String.t(), keyword()) ::
          {:ok, [SelectableSpecification.t()]} | {:error, error()}
  def selectable_specifications(authority, project_id, _opts \\ []) do
    with {:ok, _project} <- authorize_project(authority, project_id),
         {:ok, store_authority} <- store_authority(authority),
         {:ok, snapshot} <- SpecificationStore.current_snapshot(store_authority, project_id) do
      {:ok, Enum.map(snapshot.specifications, &selectable/1)}
    else
      {:error, reason} when reason in [:unauthorized, :unsupported_authority] -> {:error, reason}
      _unavailable -> {:error, :not_found}
    end
  end

  @doc """
  Commits one pilot: one current specification revision under one approved
  profile version. It stores identifiers and one digest only, and it neither
  writes to the repository nor imports a backlog item.
  """
  @spec select(authority(), String.t(), map(), keyword()) ::
          {:ok, RepositoryPilotSelection.t()} | {:error, error()}
  def select(authority, project_id, attrs, opts \\ []) do
    pilot_store = Keyword.get(opts, :pilot_store, PilotStore)

    with {:ok, specification_id, revision_id} <- selection_attrs(attrs),
         {:ok, _project} <- authorize_project(authority, project_id),
         {:ok, profile} <- current_profile(authority, project_id, opts),
         {:ok, store_authority} <- store_authority(authority),
         {:ok, current} <-
           current_revision(store_authority, project_id, specification_id),
         :ok <- fresh?(current, revision_id),
         {:ok, selection} <-
           build_selection(authority, project_id, profile, current, opts) do
      persist(pilot_store, authority, selection)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the project's current pilot pointer.

  Participants are allowed here. This read never reaches the specification store,
  so a participant can see which specification is being piloted without gaining
  access to its documents.
  """
  @spec current(viewer(), String.t(), keyword()) ::
          {:ok, RepositoryPilotSelection.t()} | {:error, :not_found}
  def current(viewer, project_id, opts \\ []) do
    pilot_store = Keyword.get(opts, :pilot_store, PilotStore)

    case pilot_store.fetch(viewer, project_id) do
      {:ok, %RepositoryPilotSelection{} = selection} -> {:ok, selection}
      _missing -> {:error, :not_found}
    end
  end

  ## Selection steps

  defp selection_attrs(attrs) when is_map(attrs) do
    specification_id = field(attrs, :specification_id)
    revision_id = field(attrs, :revision_id)

    if is_binary(specification_id) and specification_id != "" and is_binary(revision_id) and
         revision_id != "" do
      {:ok, specification_id, revision_id}
    else
      {:error, :invalid_selection}
    end
  end

  defp selection_attrs(_attrs), do: {:error, :invalid_selection}

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  # Slice 14 remains the only writer of profile versions. Taking the highest
  # version is a read convention over its ascending list, not a second contract.
  defp current_profile(authority, project_id, opts) do
    review_opts = Keyword.take(opts, [:profile_store, :assessment_store])

    case RepositoryAssessments.profile_review(authority, project_id, review_opts) do
      {:ok, %{profiles: []}} -> {:error, :no_approved_profile}
      {:ok, %{profiles: profiles}} -> {:ok, List.last(profiles)}
      {:error, _unavailable} -> {:error, :no_approved_profile}
    end
  end

  defp current_revision(store_authority, project_id, specification_id) do
    case SpecificationStore.get_current(store_authority, project_id, specification_id) do
      {:ok, current} -> {:ok, current}
      _missing -> {:error, :not_found}
    end
  end

  # Staleness is decided here, at commit, against the freshly resolved head. A
  # revision that was current when the list was rendered is not current now.
  defp fresh?(%{revision: %{id: revision_id}}, revision_id), do: :ok
  defp fresh?(_current, _submitted), do: {:error, :stale_revision}

  defp build_selection(authority, project_id, profile, current, opts) do
    RepositoryPilotSelection.new(%{
      project_id: project_id,
      profile_id: profile.id,
      profile_version: profile.version,
      specification_id: current.specification.id,
      revision_id: current.revision.id,
      revision_digest: current.revision.content_digest,
      selected_by_actor_ref: actor_ref(authority),
      selected_at: now(opts)
    })
  end

  defp persist(pilot_store, authority, selection) do
    case pilot_store.put(authority, selection) do
      {:ok, %RepositoryPilotSelection{} = stored} -> {:ok, stored}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _failed -> {:error, :persistence_failed}
    end
  end

  defp actor_ref({:hosted, account_id}), do: account_id
  defp actor_ref({:device, %DeviceWorkspace{id: id}}), do: id

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  ## Authority mapping

  # The specification store is addressed by workspace struct, not by the tuple
  # authority this context takes, and a participant may never reach it at all.
  defp store_authority({:hosted, account_id}) do
    case Accounts.get_personal_workspace(account_id) do
      %PersonalWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end

  # No catch-all clause: `authorize_project/2` already refused every authority
  # that is not a hosted owner or the owning device workspace, so an unsupported
  # authority never reaches the specification store.
  defp store_authority({:device, %DeviceWorkspace{} = workspace}), do: {:ok, workspace}

  defp selectable(entry) do
    %SelectableSpecification{
      id: entry.id,
      title: entry.title,
      revision_id: entry.revision_id
    }
  end

  ## Authorization

  # Owner-only. A participant viewer is refused here, so neither the selectable
  # list nor a commit is reachable without ownership.
  defp authorize_project({:hosted, account_id}, project_id) do
    with {:ok, project} <- Participation.owned_project(account_id, project_id),
         true <- active_hosted_project?(project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  end

  defp authorize_project({:participant, _account_id, _identity_id}, _project_id),
    do: {:error, :unauthorized}

  defp authorize_project({:device, %DeviceWorkspace{id: authority_id} = authority}, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{status: "connected"} = project} <- Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(authority, project) do
      {:ok, project}
    else
      _unauthorized -> {:error, :unauthorized}
    end
  rescue
    _error -> {:error, :unauthorized}
  catch
    :exit, _reason -> {:error, :unauthorized}
  end

  defp authorize_project(_authority, _project_id), do: {:error, :unsupported_authority}

  defp active_hosted_project?(project),
    do: project.storage_mode == "hosted" and project.lifecycle_state == "active"
end
