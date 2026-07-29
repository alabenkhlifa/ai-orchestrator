defmodule SddOrchestrator.Notifications.AccountNotification do
  @moduledoc """
  One durable in-product notification addressed to an account.

  The schema is intentionally a fixed field set rather than a free-form payload:
  a notification carries the event type, its subject reference and state
  version, a short title and body, optional project and actor display labels, a
  safe internal link, and its read state. Specification documents, feature
  content, comments, evidence, repository details, credentials, and email
  addresses stay behind the authorized link instead of being copied here.

  Slice 07 extends this foundation by adding event types under its own
  `delivery.` namespace; it does not create a second notification store.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account

  @namespaces ~w(participation delivery)
  @event_type_format ~r/\A[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\z/
  @link_format ~r{\A/[^\s?#]*(\?[^\s#]*)?\z}

  @max_title_bytes 120
  @max_body_bytes 400
  @max_label_bytes 120
  @max_ref_bytes 128
  @max_link_bytes 512

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "account_notifications" do
    field :event_type, :string
    field :subject_ref, :string
    field :event_version, :integer, default: 1
    field :title, :string
    field :body, :string
    field :project_label, :string
    field :actor_label, :string
    field :link_path, :string
    field :occurred_at, :utc_datetime
    field :read_at, :utc_datetime

    belongs_to :account, Account

    timestamps()
  end

  @spec namespaces() :: [String.t()]
  def namespaces, do: @namespaces

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :project_label,
      :actor_label,
      :link_path,
      :occurred_at
    ])
    |> put_default(:event_version, 1)
    |> put_default(:occurred_at, now())
    |> validate_required([
      :account_id,
      :event_type,
      :subject_ref,
      :event_version,
      :title,
      :body,
      :link_path,
      :occurred_at
    ])
    |> validate_event_type()
    |> validate_number(:event_version, greater_than: 0)
    |> validate_length(:subject_ref, max: @max_ref_bytes, count: :bytes)
    |> validate_length(:title, max: @max_title_bytes, count: :bytes)
    |> validate_length(:body, max: @max_body_bytes, count: :bytes)
    |> validate_length(:project_label, max: @max_label_bytes, count: :bytes)
    |> validate_length(:actor_label, max: @max_label_bytes, count: :bytes)
    |> validate_link_path()
    |> unique_constraint([:account_id, :event_type, :subject_ref, :event_version],
      name: :account_notifications_event_recipient_index,
      message: "already exists for this recipient"
    )
    |> check_constraint(:link_path, name: :account_notifications_link_path_relative)
    |> foreign_key_constraint(:account_id)
  end

  @doc "Marks one notification read. Re-marking keeps the first read time."
  def read_changeset(%__MODULE__{read_at: nil} = notification, read_at),
    do: change(notification, %{read_at: read_at || now()})

  def read_changeset(%__MODULE__{} = notification, _read_at), do: change(notification, %{})

  @spec unread?(t()) :: boolean()
  def unread?(%__MODULE__{read_at: nil}), do: true
  def unread?(%__MODULE__{}), do: false

  defp validate_event_type(changeset) do
    case get_field(changeset, :event_type) do
      value when is_binary(value) -> validate_event_type_value(changeset, value)
      _other -> changeset
    end
  end

  defp validate_event_type_value(changeset, value) do
    if Regex.match?(@event_type_format, value) and namespace(value) in @namespaces do
      changeset
    else
      add_error(changeset, :event_type, "is not an approved notification event")
    end
  end

  defp namespace(value), do: value |> String.split(".", parts: 2) |> hd()

  # A notification link stays inside the product: an absolute URL, a scheme, a
  # protocol-relative path, or embedded whitespace cannot be stored.
  defp validate_link_path(changeset) do
    case get_field(changeset, :link_path) do
      value when is_binary(value) -> validate_link_value(changeset, value)
      _other -> changeset
    end
  end

  defp validate_link_value(changeset, value) do
    if byte_size(value) <= @max_link_bytes and Regex.match?(@link_format, value) and
         not String.starts_with?(value, "//") do
      changeset
    else
      add_error(changeset, :link_path, "is not a safe in-product link")
    end
  end

  defp put_default(changeset, field, default) do
    if is_nil(get_field(changeset, field)),
      do: put_change(changeset, field, default),
      else: changeset
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
