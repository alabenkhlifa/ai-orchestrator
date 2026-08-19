defmodule SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter do
  @moduledoc """
  Read-only worker boundary for observing one project's current working tree
  (AC-08, AC-09) and for bounded progressive source discovery inside it
  (AC-13, AC-18).

  Requests carry only opaque project and repository target references, never
  a filesystem path or credential. A real implementation resolves the bound
  worker for `project_id` inside the worker boundary — the same way
  `SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability` already
  resolves worker reachability without the caller supplying a worker
  identifier.

  `observe/1` (Task 4) answers only the single bounded "observe current
  state" question: current branch, current commit when one exists, dirty
  state, and a digest of relevant working-tree state captured at scan start
  and again at scan completion, so a caller can detect concurrent change
  without a second round trip.

  `tree/1`, `search/1`, and `lines/1` (Task 5) are the bounded progressive
  discovery operations design.md's "Repository-observation interface" and
  "Read-tool broker interface" describe: a directory listing, a text search,
  and an exact line-range read, each already carrying its own byte and
  result-count limit and configured path/file exclusions at this adapter
  boundary — independent of Task 6's later trusted-tool-broker budgets, which
  wrap these same bounded operations in a runtime policy layer rather than
  redefining their limits. None of these callbacks return unbounded content:
  a real implementation truncates to the requested limits and reports
  `truncated: true` rather than silently returning everything, which is what
  keeps a large repository answerable without a full source upload.
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

  @type tree_request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t() | nil,
          required(:repository_ref) => String.t() | nil,
          required(:path) => String.t(),
          required(:exclusions) => [String.t()],
          required(:max_entries) => pos_integer(),
          required(:max_bytes) => pos_integer()
        }

  @type tree_entry :: %{
          required(:path) => String.t(),
          required(:type) => :file | :dir
        }

  @type tree_result :: %{
          required(:entries) => [tree_entry()],
          optional(:truncated) => boolean()
        }

  @type search_request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t() | nil,
          required(:repository_ref) => String.t() | nil,
          required(:query) => String.t(),
          required(:exclusions) => [String.t()],
          required(:max_results) => pos_integer(),
          required(:max_bytes) => pos_integer()
        }

  @type search_match :: %{
          required(:path) => String.t(),
          required(:line) => pos_integer(),
          required(:excerpt) => String.t()
        }

  @type search_result :: %{
          required(:matches) => [search_match()],
          optional(:truncated) => boolean()
        }

  @type lines_request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t() | nil,
          required(:repository_ref) => String.t() | nil,
          required(:path) => String.t(),
          required(:start_line) => pos_integer(),
          required(:end_line) => pos_integer(),
          required(:max_bytes) => pos_integer()
        }

  @type lines_result :: %{
          required(:path) => String.t(),
          required(:start_line) => pos_integer(),
          required(:end_line) => pos_integer(),
          required(:content) => String.t(),
          optional(:truncated) => boolean()
        }

  @callback observe(request()) :: {:ok, result()} | {:error, atom()}
  @callback tree(tree_request()) :: {:ok, tree_result()} | {:error, atom()}
  @callback search(search_request()) :: {:ok, search_result()} | {:error, atom()}
  @callback lines(lines_request()) :: {:ok, lines_result()} | {:error, atom()}

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

  @impl true
  def tree(_request), do: {:error, :worker_unavailable}

  @impl true
  def search(_request), do: {:error, :worker_unavailable}

  @impl true
  def lines(_request), do: {:error, :worker_unavailable}
end
