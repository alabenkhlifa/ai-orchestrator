defmodule SddOrchestrator.Delivery.Features do
  @moduledoc """
  The durable feature lifecycle.

  Every read and write is project-scoped and guarded by
  `Delivery.ParticipantGuard`, so a feature is only reachable by someone who is
  currently a member of its project. Writes carry the caller's expected state
  version; a superseded version is rejected rather than overwritten, which is
  what makes a stale board tab or a replayed action safe.
  """

  import Ecto.Query

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.{Feature, ParticipantGuard, Readiness}
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo
  alias SddOrchestrator.SpecificationStore

  @type actor :: ParticipantGuard.actor()
  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()

  # The design and tasks documents belong to the coding agent, so the feature
  # starts with a placeholder that says so rather than an empty file the person
  # might think is theirs to fill in.
  @design_document "## Design\n\nThe coding agent writes this document.\n"
  @tasks_document "## Tasks\n\nThe coding agent writes this document.\n"

  @doc """
  Creates one feature in `Draft` for the acting member, together with the
  specification that feature holds its requirements in.

  A feature needs somewhere to say what it should do from the moment it exists.
  Adopting a specification later would leave a window where the feature can be
  neither described nor judged, so both are written in one transaction: a
  specification the store refuses leaves no feature behind.
  """
  @spec create(Ecto.UUID.t(), actor(), map()) ::
          {:ok, Feature.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create(project_id, actor, attrs) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         {:ok, changeset} <- draft_feature(project_id, member, attrs) do
      insert_with_specification(project_id, member, changeset)
    end
  end

  @doc """
  Returns the project's features grouped into the five fixed lifecycle columns.

  Every column is present, including empty ones, because the board's shape is
  part of the contract rather than a consequence of the data.
  """
  @spec board(Ecto.UUID.t(), actor()) ::
          {:ok, %{String.t() => [Feature.t()]}} | {:error, :unauthorized}
  def board(project_id, actor) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_board) do
      features =
        Feature
        |> where([f], f.project_id == ^project_id)
        |> order_by([f], asc: f.inserted_at, asc: f.id)
        |> Repo.all()

      grouped = Enum.group_by(features, & &1.lifecycle_column)

      {:ok, Map.new(Feature.columns(), &{&1, Map.get(grouped, &1, [])})}
    end
  rescue
    Ecto.Query.CastError -> {:error, :unauthorized}
  end

  @doc "Fetches one feature the acting member may read."
  @spec fetch(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | :not_found}
  def fetch(project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      case get_scoped(project_id, feature_id) do
        nil -> {:error, :not_found}
        feature -> {:ok, feature}
      end
    end
  end

  @doc """
  Applies one legal lifecycle transition against an expected state version.
  """
  @spec transition(Ecto.UUID.t(), actor(), Feature.t(), String.t(), keyword()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | :stale_state | :illegal_transition}
  def transition(project_id, actor, %Feature{} = feature, to, opts \\ []) do
    expected = Keyword.get(opts, :expected_state_version, feature.state_version)

    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         :ok <- scoped?(project_id, feature) do
      feature
      |> Feature.transition_changeset(to, expected, Keyword.take(opts, [:status]))
      |> update()
    end
  end

  @doc "Records a visible status without changing the lifecycle column."
  @spec put_status(Ecto.UUID.t(), actor(), Feature.t(), String.t(), keyword()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | :stale_state | :illegal_transition}
  def put_status(project_id, actor, %Feature{} = feature, status, opts \\ []) do
    expected = Keyword.get(opts, :expected_state_version, feature.state_version)

    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         :ok <- scoped?(project_id, feature) do
      feature
      |> Feature.status_changeset(status, expected)
      |> update()
    end
  end

  @doc """
  Links, or changes, one feature's reference to a current authoritative
  specification. Owner-only: the specification picker depends on
  `capability:project-specification-store`, which stays owner-only readable.
  """
  @spec link_specification(authority(), Ecto.UUID.t(), actor(), Feature.t(), String.t()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | :already_linked | term()}
  def link_specification(authority, project_id, actor, %Feature{} = feature, specification_id) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         true <- member.role == :owner,
         :ok <- scoped?(project_id, feature),
         {:ok, _current} <-
           SpecificationStore.get_current(authority, project_id, specification_id) do
      feature
      |> Feature.specification_link_changeset(specification_id)
      |> Repo.update()
      |> normalize_link_error()
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Clears one feature's specification link. Owner-only, same as linking."
  @spec unlink_specification(Ecto.UUID.t(), actor(), Feature.t()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | term()}
  def unlink_specification(project_id, actor, %Feature{} = feature) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         true <- member.role == :owner,
         :ok <- scoped?(project_id, feature) do
      feature
      |> Feature.specification_link_changeset(nil)
      |> Repo.update()
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists the project's current authoritative specifications not already linked
  to a DIFFERENT feature, for the owner-only link picker. The given feature's
  own current link (if any) stays included so it can render as selected.
  """
  @spec available_specifications(authority(), Ecto.UUID.t(), actor(), Feature.t()) ::
          {:ok, [%{id: String.t(), title: String.t()}]} | {:error, :unauthorized | term()}
  def available_specifications(authority, project_id, actor, %Feature{} = feature) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature),
         true <- member.role == :owner,
         {:ok, snapshot} <- SpecificationStore.current_snapshot(authority, project_id) do
      linked_elsewhere =
        Feature
        |> where(
          [f],
          f.project_id == ^project_id and f.id != ^feature.id and not is_nil(f.specification_id)
        )
        |> select([f], f.specification_id)
        |> Repo.all()
        |> MapSet.new()

      {:ok,
       snapshot.specifications
       |> Enum.reject(&(&1.id in linked_elsewhere))
       |> Enum.map(&%{id: &1.id, title: &1.title})}
    else
      false -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The published capability read: resolves the feature currently linked to
  one project + specification identity, for another approved specification
  to consume (e.g. specs/15-repository-sdd-kit-integration). No actor —
  this is a backend-to-backend capability boundary, not a human action.
  """
  @spec fetch_by_specification(Ecto.UUID.t(), String.t()) ::
          {:ok, Feature.t()} | {:error, :not_linked}
  def fetch_by_specification(project_id, specification_id) do
    case Repo.get_by(Feature, project_id: project_id, specification_id: specification_id) do
      nil -> {:error, :not_linked}
      feature -> {:ok, feature}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_linked}
  end

  # The title is checked before the specification store is asked for anything.
  # A rejected title then costs nothing, and the specification carries the same
  # trimmed title the feature does instead of the raw text the caller sent.
  defp draft_feature(project_id, member, attrs) do
    changeset =
      Feature.create_changeset(%Feature{}, %{
        project_id: project_id,
        title: attrs[:title] || attrs["title"],
        creator_account_id: member.account_id,
        assigned_account_id: attrs[:assigned_account_id] || attrs["assigned_account_id"]
      })

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, _feature} -> {:ok, changeset}
      {:error, invalid} -> {:error, invalid}
    end
  end

  # The feature is inserted first and linked second because the link is only
  # expressible through `Feature.specification_link_changeset/2`, which carries
  # the uniqueness constraint that keeps one specification to one feature. Both
  # writes and the specification share one transaction, so a caller never sees
  # a feature without its specification or a specification without its feature.
  defp insert_with_specification(project_id, member, changeset) do
    title = Ecto.Changeset.get_field(changeset, :title)

    Repo.transaction(fn ->
      with {:ok, specification_id} <- create_specification(project_id, member, title),
           {:ok, feature} <- Repo.insert(changeset),
           {:ok, linked} <- link_created(feature, specification_id) do
        linked
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp link_created(feature, specification_id) do
    feature
    |> Feature.specification_link_changeset(specification_id)
    |> Repo.update()
  end

  # The project's specifications live under the workspace that owns the
  # project, so a participant's feature still writes into the owner's store.
  # The revision records the person who actually acted, which is what makes the
  # history readable later.
  defp create_specification(project_id, member, title) do
    attrs = %{
      id: Ecto.UUID.generate(),
      title: title,
      documents: %{
        requirements: empty_requirements_document(),
        design: @design_document,
        tasks: @tasks_document
      }
    }

    case SpecificationStore.create(owner_authority(project_id), project_id, attrs,
           actor_ref: member.account_id
         ) do
      {:ok, %{specification: specification}} -> {:ok, specification.id}
      {:error, reason} -> {:error, reason}
    end
  end

  # Authority comes from the project, never from the actor. A device or unknown
  # project resolves to `nil`, which the specification store refuses closed
  # without disclosing whether the project exists.
  defp owner_authority(project_id) do
    case Repo.get(Project, project_id) do
      %Project{storage_mode: "hosted", workspace_id: workspace_id} ->
        Repo.get(PersonalWorkspace, workspace_id)

      _other ->
        nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  # The four guided headings, with nothing under them yet. Reading the labels
  # from `Readiness.guided_structure/0` keeps the document the person fills in
  # and the parts readiness judges from drifting apart.
  defp empty_requirements_document do
    Enum.map_join(Readiness.guided_structure(), "\n\n", &"## #{&1.label}") <> "\n"
  end

  defp normalize_link_error({:ok, feature}), do: {:ok, feature}

  defp normalize_link_error({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :specification_id) do
      {:error, :already_linked}
    else
      {:error, changeset}
    end
  end

  defp get_scoped(project_id, feature_id) do
    Feature
    |> where([f], f.project_id == ^project_id and f.id == ^feature_id)
    |> Repo.one()
  rescue
    Ecto.Query.CastError -> nil
  end

  defp scoped?(project_id, %Feature{project_id: project_id}), do: :ok
  defp scoped?(_project_id, %Feature{}), do: {:error, :unauthorized}

  # A record that moved between load and write raises rather than updating no
  # rows, which is exactly the stale case the caller must be told about.
  defp update(changeset) do
    case Repo.update(changeset) do
      {:ok, feature} -> {:ok, feature}
      {:error, invalid} -> normalize(invalid)
    end
  rescue
    Ecto.StaleEntryError -> {:error, :stale_state}
  end

  defp normalize(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :state_version),
      do: {:error, :stale_state},
      else: {:error, :illegal_transition}
  end
end
