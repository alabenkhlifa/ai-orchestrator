defmodule SddOrchestrator.AIRuntime.PersonalAIConnection do
  @moduledoc """
  The minimized control-plane reference to one worker-local personal AI profile.

  Provider credentials and raw provider identity never belong in this schema.
  The account, worker, worker-local profile, provider, and authentication mode
  form an immutable binding after insertion.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @providers ~w(openai_codex)
  @authentication_modes ~w(chatgpt api_key)
  @availabilities ~w(available unavailable incompatible)
  @revocation_states ~w(active requested acknowledged)

  @label_max_length 100
  @worker_profile_ref_max_length 255
  @adapter_version_max_length 100

  @binding_fields [
    :account_id,
    :worker_id,
    :worker_profile_ref,
    :provider,
    :authentication_mode
  ]

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :worker_id,
             :label,
             :provider,
             :authentication_mode,
             :availability,
             :adapter_compatibility_version,
             :revocation_state,
             :revocation_requested_at,
             :revocation_acknowledged_at,
             :inserted_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "personal_ai_connections" do
    field :worker_profile_ref, :string, redact: true
    field :label, :string
    field :provider, :string
    field :authentication_mode, :string
    field :availability, :string
    field :adapter_compatibility_version, :string
    field :revocation_state, :string, default: "active"
    field :revocation_requested_at, :utc_datetime
    field :revocation_acknowledged_at, :utc_datetime

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :worker, SddOrchestrator.Devices.LocalWorker

    timestamps()
  end

  @doc "Builds a new minimized personal-connection record."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :account_id,
      :worker_id,
      :worker_profile_ref,
      :label,
      :provider,
      :authentication_mode,
      :availability,
      :adapter_compatibility_version,
      :revocation_state,
      :revocation_requested_at,
      :revocation_acknowledged_at
    ])
    |> update_change(:label, &String.trim/1)
    |> validate_required([
      :account_id,
      :worker_id,
      :worker_profile_ref,
      :label,
      :provider,
      :authentication_mode,
      :availability,
      :adapter_compatibility_version,
      :revocation_state
    ])
    |> validate_length(:label, min: 1, max: @label_max_length)
    |> validate_length(:worker_profile_ref, min: 1, max: @worker_profile_ref_max_length)
    |> validate_length(:adapter_compatibility_version,
      min: 1,
      max: @adapter_version_max_length
    )
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:authentication_mode, @authentication_modes)
    |> validate_inclusion(:availability, @availabilities)
    |> validate_inclusion(:revocation_state, @revocation_states)
    |> validate_revocation_timestamps()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:worker_id)
    |> unique_constraint(:label, name: :personal_ai_connections_account_label_index)
    |> unique_constraint([:worker_id, :worker_profile_ref],
      name: :personal_ai_connections_worker_profile_index,
      error_key: :worker_profile_ref
    )
  end

  @doc "Rejects rebinding while allowing later label and safe-state workflows."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :account_id,
      :worker_id,
      :worker_profile_ref,
      :label,
      :provider,
      :authentication_mode,
      :availability,
      :adapter_compatibility_version,
      :revocation_state,
      :revocation_requested_at,
      :revocation_acknowledged_at
    ])
    |> reject_rebinding()
    |> update_change(:label, &String.trim/1)
    |> validate_length(:label, min: 1, max: @label_max_length)
    |> validate_inclusion(:availability, @availabilities)
    |> validate_inclusion(:revocation_state, @revocation_states)
    |> validate_revocation_timestamps()
    |> unique_constraint(:label, name: :personal_ai_connections_account_label_index)
  end

  @doc "The only provider admitted by this slice."
  def providers, do: @providers

  @doc "The worker-local authentication modes admitted by this slice."
  def authentication_modes, do: @authentication_modes

  @doc "The safe control-plane availability values."
  def availabilities, do: @availabilities

  @doc "The persisted revocation lifecycle values."
  def revocation_states, do: @revocation_states

  @doc false
  def label_max_length, do: @label_max_length

  @doc false
  def worker_profile_ref_max_length, do: @worker_profile_ref_max_length

  @doc false
  def adapter_version_max_length, do: @adapter_version_max_length

  defp reject_rebinding(changeset) do
    Enum.reduce(@binding_fields, changeset, fn field, changeset ->
      case fetch_change(changeset, field) do
        {:ok, value} ->
          if value != Map.get(changeset.data, field),
            do: add_error(changeset, field, "cannot be changed"),
            else: changeset

        _ ->
          changeset
      end
    end)
  end

  defp validate_revocation_timestamps(changeset) do
    state = get_field(changeset, :revocation_state)
    requested_at = get_field(changeset, :revocation_requested_at)
    acknowledged_at = get_field(changeset, :revocation_acknowledged_at)

    changeset
    |> then(fn changeset ->
      if state == "active" and not is_nil(requested_at),
        do: add_error(changeset, :revocation_requested_at, "does not match state"),
        else: changeset
    end)
    |> then(fn changeset ->
      if state in ["requested", "acknowledged"] and is_nil(requested_at),
        do: add_error(changeset, :revocation_requested_at, "is required"),
        else: changeset
    end)
    |> then(fn changeset ->
      if state == "acknowledged" and is_nil(acknowledged_at),
        do: add_error(changeset, :revocation_acknowledged_at, "is required"),
        else: changeset
    end)
    |> then(fn changeset ->
      if state != "acknowledged" and not is_nil(acknowledged_at),
        do: add_error(changeset, :revocation_acknowledged_at, "does not match state"),
        else: changeset
    end)
  end
end
