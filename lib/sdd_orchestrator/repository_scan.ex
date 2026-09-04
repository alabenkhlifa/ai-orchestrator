defmodule SddOrchestrator.RepositoryScan do
  @moduledoc """
  The control plane's one way to ask a Mac's worker to scan a repository.

  A repository assessment is saved as a pending row naming an exact commit,
  and the scan that turns it into a completed one happens on the Mac. This is
  how the command gets there and how the one answer comes back.

  `run/2` blocks the calling process until exactly one outcome is known, and
  returns it directly:

    * `{:ok, evidence}` — the worker scanned the repository. The evidence is
      the scanner's own `findings`, `structure`, and `stats`, plus the six
      `proposal` fields it derived. It is not a result yet:
      `SddOrchestrator.RepositoryAssessments` builds one by putting its own
      command's fields beside this evidence.
    * `{:error, :cancelled}` — the scan was cancelled.
    * `{:error, reason}` where `reason` is one of
      `SddOrchestrator.RepositoryScan.ScanAnswer.refusal_reasons/0` — the
      worker refused, and said why. `:selection_expired` means the worker is
      no longer holding the folder the binding verified; the other nine are
      the bounded scanner's own terminal errors.
    * `{:error, :invalid_worker_response}` — the worker sent something this
      boundary cannot use.
    * `{:error, :worker_unavailable}` — there was no worker to ask, the
      worker's attachment was lost while the request was open, or nobody
      answered before the wait window closed. These three causes are folded
      together the same way `SddOrchestrator.RepositoryMetadata` folds them,
      and for the same reason: nothing yet distinguishes a worker lost
      mid-request from one that was never there.
    * `{:error, :invalid_request}` — the request map was missing a required
      field, its command was not a valid command, or the options were
      invalid.

  No message is ever sent to the caller's mailbox. There is no `cancel/1`: the
  calling process is expected to be a supervised task a LiveView starts on its
  behalf, so killing that task is the cancellation path, and this context
  notices through the same monitor it keeps on every caller.

  `answer/2` is the entry point a worker's attachment calls with its result.
  It refuses an answer for a request it does not have open, which is the same
  state as a request that was already answered, cancelled, or expired.

  Requests are in memory and are never persisted. A control-plane restart
  drops every open request, which is correct: every caller blocked on one is
  on this same node and is lost with it.

  ## What may cross this boundary

  Going out: the assessment command the control plane issued, which is closed
  to identity, root anchor, commit, digests, and limits, and the opaque
  selection reference the folder is held under. Coming back: the minimized
  evidence the bounded scanner already produced, which is repository-relative
  anchors, sizes, line counts, and content digests. No absolute path, remote
  URL, Git history, or file content enters a request, an answer, the request
  table, or a log line.
  """

  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryScan.ScanAnswer
  alias SddOrchestrator.RepositoryScan.Server

  # The bounded scanner enforces its own time limit and refuses on it, so this
  # window only has to be comfortably longer than a scan that behaves. A scan
  # opens no panel, so it needs nothing like the metadata read's allowance for
  # a person answering one.
  @default_timeout_ms 60_000

  @typedoc "Why a request could not be opened, or its options were invalid."
  @type request_error :: :invalid_request

  @typedoc "Why a blocked call did not resolve to evidence."
  @type run_error ::
          :worker_unavailable
          | :cancelled
          | :invalid_worker_response
          | ScanAnswer.refusal_reason()

  @typedoc "Why `run/2` did not resolve to evidence."
  @type error :: request_error() | run_error()

  @typedoc "Why a worker's answer was refused."
  @type answer_error :: :unknown_request | :foreign_answer | :invalid_result

  @typedoc "What the worker found, before the control plane makes a result of it."
  @type evidence :: %{
          findings: [map()],
          structure: [map()],
          stats: map(),
          proposal: map()
        }

  @typedoc "What `run/2` needs to ask a worker to scan a repository."
  @type request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:worker_ref) => Ecto.UUID.t(),
          required(:selection_ref) => String.t(),
          required(:command) => RepositoryAssessmentCommand.t()
        }

  @doc """
  Asks one worker to scan a repository at the command's exact commit, and
  blocks the calling process until exactly one outcome is known. See the
  module documentation for the outcomes.

  Options:

    * `:timeout_ms` — how long this context leaves the request open before it
      resolves the blocked call to `{:error, :worker_unavailable}` (default
      #{@default_timeout_ms}).
  """
  @spec run(request(), keyword()) :: {:ok, evidence()} | {:error, error()}
  def run(request, opts \\ []) do
    with {:ok, timeout_ms} <- validate_timeout(opts),
         {:ok, attrs} <- validate(request) do
      Server.run(attrs, timeout_ms)
    end
  end

  @doc """
  Hands one worker's answer to the request it is for.

  `answering` is the identity of the attachment that sent the answer,
  `%{device_workspace_id: id, worker_id: id}`. The answer is refused, with
  nothing changed and no blocked call resolved, when the request is not open
  (`:unknown_request`), when it was sent by an attachment other than the one
  the request was pushed to (`:foreign_answer`), or when the attributes are
  not a valid answer (`:invalid_result`).
  """
  @spec answer(map(), map()) :: :ok | {:error, answer_error()}
  def answer(answering, attrs), do: Server.answer(answering, attrs)

  @doc "The wait window a request is given when the caller names none."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  defp validate(request) when is_map(request) do
    with {:ok, project_id} <- require_binary(request, :project_id),
         {:ok, device_workspace_id} <- require_binary(request, :device_workspace_id),
         {:ok, worker_ref} <- require_binary(request, :worker_ref),
         {:ok, selection_ref} <- require_binary(request, :selection_ref),
         {:ok, command} <- require_command(request) do
      {:ok,
       %{
         project_id: project_id,
         device_workspace_id: device_workspace_id,
         worker_ref: worker_ref,
         selection_ref: selection_ref,
         command: command
       }}
    end
  end

  defp validate(_request), do: {:error, :invalid_request}

  defp require_binary(request, key) do
    case Map.get(request, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_request}
    end
  end

  defp require_command(request) do
    case Map.get(request, :command) do
      %RepositoryAssessmentCommand{} = command ->
        if RepositoryAssessmentCommand.valid?(command),
          do: {:ok, command},
          else: {:error, :invalid_request}

      _other ->
        {:error, :invalid_request}
    end
  end

  defp validate_timeout(opts) when is_list(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> {:ok, timeout_ms}
      _other -> {:error, :invalid_request}
    end
  end

  defp validate_timeout(_opts), do: {:error, :invalid_request}
end
