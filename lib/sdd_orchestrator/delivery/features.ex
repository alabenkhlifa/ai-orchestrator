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

  alias SddOrchestrator.Delivery.{Feature, ParticipantGuard}
  alias SddOrchestrator.Repo

  @type actor :: ParticipantGuard.actor()

  @doc "Creates one feature in `Draft` for the acting member."
  @spec create(Ecto.UUID.t(), actor(), map()) ::
          {:ok, Feature.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create(project_id, actor, attrs) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      %Feature{}
      |> Feature.create_changeset(%{
        project_id: project_id,
        title: attrs[:title] || attrs["title"],
        creator_account_id: member.account_id,
        assigned_account_id: attrs[:assigned_account_id] || attrs["assigned_account_id"]
      })
      |> Repo.insert()
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
