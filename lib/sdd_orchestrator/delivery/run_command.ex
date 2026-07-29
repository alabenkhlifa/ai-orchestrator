defmodule SddOrchestrator.Delivery.RunCommand do
  @moduledoc """
  One durable instruction for the configured worker.

  Commands are the reason a run survives a control-plane restart. Nothing about
  a pending start, resume, retry, cancel, or reconcile lives in process memory:
  it is a row, it has a due time, and whichever dispatcher claims it next
  delivers it.

  Delivery is at least once, so the command ID is supplied by the enqueueing
  transaction rather than generated here. Re-enqueueing the same instruction
  returns the recorded result instead of starting a second agent process, and a
  redelivered command is recognised by the worker through the same ID.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{AgentRun, RunAttempt}
  alias SddOrchestrator.Projects.Project

  @operations ~w(start resume retry cancel reconcile)
  @execution_operations ~w(start resume retry)
  @control_operations ~w(cancel reconcile)
  @states ~w(pending claimed delivered acknowledged failed)
  @terminal_states ~w(acknowledged failed)

  @max_owner_bytes 200
  @max_result_bytes 4_000

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "run_commands" do
    field :operation, :string
    field :expected_state_version, :integer
    field :manifest_digest, :string
    field :due_at, :utc_datetime_usec
    field :state, :string, default: "pending"
    field :claimed_by, :string
    field :claim_expires_at, :utc_datetime_usec
    field :delivery_count, :integer, default: 0
    field :delivered_at, :utc_datetime_usec
    field :acknowledged_at, :utc_datetime_usec
    field :result, :map
    field :failure_code, :string

    belongs_to :project, Project
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt

    timestamps()
  end

  @spec operations() :: [String.t()]
  def operations, do: @operations

  @spec execution_operations() :: [String.t()]
  def execution_operations, do: @execution_operations

  @spec control_operations() :: [String.t()]
  def control_operations, do: @control_operations

  @spec states() :: [String.t()]
  def states, do: @states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc "Reports whether a claim is still held at `now`."
  @spec claim_active?(t(), DateTime.t()) :: boolean()
  def claim_active?(%__MODULE__{claim_expires_at: nil}, _now), do: false

  def claim_active?(%__MODULE__{claim_expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  @doc """
  Builds one enqueue. The caller supplies the stable ID it will use again if the
  same instruction is produced twice.
  """
  def enqueue_changeset(command, attrs) do
    command
    |> cast(attrs, [
      :id,
      :project_id,
      :run_id,
      :attempt_id,
      :operation,
      :expected_state_version,
      :manifest_digest,
      :due_at
    ])
    |> put_default_due_at()
    |> put_change(:state, "pending")
    |> put_change(:delivery_count, 0)
    |> validate_required([
      :id,
      :project_id,
      :run_id,
      :operation,
      :expected_state_version,
      :due_at
    ])
    |> validate_inclusion(:operation, @operations)
    |> validate_number(:expected_state_version, greater_than: 0)
    |> validate_manifest_placement()
    |> apply_constraints()
  end

  @doc """
  Claims the command for one dispatcher until `expires_at`.

  Only a pending or previously claimed command may be claimed; a delivered or
  terminal command is never returned to the queue by a claim.
  """
  def claim_changeset(%__MODULE__{} = command, owner, expires_at) do
    command
    |> change(%{})
    |> validate_claimable()
    |> put_change(:state, "claimed")
    |> put_change(:claimed_by, owner)
    |> put_change(:claim_expires_at, expires_at)
    |> validate_required([:claimed_by, :claim_expires_at])
    |> validate_length(:claimed_by, max: @max_owner_bytes, count: :bytes)
    |> apply_constraints()
  end

  @doc "Records one delivery attempt. Delivery is at least once by design."
  def delivered_changeset(%__MODULE__{} = command, now) do
    command
    |> change(%{})
    |> put_change(:state, "delivered")
    |> put_change(:delivered_at, now)
    |> put_change(:delivery_count, command.delivery_count + 1)
    |> apply_constraints()
  end

  @doc """
  Records the worker's acknowledgement and its result.

  The result is what a duplicate enqueue replays, so it is stored once and
  never overwritten by a later redelivery of the same command.
  """
  def acknowledge_changeset(%__MODULE__{} = command, result, now) do
    command
    |> change(%{})
    |> put_change(:state, "acknowledged")
    |> put_change(:acknowledged_at, now)
    |> put_change(:result, result || %{})
    |> put_change(:claimed_by, nil)
    |> put_change(:claim_expires_at, nil)
    |> validate_result_size()
    |> apply_constraints()
  end

  @doc "Records a terminal delivery failure with a short code."
  def failed_changeset(%__MODULE__{} = command, failure_code, now) do
    command
    |> change(%{})
    |> put_change(:state, "failed")
    |> put_change(:failure_code, failure_code)
    |> put_change(:acknowledged_at, now)
    |> put_change(:claimed_by, nil)
    |> put_change(:claim_expires_at, nil)
    |> validate_required([:failure_code])
    |> apply_constraints()
  end

  @doc "Returns an expired or abandoned claim to the queue."
  def release_changeset(%__MODULE__{} = command, due_at) do
    command
    |> change(%{})
    |> put_change(:state, "pending")
    |> put_change(:claimed_by, nil)
    |> put_change(:claim_expires_at, nil)
    |> put_change(:due_at, due_at)
    |> apply_constraints()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = command) do
    %{
      "id" => command.id,
      "project_id" => command.project_id,
      "run_id" => command.run_id,
      "attempt_id" => command.attempt_id,
      "operation" => command.operation,
      "expected_state_version" => command.expected_state_version,
      "manifest_digest" => command.manifest_digest,
      "due_at" => DateTime.to_iso8601(command.due_at),
      "state" => command.state,
      "delivery_count" => command.delivery_count,
      "result" => command.result,
      "failure_code" => command.failure_code
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_command_value}
  def from_value(%{} = value) do
    with true <- value["operation"] in @operations,
         true <- value["state"] in @states,
         true <- is_binary(value["id"]) and is_binary(value["run_id"]),
         true <- is_integer(value["expected_state_version"]),
         true <- value["expected_state_version"] > 0,
         {:ok, due_at, _offset} <- DateTime.from_iso8601(value["due_at"] || "") do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         operation: value["operation"],
         expected_state_version: value["expected_state_version"],
         manifest_digest: value["manifest_digest"],
         due_at: due_at,
         state: value["state"],
         delivery_count: value["delivery_count"] || 0,
         result: value["result"],
         failure_code: value["failure_code"]
       }}
    else
      _invalid -> {:error, :invalid_command_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_command_value}

  defp put_default_due_at(changeset) do
    case get_field(changeset, :due_at) do
      nil -> put_change(changeset, :due_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp validate_manifest_placement(changeset) do
    operation = get_field(changeset, :operation)
    digest = get_field(changeset, :manifest_digest)

    cond do
      operation in @execution_operations and is_nil(digest) ->
        add_error(changeset, :manifest_digest, "is required for #{operation}")

      operation in @control_operations and not is_nil(digest) ->
        add_error(changeset, :manifest_digest, "is not allowed for #{operation}")

      true ->
        changeset
    end
  end

  defp validate_claimable(changeset) do
    if changeset.data.state in ~w(pending claimed) do
      changeset
    else
      add_error(changeset, :state, "is not claimable")
    end
  end

  defp validate_result_size(changeset) do
    case get_field(changeset, :result) do
      result when is_map(result) -> validate_encoded_size(changeset, result)
      _other -> changeset
    end
  end

  defp validate_encoded_size(changeset, result) do
    if byte_size(Jason.encode!(result)) > @max_result_bytes do
      add_error(changeset, :result, "is larger than #{@max_result_bytes} bytes")
    else
      changeset
    end
  rescue
    Protocol.UndefinedError -> add_error(changeset, :result, "is not encodable")
  end

  defp apply_constraints(changeset) do
    changeset
    |> validate_inclusion(:state, @states)
    |> validate_number(:delivery_count, greater_than_or_equal_to: 0)
    |> check_constraint(:operation, name: :run_commands_operation_allowed)
    |> check_constraint(:manifest_digest, name: :run_commands_manifest_placement)
    |> check_constraint(:claimed_by, name: :run_commands_claim_pairing)
    |> check_constraint(:state, name: :run_commands_state_allowed)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
  end
end
