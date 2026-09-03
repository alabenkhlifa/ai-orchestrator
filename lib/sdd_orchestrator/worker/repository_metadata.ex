defmodule SddOrchestrator.Worker.RepositoryMetadata do
  @moduledoc """
  The worker release's side of one repository-metadata question: turn a
  folder the person already pointed at (or one they are about to) into the
  four fields the control plane's adapter contract allows, and hold that
  folder in memory so a second question about the same binding attempt
  needs no second panel.

  ## Two names, two lifetimes

  Every inbound message carries `request_id`, the control plane's own
  correlation id for this one call — fresh every time — and
  `selection_ref`, stable across a prepare and every later revalidate for
  the same binding attempt. The held folder is keyed by `selection_ref`,
  because that sameness is exactly what tells this module "no panel
  needed, I already have this folder." A cancellation still names a held
  folder's owner by `request_id`, because that is the only id the control
  plane itself knows to cancel by; it is resolved back to the in-flight
  `selection_ref` from this process's own state.

  ## Getting a folder

  Getting a folder is `Worker.RepositorySelection`'s job, not this
  module's. When nothing usable is held, this module calls
  `RepositorySelection.request_path/3` with the `selection_ref` standing in
  for `RepositorySelection`'s own, unrelated internal request id — a
  deliberate reuse, not a coincidence, that makes
  `RepositorySelection.close(selection_ref)` exactly the right call to
  cancel an in-flight pick, with no separate id-mapping table needed.
  Nothing here draws a panel, touches the filesystem, or runs Git
  directly: `RepositorySelection` owns the panel and
  `RepositoryAssessments.WorkerRepositoryMetadata` owns the repository
  check.

  ## Held, and for how long

  A held folder's expiry is fixed at the moment it is first stored, to the
  `expires_at` the request that found it carried. It is never extended by
  a later revalidate that reuses it. This is the only expiry information a
  worker ever has, and it is a reasonable bound: the control plane's own
  wait window for a call is at least as long as the binding's own life.

  A folder held in this process's memory does not survive this release
  restarting, which is correct: a restarted release has forgotten the
  request it belonged to as completely as the control plane concluding its
  own timeout would.

  ## The privacy discipline

  The chosen path lives only in this process's own state and in the local
  variables of the functions that use it. It is never logged, at any
  level. The identity comparison this module performs duplicates
  `Worker.RepositorySelection`'s own private comparison rather than
  importing it, matching `RepositoryKits.WorkerKitComparison`'s own
  precedent for the same call: two callers of one comparison, not one
  shared module reaching into another's private surface.
  """

  use GenServer

  require Logger

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.RepositoryAssessments.WorkerRepositoryMetadata
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.RepositorySelection

  @typedoc "Sends one finished answer payload back to the control plane."
  @type reply :: (map() -> any())

  @doc """
  Starts the single metadata-question holder for this worker release.

  `opts` may carry `:home_override`, the storage root
  `Worker.RepositorySelection` and `Worker.Configuration` are given for
  this request; production callers pass neither.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Takes one metadata question that arrived from the control plane.

  `payload` is the decoded inbound message (`request_id`, `selection_ref`,
  `repository_provider`, `repository_id`, `selected_root`, `expires_at`)
  and `reply` is called exactly once with the finished answer payload:
  a `"metadata"`, a `"refused"`, or a `"cancelled"` outcome. `home_override`
  is the storage root the calling connection was configured with; `nil`
  means the one this process was started with.

  When a folder is already held for this request's `selection_ref`, and it
  has not expired, this answers at once from that folder and opens no
  panel — the revalidate path. Otherwise a folder is requested through
  `Worker.RepositorySelection`, which the person answers through the Mac
  app's one panel.

  Cast rather than called, because the caller is the gateway connection's
  own callback and it must never wait on a Git check or a native panel to
  keep serving the socket. A request that arrives with no usable id is
  dropped, which the control plane already reports as a request the
  worker never answered.
  """
  @spec open(map(), reply(), String.t() | nil) :: :ok
  def open(payload, reply, home_override \\ nil)
      when is_map(payload) and is_function(reply, 1) do
    GenServer.cast(__MODULE__, {:open, payload, reply, home_override})
  end

  @doc """
  Cancels the in-flight question named by its wire `request_id`.

  Only a question still awaiting a panel can be cancelled: a held folder
  answers a revalidate at once, before this could ever apply to it. An id
  that does not name the question currently awaiting a panel changes
  nothing, the same way `RepositorySelection.close/1`'s own mismatched id
  changes nothing.
  """
  @spec close(String.t()) :: :ok
  def close(request_id) when is_binary(request_id) do
    GenServer.cast(__MODULE__, {:close, request_id})
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       home_override: Keyword.get(opts, :home_override),
       awaiting: nil,
       held: %{}
     }}
  end

  @impl GenServer
  def handle_cast({:open, payload, reply, home_override}, state) do
    case parse_request(payload) do
      {:ok, request} ->
        home = home_override || state.home_override
        {:noreply, answer_request(request, reply, home, state)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:close, request_id}, %{awaiting: %{request_id: request_id}} = state) do
    RepositorySelection.close(state.awaiting.selection_ref)

    {:noreply, %{state | awaiting: nil}}
  end

  def handle_cast({:close, _request_id}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({:path_answer, selection_ref, choice}, state) do
    case state.awaiting do
      %{selection_ref: ^selection_ref} = request ->
        {:noreply, resolve_path_answer(request, choice, state)}

      # A late message from a request this process no longer holds: either
      # replaced by a newer question, or already cancelled.
      _stale ->
        {:noreply, state}
    end
  end

  # Answers a request either at once, from an unexpired held folder, or by
  # asking `RepositorySelection` for one. Nothing in either branch changes
  # what a previously-held folder was stored under.
  defp answer_request(request, reply, home, state) do
    case usable_held_entry(state.held, request.selection_ref) do
      {:ok, entry} ->
        outcome = inspect_folder(entry.path, request, home)
        reply.(built_answer(request, outcome))

        state

      :none ->
        request_folder(request, reply, home, state)
    end
  end

  defp usable_held_entry(held, selection_ref) do
    case Map.fetch(held, selection_ref) do
      {:ok, %{expires_at: expires_at} = entry} ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt,
          do: {:ok, entry},
          else: :none

      :error ->
        :none
    end
  end

  # Nothing usable is held, so a folder is requested through the one panel
  # owner. `selection_ref` stands in for `RepositorySelection`'s own,
  # unrelated internal request id, which is what makes
  # `RepositorySelection.close(selection_ref)` the right call to cancel this.
  defp request_folder(request, reply, home, state) do
    connection = self()

    path_reply = fn choice ->
      send(connection, {:path_answer, request.selection_ref, choice})
    end

    RepositorySelection.request_path(
      %{"request_id" => request.selection_ref, "expires_at" => request.expires_at},
      path_reply,
      home
    )

    %{state | awaiting: Map.merge(request, %{reply: reply, home: home})}
  end

  defp resolve_path_answer(request, :cancelled, state) do
    request.reply.(%{"request_id" => request.request_id, "outcome" => "cancelled"})

    %{state | awaiting: nil}
  end

  defp resolve_path_answer(request, path, state) do
    outcome = inspect_folder(path, request, request.home)
    request.reply.(built_answer(request, outcome))

    %{state | awaiting: nil, held: hold_on_success(state.held, request, path, outcome)}
  end

  defp inspect_folder(path, request, home) do
    WorkerRepositoryMetadata.inspect(
      path,
      request.selected_root,
      %{repository_provider: request.repository_provider, repository_id: request.repository_id},
      identity_matcher(home)
    )
  end

  # A folder is held only once it has been read successfully. A refusal
  # holds nothing, so the next question for the same reference opens a new
  # panel rather than reusing anything that failed the check.
  defp hold_on_success(held, request, path, {:ok, _result}),
    do: Map.put(held, request.selection_ref, %{path: path, expires_at: parse_expiry(request.expires_at)})

  defp hold_on_success(held, _request, _path, {:error, _reason}), do: held

  defp built_answer(request, {:ok, result}) do
    %{
      "request_id" => request.request_id,
      "outcome" => "metadata",
      "repository_provider" => result.repository_provider,
      "repository_id" => result.repository_id,
      "root" => result.root,
      "commit" => result.commit
    }
  end

  defp built_answer(request, {:error, reason}) do
    %{"request_id" => request.request_id, "outcome" => "refused", "reason" => wire_reason(reason)}
  end

  # The three refusals `RepositoryAssessments.WorkerRepositoryMetadata` names,
  # and anything unexpected folded into the same generic refusal a
  # `:repository_unavailable` already is.
  defp wire_reason(:repository_mismatch), do: "repository_mismatch"
  defp wire_reason(:root_escape), do: "root_escape"
  defp wire_reason(_other), do: "repository_unavailable"

  defp parse_request(payload) do
    with {:ok, request_id} <- fetch_id(payload, "request_id"),
         {:ok, selection_ref} <- fetch_id(payload, "selection_ref") do
      {:ok,
       %{
         request_id: request_id,
         selection_ref: selection_ref,
         repository_provider: Map.get(payload, "repository_provider"),
         repository_id: Map.get(payload, "repository_id"),
         selected_root: Map.get(payload, "selected_root"),
         expires_at: Map.get(payload, "expires_at")
       }}
    else
      :error ->
        Logger.warning(
          "worker ignoring a repository metadata request with no request id or selection ref"
        )

        :error
    end
  end

  defp fetch_id(payload, key) do
    case Map.get(payload, key) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _unusable -> :error
    end
  end

  # A held folder's expiry is fixed at the moment it is stored, from the
  # `expires_at` the request that found it carried. A value that cannot be
  # parsed is treated as already expired rather than held indefinitely; a
  # trusted control plane never sends one that fails to parse.
  defp parse_expiry(expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> DateTime.utc_now()
    end
  end

  defp parse_expiry(_expires_at), do: DateTime.utc_now()

  # Duplicated from `Worker.RepositorySelection`'s own private
  # `compare_identity/3`, deliberately: this task's boundary does not touch
  # `repository_selection.ex`, and `RepositoryKits.WorkerKitComparison`'s
  # moduledoc makes the same call for the same reason. The dispatch has to
  # match the control plane's own `Devices.matches_repository?/3`, because
  # the control plane decides from this answer whether the chosen
  # repository is already linked to a project.
  defp identity_matcher(home) do
    fn path, %{repository_id: repository_id} -> compare_identity(path, repository_id, home) end
  end

  defp compare_identity(path, repository_id, home) do
    case PortableRepositoryIdentity.parse(repository_id) do
      {:ok, _portable} ->
        PortableRepositoryIdentity.match(path, repository_id)

      {:error, :legacy_identifier} ->
        PortableRepositoryIdentity.match_legacy(path, repository_id, workspace_salt(home))

      # A non-canonical placeholder from before the contract. It cannot
      # authorize a match and is never treated as portable.
      {:error, :invalid_identifier} ->
        {:ok, false}
    end
  end

  # Every legacy fingerprint was salted with the device workspace that owns
  # the repository, which is this worker's own workspace. Read from the
  # configuration already on disk under the same home the request came
  # with, so no new value has to travel in the request. An unpaired or
  # unreadable configuration yields no salt, and `match_legacy/3` then
  # reports no match rather than guessing one.
  defp workspace_salt(home) do
    case Configuration.load(home) do
      {:ok, config} -> config.device_workspace_id
      {:error, _reason} -> nil
    end
  rescue
    error -> unsalted(error.__struct__)
  end

  # Only the exception's name is reported, for the same reason
  # `Worker.RepositorySelection` reports only that: a `File.Error` message
  # carries the path.
  defp unsalted(reason) do
    Logger.warning("worker could not read its workspace for a legacy match (#{inspect(reason)})")

    nil
  end
end
