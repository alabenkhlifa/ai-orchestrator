defmodule SddOrchestrator.ProjectAssistant.RepositoryObserver do
  @moduledoc """
  Task 4's single bounded "observe current state" operation (AC-08, AC-09,
  AC-16): revalidates the acting participant's current repository source
  authority, confirms a reachable worker exists for this project right now,
  and asks the configured `RepositoryObservationAdapter` to observe the
  current working tree, including uncommitted changes.

  Three checks run in order, every one of them fresh on every call — nothing
  here caches an authorization or availability result across calls, matching
  every other project-assistant surface:

    1. `RepositorySourceAuthorization.authorize/3` — denies a stale, absent,
       removed, or cross-project identity without disclosure
       (`:unauthorized`), and denies a currently valid participant who lacks
       repository source access as a distinguishable, disclosed outcome
       (`:source_denied`, AC-16).
    2. Worker reachability — reuses
       `SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability`, the
       same signal the disclosed processing summary already shows, so
       "may a worker be used" and "is a worker available for this
       observation" never drift apart. An unreachable worker denies with
       `:worker_unavailable` before the adapter is ever called.
    3. The configured `RepositoryObservationAdapter.observe/1` — bounded,
       opaque, and the only step that ever runs when both prior checks pass.

  Only bounded tree/search/line-read progressive discovery and the
  worker-local `RepositorySourceIndex` are out of scope here; those belong to
  a later task's own adapter and orchestrator.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.ProjectAssistant.RepositoryObservation
  alias SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter
  alias SddOrchestrator.ProjectAssistant.RepositorySourceAuthorization
  alias SddOrchestrator.ProjectAssistant.RepositoryWorkerAvailability

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: RepositorySourceAuthorization.actor()

  @doc """
  Observes one project's current working tree for the acting participant.

  `opts`:

    * `:adapter` — the `RepositoryObservationAdapter` implementation to call;
      defaults to `RepositoryObservationAdapter.configured/0`.
    * `:exclusions` — allowlisted path/pattern exclusions to pass through;
      defaults to `[]`.
    * `:worker_available` — a `(authority, project_id -> boolean())` override
      for worker reachability; defaults to
      `RepositoryWorkerAvailability.available?/2`. Exists for deterministic
      tests of the content this module returns once a worker is reachable,
      without standing up live worker-pairing infrastructure; production
      callers never pass it.
  """
  @spec observe(authority(), String.t(), actor(), keyword()) ::
          {:ok, RepositoryObservation.t()}
          | {:error, :unauthorized | :source_denied | :worker_unavailable | atom()}
  def observe(authority, project_id, actor, opts \\ []) do
    adapter = Keyword.get(opts, :adapter, RepositoryObservationAdapter.configured())
    exclusions = Keyword.get(opts, :exclusions, [])

    worker_available =
      Keyword.get(opts, :worker_available, &RepositoryWorkerAvailability.available?/2)

    with {:ok, target} <- RepositorySourceAuthorization.authorize(authority, project_id, actor),
         true <- worker_available.(authority, project_id),
         {:ok, raw} <- adapter.observe(request(target, exclusions)) do
      {:ok, RepositoryObservation.build(target, raw)}
    else
      false -> {:error, :worker_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(target, exclusions) do
    %{
      project_id: target.project_id,
      repository_provider: target.repository_provider,
      repository_ref: target.repository_ref,
      exclusions: exclusions
    }
  end
end
