defmodule SddOrchestrator.RepositorySelection do
  @moduledoc """
  The control plane's one way to ask a Mac's worker to name a repository.

  Three dashboard surfaces need the same thing: the person points at a folder
  on their own machine and the product learns which repository it is. The
  folder is on the Mac, so the answer has to come from the worker there, and a
  person takes tens of seconds to answer a native panel. A LiveView cannot sit
  and wait for that, so this is a request now and an answer later.

  `request/3` pushes the request to the worker and returns at once with a
  request id. Exactly one outcome arrives in the requesting process's mailbox
  later as `{:repository_selection, request_id, outcome}`, where the outcome is
  one of:

    * `{:selected, %SelectionResult{}}` — the person chose a folder and the
      worker checked it.
    * `:cancelled` — the person dismissed the panel, or the requester called
      `cancel/1`.
    * `{:refused, reason}` — the folder was not a usable repository
      (`:not_a_git_repository`, `:empty_repository`, or `:inaccessible`).
    * `:timeout` — nobody answered inside the wait window.
    * `:worker_lost` — the worker's attachment went away while the panel was
      open.

  Every path out of a request ends in one of those, once. The requester's own
  exit is the exception: there is nobody left to tell, so the worker is asked
  to close its panel and the request is dropped.

  `answer/2` is the entry point the attachment channel calls with a worker's
  result. It refuses an answer for a request it does not have open, which is
  the same state as a request that was already answered, cancelled, or expired.
  That is deliberate and it is the reason a second answer cannot reach anyone:
  the answerer learns only `:unknown_request`, and never whether it lost a race
  or invented an id.

  Requests are in memory and are never persisted. A control-plane restart drops
  every open request, which is correct, because the panel on the Mac is gone
  too and the person just asks again.

  ## What may cross this boundary

  Identities and a folder name. Nothing else. A request carries portable
  repository identities to compare against; a result carries which of them
  matched, the folder's own name, and a newly generated identity when one was
  asked for. No filesystem path, remote URL, Git history, file name, or file
  content enters a request, a result, the request table, or a log line, and
  none is logged here.
  """

  alias SddOrchestrator.RepositorySelection.Server
  alias SddOrchestrator.RepositorySelection.Transport

  # A person needs tens of seconds to find a folder in a native panel. A short
  # window would report `:timeout` for someone who is simply still looking.
  @default_timeout_ms 120_000

  @typedoc "Why a request could not be opened."
  @type error :: Transport.reason() | :invalid_request

  @typedoc "Why a worker's answer was refused."
  @type answer_error :: :unknown_request | :foreign_answer | :invalid_result

  @typedoc "The workspace that owns the worker, and the hosted project when one is connecting."
  @type scope :: %{
          required(:device_workspace_id) => Ecto.UUID.t(),
          optional(:project_id) => Ecto.UUID.t() | nil,
          optional(any()) => any()
        }

  @doc """
  Asks one worker to open its folder picker, and returns without waiting.

  `scope` is `%{device_workspace_id: id}` for an accountless selection, or
  `%{device_workspace_id: id, project_id: id}` when a hosted project is
  connecting its local repository. A scope without a device workspace is
  refused: the workspace is what binds the request to the worker allowed to
  answer it.

  Options:

    * `:candidates` — the identities the worker should compare the chosen
      folder against, each as `%{ref: term(), identity: binary()}`. The `ref`
      is the requester's own handle and comes back in the result's `matches`.
      Defaults to `[]`.
    * `:generate` — whether the worker should generate a fresh portable
      identity for the chosen folder. Defaults to `false`.
    * `:timeout_ms` — how long to leave the request open (default
      #{@default_timeout_ms}).

  The outcome arrives later as a message. See the module documentation.
  """
  @spec request(scope(), String.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def request(scope, worker_id, opts \\ []) do
    with {:ok, timeout_ms} <- validate_timeout(opts),
         {:ok, attrs} <- validate(scope, worker_id, opts) do
      Server.open(attrs, timeout_ms)
    end
  end

  @doc """
  Closes the calling process's own open request.

  The caller must be the process that made the request. The worker is told so
  its panel closes, and the caller still receives `:cancelled`, so every
  request ends in exactly one message however it ends.
  """
  @spec cancel(String.t()) :: :ok | {:error, :not_found | :not_owner}
  def cancel(request_id) when is_binary(request_id), do: Server.cancel(request_id)

  @doc """
  Hands one worker's answer to the requester that asked for it.

  `answering` is the identity of the attachment that sent the answer,
  `%{device_workspace_id: id, worker_id: id}`. The answer is refused, with
  nothing changed and nothing sent, when the request is not open
  (`:unknown_request`), when it was sent by an attachment other than the one
  the request was pushed to (`:foreign_answer`), or when the attributes are not
  a valid result (`:invalid_result`).
  """
  @spec answer(map(), map()) :: :ok | {:error, answer_error()}
  def answer(answering, attrs), do: Server.answer(answering, attrs)

  @doc "The wait window used when a caller does not name one."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  defp validate(scope, worker_id, opts) do
    with {:ok, device_workspace_id} <- validate_workspace(scope),
         {:ok, project_id} <- validate_project(scope),
         {:ok, worker_id} <- validate_worker(worker_id),
         {:ok, candidates} <- validate_candidates(Keyword.get(opts, :candidates, [])),
         {:ok, generate?} <- validate_generate(Keyword.get(opts, :generate, false)) do
      {:ok,
       %{
         device_workspace_id: device_workspace_id,
         project_id: project_id,
         worker_id: worker_id,
         candidates: candidates,
         generate?: generate?
       }}
    end
  end

  defp validate_workspace(scope) when is_map(scope) do
    case Map.get(scope, :device_workspace_id) do
      id when is_binary(id) -> {:ok, id}
      _other -> {:error, :invalid_request}
    end
  end

  defp validate_workspace(_scope), do: {:error, :invalid_request}

  defp validate_project(scope) do
    case Map.get(scope, :project_id) do
      nil -> {:ok, nil}
      id when is_binary(id) -> {:ok, id}
      _other -> {:error, :invalid_request}
    end
  end

  defp validate_worker(worker_id) when is_binary(worker_id), do: {:ok, worker_id}
  defp validate_worker(_worker_id), do: {:error, :invalid_request}

  # A candidate holds a reference and an identity, and nothing else. Refusing
  # every other shape is what stops a caller from putting a path, a name, or a
  # remote into the payload that leaves for the worker.
  defp validate_candidates(candidates) when is_list(candidates) do
    if Enum.all?(candidates, &candidate?/1) do
      {:ok, candidates}
    else
      {:error, :invalid_request}
    end
  end

  defp validate_candidates(_candidates), do: {:error, :invalid_request}

  defp candidate?(%{ref: _ref, identity: identity} = candidate) when is_binary(identity) do
    Enum.sort(Map.keys(candidate)) == [:identity, :ref]
  end

  defp candidate?(_candidate), do: false

  defp validate_generate(generate?) when is_boolean(generate?), do: {:ok, generate?}
  defp validate_generate(_generate), do: {:error, :invalid_request}

  defp validate_timeout(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> {:ok, timeout_ms}
      _other -> {:error, :invalid_request}
    end
  end
end
