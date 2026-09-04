defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter do
  @moduledoc """
  The domain's one way to have a repository scanned on a Mac.

  A request carries the assessment command the control plane issued and the
  opaque selection reference the binding was verified under, never a
  filesystem path. An answer carries only what the bounded scanner already
  minimized: findings, structure, stats, the six proposal fields, and the
  provenance of the worker's own exact-commit cache.

  The indirection exists for the same reason
  `SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter` does. The
  default refuses, tests install a double, and nothing reaches a worker by
  accident.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand

  @type request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:worker_ref) => Ecto.UUID.t(),
          required(:selection_ref) => String.t(),
          required(:command) => RepositoryAssessmentCommand.t()
        }

  @type evidence :: %{
          required(:findings) => [map()],
          required(:structure) => [map()],
          required(:stats) => map(),
          required(:proposal) => map(),
          required(:provenance) => map()
        }

  @callback scan(request()) :: {:ok, evidence()} | {:error, atom()}

  @spec configured() :: module()
  def configured do
    Application.get_env(
      :sdd_orchestrator,
      :repository_scan_adapter,
      __MODULE__.Unavailable
    )
  end
end

defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter.Unavailable do
  @moduledoc false
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter

  @impl true
  def scan(_request), do: {:error, :worker_unavailable}
end

defmodule SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter.Worker do
  @moduledoc """
  The real `RepositoryScanAdapter`: a scan asked of a Mac's worker, through
  `SddOrchestrator.RepositoryScan`.

  There is nothing to translate. A `RepositoryScanAdapter.request()` map is
  field-for-field a `RepositoryScan.request()` map, so it is passed straight
  through, and every refusal keeps the name the worker gave it. That is
  deliberate and it is the difference from
  `RepositoryMetadataAdapter.Worker`, which narrows its error union: the
  caller here has to tell an expired folder hold from a repository that moved
  off its commit, because the two mean different things to the person waiting
  and produce different sentences on screen.
  """
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryScanAdapter

  alias SddOrchestrator.RepositoryScan

  @impl true
  def scan(request), do: RepositoryScan.run(request)
end
