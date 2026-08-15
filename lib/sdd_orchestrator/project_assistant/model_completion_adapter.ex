defmodule SddOrchestrator.ProjectAssistant.ModelCompletionAdapter do
  @moduledoc """
  The read-only boundary between one turn's bounded current context and one
  candidate answer with claimed source references (AC-10, AC-11, AC-12).

  No live model tool-calling or completion loop exists anywhere in this
  codebase yet: `SddOrchestrator.AIRuntime.CodexAppServer` exposes only
  `account/...` and `model/list` RPC methods, nothing that sends a prompt or
  runs a completion. This mirrors Task 4/5's own
  `SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter` pattern
  exactly for the same reason: a `@behaviour` plus a deterministic
  `.Unavailable` fallback now, with the actual live provider wiring deferred
  to a later task and this slice's release-level live-smoke proof (see
  tasks.md's Verification Gate: "A live configured personal AI connection
  answers one stored-project question...").

  Task 7's real, provable value is everything *downstream* of this
  boundary: resolving each claimed reference into an authorization-checked
  `SddOrchestrator.ProjectAssistant.ProjectAssistantCitation` against Task
  3's current context or Task 4's current repository observation, rejecting
  anything inaccessible, fabricated, stale, or unstable, and attaching
  uncertainty markers
  (`SddOrchestrator.ProjectAssistant.TurnOrchestrator`). That pipeline is
  fully provable with fixture-driven candidate answers — some claims valid,
  some fabricated, some pointing at stale or superseded state — without any
  live model call, exactly like Task 6 proved its policy layer with
  fixture-driven hostile content and Tasks 4/5 proved their adapter with a
  deterministic fake (`SddOrchestrator.ProjectAssistant.FakeRepositoryObservationAdapter`).

  A request carries only the already-minimized, already-authorized current
  context (`SddOrchestrator.ProjectAssistant.ProjectContextAssembler`'s
  `content` and `context_version`) and the participant's question — never a
  credential, a repository path outside what the context or a later
  repository-observation tool call reveals, or unrestricted project data.
  Repository source is never preloaded here (design.md: "Repository source
  is omitted unless the runtime explicitly requests an approved source
  tool"): a `candidate_answer`'s repository claims only *name* a path and
  line range for `TurnOrchestrator` to independently observe and resolve
  through Task 4/5's own authorization-checked adapters — this module's
  output is never trusted as already-verified.
  """

  @type citation_claim ::
          %{type: :specification, specification_id: Ecto.UUID.t(), revision_id: Ecto.UUID.t()}
          | %{type: :board, feature_id: Ecto.UUID.t()}
          | %{type: :run, run_id: Ecto.UUID.t()}
          | %{type: :evidence, evidence_id: Ecto.UUID.t()}
          | %{
              type: :repository,
              path: String.t(),
              start_line: pos_integer(),
              end_line: pos_integer()
            }

  @type claim :: %{
          required(:text) => String.t(),
          required(:material) => boolean(),
          optional(:citation) => citation_claim() | nil
        }

  @type marker_hint :: %{type: atom(), detail: String.t()}

  @type candidate_answer :: %{
          required(:claims) => [claim()],
          optional(:markers) => [marker_hint()]
        }

  @type request :: %{
          required(:question_text) => String.t(),
          required(:context_content) => map(),
          required(:context_version) => String.t()
        }

  @doc """
  Produces one candidate answer for the given bounded request, or a
  normalized failure reason (never a raw provider error or exception).
  """
  @callback complete(request()) :: {:ok, candidate_answer()} | {:error, atom()}

  @doc "The configured adapter, defaulting to the deterministic unavailable fallback."
  @spec configured() :: module()
  def configured do
    Application.get_env(:sdd_orchestrator, :model_completion_adapter, __MODULE__.Unavailable)
  end
end

defmodule SddOrchestrator.ProjectAssistant.ModelCompletionAdapter.Unavailable do
  @moduledoc """
  The default `ModelCompletionAdapter`: no live personal-AI completion loop
  is wired yet, so every turn fails closed with a normalized reason rather
  than fabricating an answer (AC-04's "no answer is fabricated" principle
  applied to the completion step itself).
  """
  @behaviour SddOrchestrator.ProjectAssistant.ModelCompletionAdapter

  @impl true
  def complete(_request), do: {:error, :model_unavailable}
end
