defmodule SddOrchestrator.Delivery.NotificationAccess do
  @moduledoc """
  Authorized, minimized reads over one account's guided-delivery notifications.

  `SddOrchestrator.Notifications` stores the shared account-level notification
  record; it authorizes at the account boundary alone, which is exactly right
  for a record whose recipient may have left the project it was about. A
  guided-delivery list has a stricter promise: only *currently* authorized
  records are shown, so a departed participant stops seeing a project's
  delivery notifications on the very next read, with no cache to invalidate.

  Every candidate record is revalidated against
  `SddOrchestrator.Delivery.ParticipantGuard` on every call — a project id is
  parsed out of the record's own `link_path` (this schema keeps no
  `project_id` column), and the acting person's current membership is
  re-checked through the participation boundary. A record whose link cannot be
  parsed to a project, or whose project the actor is no longer a current
  member of, is dropped rather than shown or backfilled. Participation lookups
  are memoized within one call so that several notifications from the same
  project cost one lookup, never across separate calls.

  The list is restricted to the `delivery.` event-type namespace: Slice 08's
  own `participation.` notifications are a different feature's concern and are
  never returned here.
  """

  import Ecto.Query

  alias SddOrchestrator.Delivery.{Features, ParticipantGuard}
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Repo

  @default_limit 50
  @max_limit 200
  @namespace "delivery."
  @project_link ~r{^/projects/([^/]+)(?:/|$)}
  @feature_link ~r{^/projects/([^/]+)/features/([^/]+)$}

  @type actor :: ParticipantGuard.actor()

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc """
  Lists one account's guided-delivery notifications, newest first.

  Authorization is revalidated on every call: a record is only returned when
  `actor` is presently a current participant (or owner) of the project its
  `link_path` names. Options: `:limit`, capped at `max_limit/0` and defaulting
  to `default_limit/0`. Dropping an unauthorized or unparsable record shortens
  the page rather than being backfilled to the requested size.
  """
  @spec list(Ecto.UUID.t() | nil, actor(), keyword()) :: [AccountNotification.t()]
  def list(account_id, actor, opts \\ [])
  def list(nil, _actor, _opts), do: []

  def list(account_id, actor, opts) do
    account_id
    |> candidates(opts)
    |> filter_authorized(actor)
  rescue
    Ecto.Query.CastError -> []
  end

  @doc """
  Fetches one account's guided-delivery notification, revalidating current
  participation the same way `list/3` does.

  A genuinely unknown id, a record belonging to another account, a record
  whose link cannot be parsed to a project, and a record whose project the
  actor is no longer a current participant of all return the identical
  `{:error, :not_found}` — nothing here discloses which case occurred.
  """
  @spec fetch(Ecto.UUID.t() | nil, actor(), Ecto.UUID.t()) ::
          {:ok, AccountNotification.t()} | {:error, :not_found}
  def fetch(account_id, actor, id) do
    with {:ok, notification} <- Notifications.fetch(account_id, id),
         true <- authorized_record?(notification, actor) do
      {:ok, notification}
    else
      _denied -> {:error, :not_found}
    end
  end

  @doc """
  Marks one account's guided-delivery notification read, gated behind the
  same authorization revalidation as `fetch/3`.

  The durable, idempotent read transition itself belongs to
  `SddOrchestrator.Notifications.mark_read/3`, which already keeps the first
  `read_at` across repeated calls; this function only stands the current
  participation gate in front of it, so a removed participant cannot mark a
  stale notification read.
  """
  @spec mark_read(Ecto.UUID.t() | nil, actor(), Ecto.UUID.t()) ::
          {:ok, AccountNotification.t()} | {:error, :not_found}
  def mark_read(account_id, actor, id) do
    with {:ok, _notification} <- fetch(account_id, actor, id) do
      Notifications.mark_read(account_id, id)
    end
  end

  @doc """
  Resolves one account's guided-delivery notification to its safe feature
  link, so an authorized recipient can be returned to the related feature
  without ever disclosing whether an inaccessible project or notification
  exists.

  `fetch/3` first authorizes the notification itself, exactly as `list/3` and
  `mark_read/3` do. The notification's `link_path` is then parsed into a
  project id and a feature id — the one `"/projects/:id/features/:id"` shape
  every `delivery.` notification uses — and
  `SddOrchestrator.Delivery.Features.fetch/3` authorizes `:view_feature` and
  scopes the feature lookup to that exact project id, so a feature id that
  genuinely belongs to a different project misses even when the parsed
  project id is one the actor currently belongs to. On success the caller
  gets back the exact stored `link_path`, not a reconstructed one and not the
  feature itself. An unknown id, a removed or cross-project participant, an
  unparsable link, and a feature that does not genuinely belong to its
  project all collapse to the identical `{:error, :not_found}` — nothing here
  discloses which case occurred.
  """
  @spec resolve_safe_link(Ecto.UUID.t() | nil, actor(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, :not_found}
  def resolve_safe_link(account_id, actor, id) do
    with {:ok, notification} <- fetch(account_id, actor, id),
         {:ok, project_id, feature_id} <- project_and_feature_id(notification.link_path),
         {:ok, _feature} <- Features.fetch(project_id, actor, feature_id) do
      {:ok, notification.link_path}
    else
      _denied -> {:error, :not_found}
    end
  end

  defp authorized_record?(notification, actor) do
    {result, _cache} = authorized?(notification, actor, %{})
    result
  end

  defp candidates(account_id, opts) do
    AccountNotification
    |> where([n], n.account_id == ^account_id)
    |> where([n], like(n.event_type, ^(@namespace <> "%")))
    |> order_by([n], desc: n.occurred_at, desc: n.id)
    |> limit(^limit_for(opts))
    |> Repo.all()
  end

  # A single reduce over the page keeps the per-project authorization check to
  # one lookup no matter how many of the account's notifications share a
  # project, without remembering anything past this one call.
  defp filter_authorized(notifications, actor) do
    {kept, _cache} =
      Enum.reduce(notifications, {[], %{}}, fn notification, {kept, cache} ->
        case authorized?(notification, actor, cache) do
          {true, cache} -> {[notification | kept], cache}
          {false, cache} -> {kept, cache}
        end
      end)

    Enum.reverse(kept)
  end

  defp authorized?(notification, actor, cache) do
    case project_id(notification.link_path) do
      {:ok, project_id} -> authorized_for_project(project_id, actor, cache)
      :error -> {false, cache}
    end
  end

  defp authorized_for_project(project_id, actor, cache) do
    case Map.fetch(cache, project_id) do
      {:ok, authorized?} ->
        {authorized?, cache}

      :error ->
        authorized? = current_participant?(project_id, actor)
        {authorized?, Map.put(cache, project_id, authorized?)}
    end
  end

  defp current_participant?(project_id, actor) do
    case ParticipantGuard.authorize(project_id, actor) do
      {:ok, _member} -> true
      {:error, :unauthorized} -> false
    end
  end

  # Fails closed on anything that is not a well-formed project link: a nil or
  # malformed `link_path`, or a captured segment that is not a real project id.
  defp project_id(link_path) when is_binary(link_path) do
    case Regex.run(@project_link, link_path) do
      [_match, id] -> Ecto.UUID.cast(id)
      _no_match -> :error
    end
  end

  defp project_id(_link_path), do: :error

  # Fails closed on anything that is not the exact
  # "/projects/:project_id/features/:feature_id" shape every `delivery.`
  # notification's `link_path` uses, including a segment that is not a real
  # UUID. Shares the same fail-closed contract as `project_id/1` above rather
  # than a second, possibly inconsistent, parser.
  defp project_and_feature_id(link_path) when is_binary(link_path) do
    case Regex.run(@feature_link, link_path) do
      [_match, project_id, feature_id] ->
        with {:ok, project_id} <- Ecto.UUID.cast(project_id),
             {:ok, feature_id} <- Ecto.UUID.cast(feature_id) do
          {:ok, project_id, feature_id}
        else
          :error -> :error
        end

      _no_match ->
        :error
    end
  end

  defp project_and_feature_id(_link_path), do: :error

  defp limit_for(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> case do
      limit when is_integer(limit) and limit > 0 -> min(limit, @max_limit)
      _invalid -> @default_limit
    end
  end
end
