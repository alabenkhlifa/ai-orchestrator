defmodule SddOrchestrator.RepositorySelection.Stub do
  @moduledoc """
  The development stand-in for an attached worker, as a transport rather than a
  flag.

  There used to be one `:device_worker_stub` gate inside each screen that asks
  for a folder, and three copies of a gate is how nobody noticed the real path
  had never run. This is the same stand-in behind the real contract instead: it
  implements `SddOrchestrator.RepositorySelection.Transport`, so the browser
  suite drives exactly the code a production control plane drives and only the
  transport differs. It is selected in the test environment and under
  `E2E_MODE`, and nowhere else, so a plain development server has no stand-in
  and a flow that only works with one is visibly broken there.

  The answer is computed, not scripted. It runs `RepositoryValidation` and
  `PortableRepositoryIdentity` over the configured stub folder, exactly as
  `SddOrchestrator.Worker.RepositorySelection` runs them over the folder a
  person picked, so `matches`, refusals, and generated identities are real. What
  the stand-in skips is the panel and the network, not the check.

  The answer goes back through `SddOrchestrator.RepositorySelection.answer/2`
  with the request's own workspace and worker id, so the request server applies
  the same open-request, single-outcome, and foreign-answer rules it applies to
  a real worker.

  ## Why the answer comes from another process

  `push/1` is called by `SddOrchestrator.RepositorySelection.Server` from inside
  its own `handle_call({:open, ...})`, and `answer/2` is a `GenServer.call` to
  that same server. Answering inside `push/1` would therefore be the server
  calling itself and would deadlock until the call timed out. So `push/1` spawns
  a process, and that process does the work and answers.

  That spawned process is also what `push/1` returns, because the server
  monitors what it pushed to in order to report `:worker_lost`. Returning
  `self()` would name the server itself. A short-lived process is safe here
  rather than racy: it blocks in `answer/2` until the server has finished
  opening the request, which is the same call that installs the monitor, so it
  cannot exit before it is watched. Every failure inside it is turned into an
  `inaccessible` answer rather than an exit, for the same reason.

  Nothing here logs, and no path leaves this module. The stub folder is read
  from configuration, matched against, and reduced to a folder name and a list
  of references, exactly as a worker reduces the folder a person chose.
  """
  @behaviour SddOrchestrator.RepositorySelection.Transport

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryValidation
  alias SddOrchestrator.RepositorySelection
  alias SddOrchestrator.RepositorySelection.AttachmentCodec
  alias SddOrchestrator.RepositorySelection.SelectionRequest

  @impl true
  @spec push(SelectionRequest.t()) :: {:ok, pid()}
  def push(%SelectionRequest{} = request) do
    {:ok, spawn(fn -> answer(request) end)}
  end

  @impl true
  @spec cancel(SelectionRequest.t()) :: :ok
  def cancel(%SelectionRequest{}), do: :ok

  @doc """
  The folder this stand-in answers with.

  `:device_worker_stub_folder` is what the browser suite points at the
  repository it seeded. Without one the working directory is used, which is a
  real Git repository in this project and therefore still a real answer.
  """
  @spec folder() :: Path.t()
  def folder do
    Application.get_env(:sdd_orchestrator, :device_worker_stub_folder) || File.cwd!()
  end

  # Runs in the spawned process. It must reach `answer/2` on every path,
  # including a failure, because exiting first is what the request server would
  # read as a lost worker.
  defp answer(request) do
    attachment = %{
      device_workspace_id: request.device_workspace_id,
      worker_id: request.worker_id
    }

    RepositorySelection.answer(attachment, result(request))
  catch
    _kind, _reason -> :ok
  end

  # The request is encoded first so the candidates this stand-in compares are
  # the candidates a real worker would receive, references stringified and all.
  defp result(request) do
    case AttachmentCodec.encode_request(request) do
      {:ok, payload} -> answered(request, folder(), payload)
      {:error, _reason} -> refused(request.id, :inaccessible)
    end
  catch
    # A folder that cannot be resolved or read at all raises rather than
    # returning, and a stand-in that dies here would be reported as a lost
    # worker instead of an unreadable folder.
    _kind, _reason -> refused(request.id, :inaccessible)
  end

  defp answered(request, path, payload) do
    with {:ok, _roots} <- RepositoryValidation.root_commit_ids(path),
         {:ok, identity} <- generated_identity(payload["generate"], path) do
      # The request's own workspace is the salt, which is the same value a real
      # worker reads from its paired configuration, so the stand-in cannot
      # answer a legacy candidate differently from the worker it stands in for.
      matches =
        matching_refs(payload["candidates"], path, request.device_workspace_id)

      selected(request.id, path, matches, identity)
    else
      {:error, reason} -> refused(request.id, reason)
    end
  end

  defp selected(request_id, path, matches, identity) do
    payload = %{
      "request_id" => request_id,
      "outcome" => "selected",
      "folder_name" => Path.basename(path),
      "matches" => matches
    }

    if identity, do: Map.put(payload, "identity", identity), else: payload
  end

  defp refused(request_id, reason) do
    %{"request_id" => request_id, "outcome" => outcome_name(reason)}
  end

  defp generated_identity(true, path), do: PortableRepositoryIdentity.generate(path)
  defp generated_identity(_generate, _path), do: {:ok, nil}

  # A candidate whose identity cannot be parsed is simply not a match, the same
  # answer a real worker gives: one malformed value in the requester's own table
  # must neither fail the selection nor be reported as a match.
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

  # The same dispatch `SddOrchestrator.Devices.matches_repository?/3` makes on
  # the control plane, and the same one
  # `SddOrchestrator.Worker.RepositorySelection` makes on a Mac. The control
  # plane reads this answer to decide whether the chosen repository is already
  # linked to a project, so a stand-in that reported "no match" for a legacy
  # candidate would let the browser suite pass a flow that turns one repository
  # into two projects on a real worker. A project onboarded before the portable
  # format still carries a workspace-scoped fingerprint, and only
  # `match_legacy/3` can answer for one.
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

  # The three refusals `RepositoryValidation` reports, named as
  # `SelectionResult` accepts them. Anything else is a folder this stand-in
  # could not read.
  defp outcome_name(:not_a_git_repository), do: "not_a_git_repository"
  defp outcome_name(:empty_repository), do: "empty_repository"
  defp outcome_name(_reason), do: "inaccessible"
end
