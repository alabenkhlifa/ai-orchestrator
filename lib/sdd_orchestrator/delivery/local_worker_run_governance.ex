defmodule SddOrchestrator.Delivery.LocalWorkerRunGovernance do
  @moduledoc """
  The link between one governed `AgentRun` and its pinned `AIRuntimeSession`.

  A run's absence from this table is what "ungoverned" means; there is no
  separate boolean to fall out of sync with it. A row is created at most once
  per run, only after a session is actually pinned, and never mutated
  afterward (see specs/34-local-worker-runtime-governance/design.md, "A new
  owned join entity instead of extending AgentRun or AIRuntimeSession").
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.AIRuntime.AIRuntimeSession
  alias SddOrchestrator.Delivery.AgentRun
  alias SddOrchestrator.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{}

  schema "local_worker_run_governance" do
    belongs_to :run, AgentRun
    belongs_to :session, AIRuntimeSession

    timestamps()
  end

  @doc "Builds the changeset for one run's session pin."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(governance, attrs) do
    governance
    |> cast(attrs, [:run_id, :session_id])
    |> validate_required([:run_id, :session_id])
    |> unique_constraint(:run_id, name: :local_worker_run_governance_run_index)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:session_id)
  end

  @doc "Returns the governance row pinned to one run, or `nil` when ungoverned."
  @spec for_run(Ecto.UUID.t()) :: t() | nil
  def for_run(run_id), do: Repo.get_by(__MODULE__, run_id: run_id)

  @doc """
  Records the session pinned to one run.

  Idempotent on the run's unique index: recording the same run a second time
  returns the existing row instead of creating a duplicate, which is what
  makes a resume, retry, or reject-driven reattempt's re-pin a safe no-op.
  """
  @spec record(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(run_id, session_id) do
    %__MODULE__{}
    |> changeset(%{run_id: run_id, session_id: session_id})
    |> Repo.insert()
    |> case do
      {:ok, governance} -> {:ok, governance}
      {:error, changeset} -> resolve_conflict(changeset, run_id)
    end
  end

  defp resolve_conflict(changeset, run_id) do
    if Keyword.has_key?(changeset.errors, :run_id) do
      case for_run(run_id) do
        %__MODULE__{} = governance -> {:ok, governance}
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end
end
