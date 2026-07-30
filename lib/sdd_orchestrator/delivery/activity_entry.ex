defmodule SddOrchestrator.Delivery.ActivityEntry do
  @moduledoc """
  One ordered, immutable, user-visible record in a feature's history.

  Activity is what makes an agent run reviewable: progress, comments, blocking
  questions, accepted answers, evidence, preview outcomes, and final results
  all land here in authoritative order, and none of them can be rewritten
  afterwards.

  Two rules give the record its value. It is append-only — a database trigger
  rejects `UPDATE`, so immutability does not depend on every caller behaving.
  And its payload is a minimized normalized projection: raw provider events,
  transcripts, and credential-shaped fields are rejected at the changeset
  rather than filtered later, because a stream that is never stored cannot
  leak.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Accounts.Account
  alias SddOrchestrator.Delivery.{AgentRun, Feature, RunAttempt}
  alias SddOrchestrator.Projects.Project

  @actor_kinds ~w(participant agent system)

  @types ~w(
    assignment_changed
    comment
    evidence_recorded
    preview_updated
    progress
    question_answered
    question_asked
    readiness_evaluated
    reconciled
    retry_scheduled
    review_approved
    review_rejected
    revocation_applied
    run_canceled
    run_completed
    run_failed
    run_started
    suggestion_dismissed
    verification_completed
    verification_refused
  )

  # Payload keys that would carry a raw provider stream, a transcript, or a
  # credential. These never become project activity, so they are rejected on the
  # way in instead of being redacted on the way out.
  @forbidden_payload_keys ~w(
    access_token
    api_key
    authorization
    completion
    credential
    email
    messages
    password
    prompt
    provider_event
    raw
    raw_event
    secret
    stderr
    stdout
    token
    transcript
  )

  @max_payload_bytes 4_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime, updated_at: false]

  @type t :: %__MODULE__{}

  schema "activity_entries" do
    field :actor_kind, :string
    field :type, :string
    field :sequence, :integer
    field :occurred_at, :utc_datetime_usec
    field :payload, :map, default: %{}

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt
    belongs_to :actor_account, Account

    timestamps()
  end

  @spec actor_kinds() :: [String.t()]
  def actor_kinds, do: @actor_kinds

  @spec types() :: [String.t()]
  def types, do: @types

  @spec forbidden_payload_keys() :: [String.t()]
  def forbidden_payload_keys, do: @forbidden_payload_keys

  @spec max_payload_bytes() :: pos_integer()
  def max_payload_bytes, do: @max_payload_bytes

  @doc """
  Builds one append. There is deliberately no update changeset.

  `:sequence` is supplied by the appending transaction because authoritative
  order is a property of the transaction, not of the caller's clock.
  """
  def append_changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :actor_kind,
      :actor_account_id,
      :type,
      :sequence,
      :occurred_at,
      :payload
    ])
    |> put_default_occurred_at()
    |> validate_required([:project_id, :feature_id, :actor_kind, :type, :sequence, :occurred_at])
    |> validate_inclusion(:actor_kind, @actor_kinds)
    |> validate_inclusion(:type, @types)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_actor_pairing()
    |> validate_payload()
    |> check_constraint(:actor_kind, name: :activity_entries_actor_pairing)
    |> check_constraint(:type, name: :activity_entries_type_allowed)
    |> unique_constraint([:feature_id, :sequence])
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:actor_account_id)
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = entry) do
    %{
      "id" => entry.id,
      "project_id" => entry.project_id,
      "feature_id" => entry.feature_id,
      "run_id" => entry.run_id,
      "attempt_id" => entry.attempt_id,
      "actor_kind" => entry.actor_kind,
      "actor_account_id" => entry.actor_account_id,
      "type" => entry.type,
      "sequence" => entry.sequence,
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "payload" => entry.payload
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_activity_value}
  def from_value(%{} = value) do
    with true <- value["actor_kind"] in @actor_kinds,
         true <- value["type"] in @types,
         true <- is_integer(value["sequence"]) and value["sequence"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["feature_id"]),
         true <- is_map(value["payload"] || %{}),
         {:ok, occurred_at, _offset} <- DateTime.from_iso8601(value["occurred_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         actor_kind: value["actor_kind"],
         actor_account_id: value["actor_account_id"],
         type: value["type"],
         sequence: value["sequence"],
         occurred_at: occurred_at,
         payload: value["payload"] || %{}
       }}
    else
      _invalid -> {:error, :invalid_activity_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_activity_value}

  defp put_default_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil -> put_change(changeset, :occurred_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp validate_actor_pairing(changeset) do
    kind = get_field(changeset, :actor_kind)
    account_id = get_field(changeset, :actor_account_id)

    case {kind, account_id} do
      {"participant", nil} ->
        add_error(changeset, :actor_account_id, "is required for a participant entry")

      {kind, account_id} when kind in ~w(agent system) and not is_nil(account_id) ->
        add_error(changeset, :actor_account_id, "is not allowed for a #{kind} entry")

      _valid ->
        changeset
    end
  end

  defp validate_payload(changeset) do
    case get_field(changeset, :payload) do
      payload when is_map(payload) -> validate_payload_content(changeset, payload)
      nil -> put_change(changeset, :payload, %{})
      _other -> add_error(changeset, :payload, "must be a map")
    end
  end

  defp validate_payload_content(changeset, payload) do
    cond do
      forbidden = forbidden_key(payload) ->
        add_error(changeset, :payload, "must not carry #{forbidden}")

      payload_bytes(payload) > @max_payload_bytes ->
        add_error(changeset, :payload, "is larger than #{@max_payload_bytes} bytes")

      true ->
        changeset
    end
  end

  # Any nesting depth is checked, because a raw stream hidden one level down is
  # still a raw stream.
  defp forbidden_key(payload) when is_map(payload) do
    Enum.find_value(payload, fn {key, value} ->
      if to_string(key) in @forbidden_payload_keys, do: to_string(key), else: forbidden_key(value)
    end)
  end

  defp forbidden_key(values) when is_list(values), do: Enum.find_value(values, &forbidden_key/1)
  defp forbidden_key(_value), do: nil

  defp payload_bytes(payload) do
    payload |> Jason.encode!() |> byte_size()
  rescue
    Protocol.UndefinedError -> @max_payload_bytes + 1
  end
end
