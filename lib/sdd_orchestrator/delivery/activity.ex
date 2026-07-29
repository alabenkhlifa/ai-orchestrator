defmodule SddOrchestrator.Delivery.Activity do
  @moduledoc """
  Appending to and reading one feature's ordered history.

  Every state-changing delivery action appends its activity in the same
  transaction that applies the state change, so history and state can never
  disagree. `append_multi/3` exists for exactly that: it takes the position
  inside the caller's `Ecto.Multi` rather than opening a transaction of its own.

  Reads are authorized on every call through the participation guard, and the
  list is paginated by authoritative sequence rather than by timestamp, so a
  clock skew cannot reorder a feature's story.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Delivery.{ActivityEntry, ParticipantGuard}
  alias SddOrchestrator.Repo

  @default_limit 50
  @max_limit 200

  @type actor :: ParticipantGuard.actor()

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Appends one entry in its own transaction.

  Used by callers that have no other state to change; everything else composes
  `append_multi/3` into its own transaction instead.
  """
  @spec append(map()) :: {:ok, ActivityEntry.t()} | {:error, Ecto.Changeset.t()}
  def append(attrs) do
    Multi.new()
    |> append_multi(:activity, attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{activity: entry}} -> {:ok, entry}
      {:error, :activity, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Adds one ordered append to the caller's transaction.

  `attrs` may be a map or a one-argument function of the transaction's changes
  so far, which is what lets an append name a run or attempt created earlier in
  the same transaction.
  """
  @spec append_multi(Multi.t(), Multi.name(), map() | (map() -> map())) :: Multi.t()
  def append_multi(multi, name, attrs) do
    Multi.insert(multi, name, fn changes ->
      attrs = resolve(attrs, changes)

      %ActivityEntry{}
      |> ActivityEntry.append_changeset(Map.put(attrs, :sequence, next_sequence(attrs)))
    end)
  end

  @doc """
  Returns the next authoritative position for one feature.

  Read inside the appending transaction. Two concurrent appends can compute the
  same number; the unique index rejects the loser so it retries rather than
  silently overwriting the winner's position.
  """
  @spec next_sequence(map() | Ecto.UUID.t()) :: pos_integer()
  def next_sequence(%{} = attrs), do: attrs |> feature_id() |> next_sequence()

  def next_sequence(feature_id) when is_binary(feature_id) do
    ActivityEntry
    |> where([e], e.feature_id == ^feature_id)
    |> select([e], max(e.sequence))
    |> Repo.one()
    |> case do
      nil -> 1
      highest -> highest + 1
    end
  rescue
    Ecto.Query.CastError -> 1
  end

  @doc """
  Lists one feature's activity in authoritative order for an authorized member.

  Options: `:limit` (capped) and `:after_sequence` for the pagination cursor.
  """
  @spec list(Ecto.UUID.t(), actor(), Ecto.UUID.t(), keyword()) ::
          {:ok, [ActivityEntry.t()]} | {:error, :unauthorized}
  def list(project_id, actor, feature_id, opts \\ []) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :view_feature) do
      {:ok, read_page(project_id, feature_id, opts)}
    end
  end

  @doc "The most recent entries first, for a compact feature-detail summary."
  @spec recent(Ecto.UUID.t(), actor(), Ecto.UUID.t(), keyword()) ::
          {:ok, [ActivityEntry.t()]} | {:error, :unauthorized}
  def recent(project_id, actor, feature_id, opts \\ []) do
    with {:ok, entries} <- list(project_id, actor, feature_id, opts) do
      {:ok, Enum.reverse(entries)}
    end
  end

  defp read_page(project_id, feature_id, opts) do
    ActivityEntry
    |> where([e], e.project_id == ^project_id and e.feature_id == ^feature_id)
    |> after_sequence(Keyword.get(opts, :after_sequence))
    |> order_by([e], asc: e.sequence)
    |> limit(^limit_for(opts))
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  defp after_sequence(query, nil), do: query

  defp after_sequence(query, sequence) when is_integer(sequence),
    do: where(query, [e], e.sequence > ^sequence)

  defp after_sequence(query, _sequence), do: query

  defp limit_for(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> case do
      limit when is_integer(limit) and limit > 0 -> min(limit, @max_limit)
      _invalid -> @default_limit
    end
  end

  defp resolve(attrs, changes) when is_function(attrs, 1), do: attrs.(changes)
  defp resolve(attrs, _changes), do: attrs

  defp feature_id(attrs), do: Map.get(attrs, :feature_id) || Map.get(attrs, "feature_id")
end
