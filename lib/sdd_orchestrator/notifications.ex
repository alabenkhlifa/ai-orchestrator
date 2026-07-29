defmodule SddOrchestrator.Notifications do
  @moduledoc """
  The shared account-level in-product notification foundation.

  Delivery is the stored unread record, not the broadcast: `deliver/1` commits
  the notification first and publishes a PubSub hint afterwards, so a
  disconnected browser or a restarted node still finds its unread work. The
  unique event, subject, version, and recipient key makes an at-least-once
  projector replay idempotent.

  Reads are authorized at the account boundary on every call, which keeps a
  notification readable after project access ends while its linked project
  content stays behind the link's own authorization.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Repo

  @topic_prefix "account_notifications:"
  @conflict_target [:account_id, :event_type, :subject_ref, :event_version]

  @doc """
  Creates one notification, or returns the existing record when the same event,
  subject, version, and recipient was already delivered.
  """
  @spec deliver(map()) :: {:ok, AccountNotification.t()} | {:error, Ecto.Changeset.t()}
  def deliver(attrs) do
    changeset = AccountNotification.changeset(%AccountNotification{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: @conflict_target) do
      {:ok, _inserted} -> {:ok, publish(get_by_key(Repo, changeset))}
      {:error, invalid} -> {:error, invalid}
    end
  end

  @doc """
  Contributes one idempotent notification insertion to a caller transaction.

  The projector commits authoritative state and its notifications together;
  the PubSub hint is published only after that transaction succeeds. The step
  named `name` always resolves to the stored record, whether this attempt
  created it or a prior delivery already did.
  """
  @spec deliver_multi(Multi.t(), Multi.name(), map()) :: Multi.t()
  def deliver_multi(multi, name, attrs) do
    multi
    |> Multi.insert({name, :insert}, changeset(attrs), insert_options())
    |> Multi.run(name, fn repo, _changes -> {:ok, get_by_key(repo, changeset(attrs))} end)
  end

  @doc "Builds one notification changeset for a caller-owned transaction step."
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attrs), do: AccountNotification.changeset(%AccountNotification{}, attrs)

  @doc "Insert options that make a notification step idempotent under replay."
  @spec insert_options() :: keyword()
  def insert_options, do: [on_conflict: :nothing, conflict_target: @conflict_target]

  @doc "Publishes the presentation hint for notifications committed in a transaction."
  @spec publish_committed([AccountNotification.t() | nil]) :: :ok
  def publish_committed(notifications) do
    notifications
    |> Enum.reject(&(is_nil(&1) or is_nil(&1.id)))
    |> Enum.each(&publish/1)
  end

  @doc "Lists one account's notifications, newest first."
  @spec list(Ecto.UUID.t() | nil, keyword()) :: [AccountNotification.t()]
  def list(account_id, opts \\ [])
  def list(nil, _opts), do: []

  def list(account_id, opts) do
    limit = Keyword.get(opts, :limit, 50)

    AccountNotification
    |> where([n], n.account_id == ^account_id)
    |> then(&maybe_unread_only(&1, Keyword.get(opts, :unread_only, false)))
    |> order_by([n], desc: n.occurred_at, desc: n.id)
    |> limit(^limit)
    |> Repo.all()
  rescue
    Ecto.Query.CastError -> []
  end

  @doc "Counts one account's unread notifications."
  @spec unread_count(Ecto.UUID.t() | nil) :: non_neg_integer()
  def unread_count(nil), do: 0

  def unread_count(account_id) do
    AccountNotification
    |> where([n], n.account_id == ^account_id and is_nil(n.read_at))
    |> Repo.aggregate(:count)
  rescue
    Ecto.Query.CastError -> 0
  end

  @doc "Fetches one notification, failing closed for another account."
  @spec fetch(Ecto.UUID.t() | nil, Ecto.UUID.t()) ::
          {:ok, AccountNotification.t()} | {:error, :not_found}
  def fetch(nil, _id), do: {:error, :not_found}

  def fetch(account_id, id) do
    AccountNotification
    |> where([n], n.account_id == ^account_id and n.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      notification -> {:ok, notification}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Marks one notification read for its own recipient.

  Repeating the action keeps the first read time and still succeeds, so a
  retried client action cannot fail or rewrite history.
  """
  @spec mark_read(Ecto.UUID.t() | nil, Ecto.UUID.t(), DateTime.t() | nil) ::
          {:ok, AccountNotification.t()} | {:error, :not_found}
  def mark_read(account_id, id, read_at \\ nil) do
    with {:ok, notification} <- fetch(account_id, id) do
      notification
      |> AccountNotification.read_changeset(truncate(read_at))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, _changeset} -> {:error, :not_found}
      end
    end
  end

  @doc "Subscribes the caller to one account's presentation hints."
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(account_id),
    do: Phoenix.PubSub.subscribe(SddOrchestrator.PubSub, topic(account_id))

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(account_id), do: @topic_prefix <> account_id

  defp maybe_unread_only(query, true), do: where(query, [n], is_nil(n.read_at))
  defp maybe_unread_only(query, _false), do: query

  # Resolves the canonical stored record for one delivery, so a replay returns
  # the notification that already exists instead of a phantom insert result.
  defp get_by_key(repo, %Ecto.Changeset{} = changeset) do
    notification = Ecto.Changeset.apply_changes(changeset)

    AccountNotification
    |> where(
      [n],
      n.account_id == ^notification.account_id and n.event_type == ^notification.event_type and
        n.subject_ref == ^notification.subject_ref and
        n.event_version == ^notification.event_version
    )
    |> repo.one()
  end

  defp publish(notification) do
    Phoenix.PubSub.broadcast(
      SddOrchestrator.PubSub,
      topic(notification.account_id),
      {:account_notification, notification.id}
    )

    notification
  end

  defp truncate(nil), do: nil
  defp truncate(%DateTime{} = value), do: DateTime.truncate(value, :second)
end
