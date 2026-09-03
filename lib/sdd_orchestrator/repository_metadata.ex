defmodule SddOrchestrator.RepositoryMetadata do
  @moduledoc """
  The control plane's one way to ask a Mac's worker to read a repository's identity, root, and commit.

  A later feature, repository assessment, needs to know what repository sits
  at a chosen root, what its normalized root and current commit are, and
  whether the worker still sees the repository it was told to expect. That
  read happens on the Mac, so the answer has to come from the worker there.

  Unlike `SddOrchestrator.RepositorySelection`, which returns at once and
  delivers its outcome as a later mailbox message, `inspect/2` blocks the
  calling process until exactly one outcome is known, and returns it
  directly:

    * `{:ok, result}` — the worker read the repository.
    * `{:error, :cancelled}` — the read was cancelled.
    * `{:error, :repository_mismatch}` — the worker checked the folder and it
      was not the repository this request named.
    * `{:error, :invalid_worker_response}` — the worker refused to answer for
      any other reason, or sent something this boundary cannot use.
    * `{:error, :worker_unavailable}` — there was no worker to ask, the
      worker's attachment was lost while the request was open, or nobody
      answered before the wait window closed. These three causes are still
      folded together here on purpose: nothing yet distinguishes a worker
      that was lost mid-request from one that was simply never there. A
      timeout is logged internally as its own case, at the server that owns
      the wait window, so a later change can split it out without
      redesigning this one.
    * `{:error, :invalid_request}` — the request map was missing a required
      field, or the options were invalid.

  No message is ever sent to the caller's mailbox; the caller only ever sees
  `inspect/2`'s own return value. There is no `cancel/1`. The calling process
  is expected to be a supervised task a LiveView starts on its behalf, so
  killing that task is the cancellation path, and this context notices
  through the same monitor it already keeps on every caller.

  `answer/2` is the entry point a worker's attachment calls with its result.
  It refuses an answer for a request it does not have open, which is the same
  state as a request that was already answered, cancelled, or expired. That is
  deliberate and it is the reason a second answer cannot reach anyone: the
  answerer learns only `:unknown_request`, never whether it lost a race or
  invented an id.

  Requests are in memory and are never persisted. A control-plane restart
  drops every open request, which is correct: every caller blocked on one is
  on this same node and is lost with it.

  ## What may cross this boundary

  Identity, a normalized root, and a commit. Nothing else. A request carries
  opaque worker and selection references and two opaque digests to check
  against; a result carries the repository's provider, its id, its normalized
  root, and the commit it is at. No filesystem path, remote URL, Git history,
  file name, or file content enters a request, a result, the request table,
  or a log line, and none is logged here.
  """

  alias SddOrchestrator.RepositoryMetadata.Server

  # A worker needs real time to resolve a request's references into a
  # repository on the Mac and check it. This is generous rather than tight,
  # because a slow worker is not a defect and a short window would fold a
  # normal answer into `:worker_unavailable`.
  @default_timeout_ms 130_000

  @typedoc "Why a request could not be opened, or its options were invalid."
  @type request_error :: :invalid_request

  @typedoc "Why a blocked call did not resolve to a result."
  @type inspect_error ::
          :worker_unavailable | :cancelled | :invalid_worker_response | :repository_mismatch

  @typedoc "Why `inspect/2` did not resolve to a result."
  @type error :: request_error() | inspect_error()

  @typedoc "Why a worker's answer was refused."
  @type answer_error :: :unknown_request | :foreign_answer | :invalid_result

  @typedoc "What the worker read about the repository."
  @type result :: %{
          repository_provider: String.t(),
          repository_id: String.t(),
          root: String.t(),
          commit: String.t()
        }

  @typedoc "What `inspect/2` needs to ask a worker to read a repository."
  @type request :: %{
          required(:project_id) => Ecto.UUID.t(),
          required(:repository_provider) => String.t(),
          required(:repository_id) => String.t(),
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:worker_ref) => Ecto.UUID.t(),
          required(:selection_ref) => String.t(),
          required(:selected_root) => String.t(),
          required(:scanner_contract_digest) => String.t(),
          required(:disclosure_digest) => String.t()
        }

  @doc """
  Asks one worker to read a repository's identity, normalized root, and
  current commit, and blocks the calling process until exactly one outcome is
  known. See the module documentation for the outcomes.

  Options:

    * `:timeout_ms` — how long this context leaves the request open before it
      resolves the blocked call to `{:error, :worker_unavailable}` (default
      #{@default_timeout_ms}).
  """
  @spec inspect(request(), keyword()) :: {:ok, result()} | {:error, error()}
  def inspect(request, opts \\ []) do
    with {:ok, timeout_ms} <- validate_timeout(opts),
         {:ok, attrs} <- validate(request) do
      Server.inspect(attrs, timeout_ms)
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

  defp validate(request) when is_map(request) do
    with {:ok, project_id} <- require_binary(request, :project_id),
         {:ok, repository_provider} <- require_binary(request, :repository_provider),
         {:ok, repository_id} <- require_binary(request, :repository_id),
         {:ok, device_workspace_id} <- require_binary(request, :device_workspace_id),
         {:ok, worker_ref} <- require_binary(request, :worker_ref),
         {:ok, selection_ref} <- require_binary(request, :selection_ref),
         {:ok, selected_root} <- require_binary(request, :selected_root),
         {:ok, scanner_contract_digest} <- require_binary(request, :scanner_contract_digest),
         {:ok, disclosure_digest} <- require_binary(request, :disclosure_digest) do
      {:ok,
       %{
         project_id: project_id,
         repository_provider: repository_provider,
         repository_id: repository_id,
         device_workspace_id: device_workspace_id,
         worker_ref: worker_ref,
         selection_ref: selection_ref,
         selected_root: selected_root,
         scanner_contract_digest: scanner_contract_digest,
         disclosure_digest: disclosure_digest
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

  defp validate_timeout(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> {:ok, timeout_ms}
      _other -> {:error, :invalid_request}
    end
  end
end
