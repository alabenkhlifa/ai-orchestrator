defmodule SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter do
  @moduledoc """
  Read-only worker boundary for observing one project's current working tree
  (AC-08, AC-09).

  Requests carry only opaque project and repository target references, never
  a filesystem path or credential. A real implementation resolves the bound
  worker for `project_id` inside the worker boundary — the same way
  `SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability` already
  resolves worker reachability without the caller supplying a worker
  identifier — and reports the current branch, current commit when one
  exists, dirty state, and a digest of relevant working-tree state captured
  at scan start and again at scan completion, so a caller can detect
  concurrent change without a second round trip.

  This adapter answers only the single bounded "observe current state"
  question. It never lists a tree, runs a text search, or reads a line range;
  those bounded progressive-discovery operations and the worker-local
  `RepositorySourceIndex` belong to a later task's own adapter.
  """

  @type request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t() | nil,
          required(:repository_ref) => String.t() | nil,
          required(:exclusions) => [String.t()]
        }

  @type result :: %{
          required(:branch) => String.t() | nil,
          required(:commit) => String.t() | nil,
          required(:dirty) => boolean(),
          required(:scan_started_at) => DateTime.t(),
          required(:scan_completed_at) => DateTime.t(),
          required(:exclusions) => [String.t()],
          required(:before_digest) => String.t(),
          required(:after_digest) => String.t()
        }

  @callback observe(request()) :: {:ok, result()} | {:error, atom()}

  @spec configured() :: module()
  def configured do
    Application.get_env(
      :sdd_orchestrator,
      :repository_observation_adapter,
      __MODULE__.Unavailable
    )
  end
end

defmodule SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter.Unavailable do
  @moduledoc false
  @behaviour SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

  @impl true
  def observe(_request), do: {:error, :worker_unavailable}
end
