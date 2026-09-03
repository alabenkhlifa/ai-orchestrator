defmodule SddOrchestrator.Worker.RepositorySelection do
  @moduledoc """
  The worker release's side of one folder-picker request: hold it, show it to
  the Mac app, and answer it with identities and a folder name only.

  The control plane cannot ask a person to point at a folder. It pushes a
  `repository_selection` request over the Mac-scoped attachment, and everything
  that needs the chosen path then happens here, on the Mac that holds the
  repository. The answer carries which of the requested identities matched, the
  folder's own name, and a freshly generated identity when one was asked for.
  The path itself never leaves this machine, and the control plane never learns
  where the repository lives.

  ## Why two files

  The release holds the request in memory and the native app draws the panel,
  and those are two processes on one machine with no channel between them.
  `bin/worker rpc` is not one: specs/43-distribution-free-worker-control removed
  every rpc call the app made, because a managed Mac's firewall blocks incoming
  `epmd`. `eval` is not one either, because a fresh VM has none of this VM's
  memory and would answer that nothing is pending while a request is open. That
  is the same reason the connection status needed a file, so the request crosses
  the same way, through owner-only JSON beside `connection_status.json` under
  `SddOrchestrator.Worker.Configuration.home/1`:

    * `pending_selection.json`, written here while one request is open. It holds
      the request id and its expiry and nothing else. The candidate identities
      stay in this process's memory, because the app has no use for them and
      must never hold them. It is removed when the request ends by any route.
    * `selection_answer.json`, written by the app, read here. It holds the
      request id and either the chosen path or a cancellation.

  ## The path rule

  The answer file is the only place a path is ever written, and it exists for at
  most one poll interval. This module reads it, deletes it at once, and only
  then runs the Git check, so a crash part-way through a computation cannot
  leave a path behind. A stale pending file and a stale answer found at start
  are both deleted, the answer without being read at all: neither can belong to
  anything but a request this VM no longer has, a pending file left by a
  release that died would show a panel for a request the control plane has
  already timed out, and reading the answer would put a path in memory for no
  reason.

  Beyond that, the path lives only in the local variables of the function
  answering with it. It is never held in this process's state, never written to
  the pending file, never placed in the result payload, and never logged. No log
  line this module emits carries a path, at any level.

  ## Shape

  One request at a time, which is all the control plane opens per requester. A
  new request replaces the one being held, so a worker-side request can never
  outlive the control-plane request it belongs to. Polling for the answer runs
  twice a second, shorter than the app's two-second poll, so the release is
  never the slow half of the exchange.

  A failed file write is reported to the log and swallowed, exactly as
  `SddOrchestrator.Worker.ConnectionStatus` treats its own publication. A
  request that cannot be published is a request the person will not see, and the
  control plane already times that out; crashing the worker over it would be
  worse.
  """

  use GenServer

  require Logger

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryValidation
  alias SddOrchestrator.Worker.Configuration

  @pending_file "pending_selection.json"
  @answer_file "selection_answer.json"

  # How often the answer file is looked for while a request is open. The app
  # polls the pending file every two seconds, so this is deliberately shorter:
  # the person's own wait is the panel, never the release noticing their answer.
  # Production callers never override it; tests do, through `:poll_interval`,
  # the same seam `:home_override` uses.
  @poll_interval 500

  @typedoc "Sends one finished result payload back to the control plane."
  @type reply :: (map() -> any())

  @typedoc "Sends the raw chosen path, or `:cancelled`, to an in-release caller."
  @type path_reply :: (String.t() | :cancelled -> any())

  @doc """
  Starts the single request holder for this worker release.

  `opts` may carry `:home_override`, the storage root to read and write the two
  files under (see `SddOrchestrator.Worker.Configuration.home/1`), and
  `:poll_interval`, how often the answer file is looked for. Production callers
  pass neither and take the configured root and the interval above.

  Both files left on disk by an earlier release are deleted here, the answer
  unread. Nothing is open yet, so neither can belong to a live request.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The full path to the pending-request file under `Configuration.home/1`.

  Takes the same optional home override every other function in this area
  takes, so the release, the app, and a test can all name the storage root they
  mean. Path resolution itself belongs to `Configuration.home/1`.
  """
  @spec pending_path(String.t() | nil) :: String.t()
  def pending_path(home_override \\ nil),
    do: Path.join(Configuration.home(home_override), @pending_file)

  @doc """
  The full path to the answer file the Mac app writes, under
  `Configuration.home/1`.

  This is the only path in the product a chosen folder is ever written to, and
  it is deleted as soon as it is read.
  """
  @spec answer_path(String.t() | nil) :: String.t()
  def answer_path(home_override \\ nil),
    do: Path.join(Configuration.home(home_override), @answer_file)

  @doc """
  The id of the request being held, or `nil` when nothing is open.

  The app never calls this: the pending file is the crossing. It exists so the
  release itself, and this task's tests, can read what is open without going
  through the filesystem.
  """
  @spec pending() :: String.t() | nil
  def pending, do: GenServer.call(__MODULE__, :pending)

  @doc """
  Takes one selection request that arrived from the control plane.

  `payload` is the decoded inbound message (`request_id`, `candidates`,
  `generate`, `expires_at`) and `reply` is called once with the finished result
  payload. `home_override` is the storage root the calling connection was
  configured with; `nil` means the one this process was started with.

  A request already being held is replaced, and a leftover answer is discarded
  before the new pending file is written, so nothing left by the previous
  request can be mistaken for an answer to this one.

  Cast rather than called, because the caller is the gateway connection's own
  callback and it must never wait on a Git check or a file write to keep serving
  the socket. A request that arrives while nothing is started is dropped, which
  the control plane already reports as a request the worker never answered.
  """
  @spec open(map(), reply(), String.t() | nil) :: :ok
  def open(payload, reply, home_override \\ nil)
      when is_map(payload) and is_function(reply, 1) do
    GenServer.cast(__MODULE__, {:open, payload, reply, home_override, &result/2})
  end

  @doc """
  Takes one selection request the same way `open/3` does, but hands the
  caller the raw path directly instead of building a selection answer.

  This is for a caller inside this same release, one that needs the chosen
  folder itself so it can inspect the repository on its own terms, not the
  wire payload `open/3` builds for its control-plane caller. `reply` is
  called once, with the chosen absolute path, or with `:cancelled` when the
  person dismissed the panel or the request was cancelled through `close/1`.
  Nothing here runs the Git check, matches candidate identities, or
  generates one: that is `open/3`'s job for its own caller, not this one's.

  The request is held the same way `open/3` holds one, through the same
  pending file, the same answer poll, and the same replace-on-open and
  expiry handling, so the two entry points share one held request rather
  than each keeping their own.

  The path still never touches this module's own logging, and it crosses no
  contract beyond the pending/answer files `open/3` already crosses. It is
  handed to `reply` exactly as `open/3` already hands a path to its own
  `result/2` internally, and the caller owns what happens to it from there.
  """
  @spec request_path(map(), path_reply(), String.t() | nil) :: :ok
  def request_path(payload, reply, home_override \\ nil)
      when is_map(payload) and is_function(reply, 1) do
    GenServer.cast(
      __MODULE__,
      {:open, payload, reply, home_override, fn _request, choice -> choice end}
    )
  end

  @doc """
  Drops the held request because the control plane cancelled it.

  The pending file is removed so the app closes its panel, and no result is
  sent: the control plane has already stopped waiting for one. An id that is not
  the one being held changes nothing.
  """
  @spec close(String.t()) :: :ok
  def close(request_id) when is_binary(request_id) do
    GenServer.cast(__MODULE__, {:close, request_id})
  end

  @doc """
  Answers the held request with a chosen folder or a cancellation.

  This is the seam the answer-file poll and this task's tests both go through.
  It runs the Git check, matches the folder against every candidate identity the
  request carried, generates a fresh identity when one was asked for, takes the
  folder name, replies, and removes the pending file.

  Returns `{:error, :unknown_request}` when `request_id` is not the request being
  held, which is how a late or foreign answer changes nothing.
  """
  @spec answer(String.t(), Path.t() | :cancelled) :: :ok | {:error, :unknown_request}
  def answer(request_id, choice) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:answer, request_id, choice})
  end

  @impl GenServer
  def init(opts) do
    home_override = Keyword.get(opts, :home_override)

    # A pending file exists only while a request is open, so one found before
    # anything is open belongs to a release that died holding a request the
    # control plane has long since timed out. Left in place it would show the
    # person a panel for a question nobody is waiting on an answer to.
    discard_answer(home_override)
    remove_pending(home_override)

    {:ok,
     %{
       home_override: home_override,
       poll_interval: Keyword.get(opts, :poll_interval, @poll_interval),
       request: nil
     }}
  end

  @impl GenServer
  def handle_call(:pending, _from, state) do
    {:reply, state.request && state.request.id, state}
  end

  def handle_call({:answer, request_id, choice}, _from, %{request: %{id: request_id}} = state) do
    {:reply, :ok, finish(state, choice)}
  end

  def handle_call({:answer, _request_id, _choice}, _from, state) do
    {:reply, {:error, :unknown_request}, state}
  end

  @impl GenServer
  def handle_cast({:open, payload, reply, home_override, result_builder}, state) do
    case build_request(payload, reply, home_override || state.home_override, result_builder) do
      {:ok, request} -> {:noreply, hold(state, request)}
      :error -> {:noreply, state}
    end
  end

  def handle_cast({:close, request_id}, %{request: %{id: request_id}} = state) do
    remove_pending(state.request.home)

    {:noreply, %{state | request: nil}}
  end

  def handle_cast({:close, _request_id}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:poll_answer, request_id}, %{request: %{id: request_id}} = state) do
    case take_answer(state.request.home) do
      {:ok, ^request_id, choice} ->
        {:noreply, finish(state, choice)}

      _no_answer_for_this_request ->
        {:noreply, schedule_poll(state)}
    end
  end

  # A tick left over from a request that has since been answered, cancelled, or
  # replaced. Nothing to look for and nothing to reschedule.
  def handle_info({:poll_answer, _request_id}, state), do: {:noreply, state}

  # Replaces whatever was held. The control plane opens one request per
  # requester, so a second arriving here means the first is already gone on that
  # side and must not stay visible on this one.
  defp hold(state, request) do
    if state.request, do: remove_pending(state.request.home)

    discard_answer(request.home)
    publish_pending(request)

    schedule_poll(%{state | request: request})
  end

  defp schedule_poll(state) do
    Process.send_after(self(), {:poll_answer, state.request.id}, state.poll_interval)

    state
  end

  # The request as it is held: identities, references, an expiry, and how to
  # turn a choice into what `reply` receives. Nothing here names a location,
  # and nothing here is written to the pending file except the id and the
  # expiry.
  defp build_request(payload, reply, home, result_builder) do
    case Map.get(payload, "request_id") do
      id when is_binary(id) and id != "" ->
        {:ok,
         %{
           id: id,
           expires_at: expiry(payload),
           candidates: candidates(payload),
           generate?: payload["generate"] == true,
           reply: reply,
           home: home,
           result_builder: result_builder
         }}

      _unusable ->
        Logger.warning("worker ignoring a repository selection request with no request id")

        :error
    end
  end

  defp expiry(%{"expires_at" => expires_at}) when is_binary(expires_at), do: expires_at
  defp expiry(_payload), do: nil

  defp candidates(%{"candidates" => candidates}) when is_list(candidates), do: candidates
  defp candidates(_payload), do: []

  # Answers the held request and lets it go. The pending file is removed last so
  # the app's panel closes only once the answer is on its way.
  defp finish(state, choice) do
    request = state.request

    request.reply.(request.result_builder.(request, choice))
    remove_pending(request.home)

    %{state | request: nil}
  end

  defp result(request, :cancelled), do: %{"request_id" => request.id, "outcome" => "cancelled"}

  # The one function that holds a chosen path, and it holds it only in its own
  # arguments. What leaves is a folder name, a list of the requester's own
  # references, and an identity.
  defp result(request, path) do
    with {:ok, _roots} <- RepositoryValidation.root_commit_ids(path),
         {:ok, identity} <- generated_identity(request.generate?, path) do
      selected(request, path, identity)
    else
      {:error, reason} -> %{"request_id" => request.id, "outcome" => outcome_name(reason)}
    end
  end

  defp selected(request, path, identity) do
    payload = %{
      "request_id" => request.id,
      "outcome" => "selected",
      "folder_name" => Path.basename(path),
      "matches" => matching_refs(request.candidates, path, workspace_salt(request.home))
    }

    if identity, do: Map.put(payload, "identity", identity), else: payload
  end

  defp generated_identity(false, _path), do: {:ok, nil}
  defp generated_identity(true, path), do: PortableRepositoryIdentity.generate(path)

  # A candidate whose stored identity cannot be parsed is simply not a match. A
  # single malformed value in the requester's own table must not fail the whole
  # selection, and reporting it as a match would be worse still.
  defp matching_refs(candidates, path, workspace_salt) do
    candidates
    |> Enum.filter(&matching_candidate?(&1, path, workspace_salt))
    |> Enum.map(fn %{"ref" => ref} -> ref end)
  end

  defp matching_candidate?(%{"ref" => ref, "identity" => identity}, path, workspace_salt)
       when is_binary(ref) and is_binary(identity) do
    match?({:ok, true}, compare_identity(path, identity, workspace_salt))
  end

  defp matching_candidate?(_candidate, _path, _workspace_salt), do: false

  # The same dispatch the control plane's own `Devices.matches_repository?/3`
  # makes, and it has to be the same one. The control plane decides from this
  # answer whether the chosen repository is already linked to a project, so a
  # worker that reports "no match" where the control plane would have reported a
  # match turns one repository into two projects. Projects onboarded before the
  # portable format still carry a workspace-scoped fingerprint, which `match/2`
  # refuses outright: only `match_legacy/3`, with the workspace the identity was
  # salted with, can answer for one.
  defp compare_identity(path, identity, workspace_salt) do
    case PortableRepositoryIdentity.parse(identity) do
      {:ok, _portable} ->
        PortableRepositoryIdentity.match(path, identity)

      {:error, :legacy_identifier} ->
        PortableRepositoryIdentity.match_legacy(path, identity, workspace_salt)

      # A non-canonical placeholder from before the contract. It cannot
      # authorize a match and is never treated as portable.
      {:error, :invalid_identifier} ->
        {:ok, false}
    end
  end

  # Every legacy fingerprint was salted with the device workspace that owns the
  # repository, which is this worker's own workspace: the control plane only
  # ever sends candidates belonging to the workspace it paired this worker for.
  # It is read from the configuration already on disk under the same home the
  # request came with, so no new value has to travel in the request. An
  # unpaired or unreadable configuration yields no salt, and `match_legacy/3`
  # then reports no match rather than guessing one.
  defp workspace_salt(home) do
    case Configuration.load(home) do
      {:ok, config} -> config.device_workspace_id
      {:error, _reason} -> nil
    end
  rescue
    error -> unsalted(error.__struct__)
  end

  # Only the exception's name is reported, for the same reason `discarded/1`
  # reports only that: a `File.Error` message carries the path.
  defp unsalted(reason) do
    Logger.warning("worker could not read its workspace for a legacy match (#{inspect(reason)})")

    nil
  end

  # The three refusals `RepositoryValidation` reports, named exactly as the
  # control plane's own `SelectionResult` accepts them.
  defp outcome_name(:inaccessible), do: "inaccessible"
  defp outcome_name(:not_a_git_repository), do: "not_a_git_repository"
  defp outcome_name(:empty_repository), do: "empty_repository"

  # Reads the app's answer and deletes it before anything is computed from it,
  # so the path is on disk for the shortest time the exchange allows and a crash
  # part-way through the Git check cannot leave it there. An answer naming
  # another request is deleted too: it can only be stale.
  #
  # The path is derived from the worker's own configured storage root — trusted
  # application configuration, never web or user input, exactly as in
  # `Configuration.store/2`. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp take_answer(home) do
    file = answer_path(home)

    case File.read(file) do
      {:ok, contents} ->
        File.rm(file)
        decode_answer(contents)

      {:error, _reason} ->
        :none
    end
  rescue
    error -> discarded(error.__struct__)
  end

  defp decode_answer(contents) do
    case Jason.decode(contents) do
      {:ok, %{"request_id" => id, "cancelled" => true}} when is_binary(id) ->
        {:ok, id, :cancelled}

      {:ok, %{"request_id" => id, "path" => path}} when is_binary(id) and is_binary(path) ->
        {:ok, id, path}

      _unusable ->
        :none
    end
  end

  # Deletes an answer without reading it. Used at start, where the only answer
  # that can be on disk belongs to a request this VM no longer has, and before
  # each new pending file, so a leftover can never be taken for a fresh answer.
  #
  # sobelow_skip ["Traversal.FileModule"]
  defp discard_answer(home) do
    home |> answer_path() |> File.rm()

    :ok
  rescue
    error -> discarded(error.__struct__)
  end

  # Resolving the home directory can raise, and no caller here may fail for it.
  # Only the exception's name is reported: a `File.Error` message carries the
  # path, which never belongs in a log line.
  defp discarded(reason) do
    Logger.warning("worker could not clear a repository selection answer (#{inspect(reason)})")

    :none
  end

  defp publish_pending(request) do
    directory = Configuration.home(request.home)
    contents = encode_pending(request)

    case write_atomically(directory, Path.join(directory, @pending_file), contents) do
      :ok -> :ok
      {:error, reason} -> unpublished(reason)
    end
  rescue
    error -> unpublished(error.__struct__)
  end

  # The request id and its expiry, and nothing else. The candidates and the
  # identities stay in memory: the app draws a panel, and a panel needs neither.
  defp encode_pending(request) do
    Jason.encode!(%{"request_id" => request.id, "expires_at" => request.expires_at}, pretty: true)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_pending(home) do
    home |> pending_path() |> File.rm()

    :ok
  rescue
    error -> unpublished(error.__struct__)
  end

  defp unpublished(reason) do
    Logger.warning("worker pending selection file not published (#{inspect(reason)})")

    :ok
  end

  # The same write discipline `ConnectionStatus` publishes its own file with: a
  # uniquely named temporary file in the same directory, made owner-only, then
  # renamed over the target, so the app reads either the previous file or the
  # complete new one and never a half-written one.
  #
  # The path is derived from the worker's own configured or default storage root
  # — trusted application configuration, never web or user input. Documented
  # false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_atomically(directory, file, contents) do
    temporary = file <> ".#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, file) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end
end
