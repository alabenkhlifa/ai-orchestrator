defmodule SddOrchestrator.RepositoryInitialization.StagingBuilder do
  @moduledoc """
  Materializes one confirmed `RepositoryInitialization.Plan` into an isolated
  `StagingWorkspace` directory (specs/16 Task 4, AC-07, AC-08, AC-10).

  This module deliberately does not route through `Delivery.AgentAdapter` or
  a coding-agent CLI, and does not call `InitializationDispatch.dispatch/2`
  (see `specs/16-empty-repository-initialization/progress.md`, "Task 4
  preflight"). The fixed skeleton (`Skeleton.content/0`) and the kit's fully
  known `RepositoryKitPackage.file_manifest` leave nothing for a generically
  capable coding agent to decide, so `InitializationManifest.new/1` and
  `InitializationDispatch.negotiate/1`/`authorize_grant/2` (Task 1) are reused
  only for their authorization/capability-grant primitives — the manifest
  built here is an audit record, never dispatched to an adapter.

  The path-escape/undeclared-output/package-tamper/no-network/no-hook proof
  surface defends against the *vendored kit package's own content*
  (externally sourced, per `RepositoryKitPackage`'s provenance/license/scripts
  fields), not an unpredictable LLM agent: every kit file's path is
  re-validated and its content re-hashed against its recorded `sha256` here,
  defense in depth beyond what `RepositoryKits.publish_package/2` already
  checks at publish time, and a kit's declared `scripts` are vendored
  (written, permission bit preserved) but never executed as a subprocess.

  `start_run/4` re-derives the plan's live confirmation snapshot and digest
  rather than trusting the caller's plan struct (AC-07's mechanism for this
  task), and refuses unless the caller's connection actually negotiated the
  `staging_write` capability grant (AC-08) — the same enforcement point that
  keeps a read-only, plan-discovery-only connection from ever reaching this
  path. `build/3` then walks a small deterministic pipeline — staging
  directory, skeleton, kit vendoring, Git initialization — updating the run's
  `state` and ordered `progress` log as it goes, and cleans up the entire
  partial staging directory on any refusal or failure so no orphaned state
  survives. No commit is created here; that is Task 5's job.

  Cancellation is checked only at two coarse checkpoints (after the skeleton
  is written, and again after kit vendoring, before Git setup) rather than
  preemptively — proportionate for how little work a run this small actually
  does. `build/3`'s optional `:after_kit_vendored` hook exists only so a test
  can request cancellation in the window between those two checkpoints; no
  production caller passes it.
  """

  alias SddOrchestrator.Delivery.CanonicalJson
  alias SddOrchestrator.Delivery.{InitializationDispatch, InitializationManifest, WorkerProtocol}
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization
  alias SddOrchestrator.RepositoryInitialization.{Plan, Run, StagingWorkspace}
  alias SddOrchestrator.RepositoryKits

  @capability_grant "staging_write"

  @type start_error ::
          :invalid_request
          | :plan_not_ready
          | :plan_not_confirmed
          | :plan_changed
          | :capability_grant_denied
          | :invalid_manifest
          | Ecto.Changeset.t()

  @doc """
  Authorizes and starts one staging build for a confirmed plan.

  Refuses unless the plan has reached `"ready"` and was confirmed
  (`:plan_not_ready` / `:plan_not_confirmed`), unless its live, freshly
  re-derived confirmation snapshot still hashes to its stored
  `confirmation_digest` (`:plan_changed` — a real recomputation, not a trust
  of the caller's plan struct), and unless `negotiated_grants` actually
  includes `"staging_write"` (`:capability_grant_denied`).

  Retrying with the same `idempotency_key` returns the already-created run
  without starting a second build.

  Before a `Run` exists (every refusal above), the error is the plain
  two-element `{:error, reason}`. Once a `Run` has been created, this
  delegates to `build/3` and therefore shares its result shape: `{:ok, run}`
  on success or cancellation, or `{:error, reason, run}` on a build failure —
  the failed run is always returned so its `progress` and `failure_reason`
  stay visible.
  """
  @spec start_run(Plan.t(), Ecto.UUID.t(), [String.t()], String.t()) ::
          {:ok, Run.t()} | {:error, start_error()} | {:error, atom(), Run.t()}
  def start_run(%Plan{} = plan, worker_id, negotiated_grants, idempotency_key)
      when is_binary(worker_id) and is_list(negotiated_grants) and is_binary(idempotency_key) do
    case existing_run(idempotency_key) do
      {:ok, run} ->
        {:ok, run}

      {:error, :not_found} ->
        authorize_and_start(plan, worker_id, negotiated_grants, idempotency_key)
    end
  end

  def start_run(_plan, _worker_id, _negotiated_grants, _idempotency_key),
    do: {:error, :invalid_request}

  @doc """
  Requests cancellation of one run.

  Only records the request; `build/3`'s two checkpoints are what actually
  stop and clean up. For a run still `"pending"`, that is enough on its own:
  `build/3` checks for a cancellation request before doing anything.
  """
  @spec cancel_run(Run.t()) :: {:ok, Run.t()} | {:error, atom()}
  def cancel_run(%Run{} = run) do
    update_run(Run.cancel_request_changeset(run, %{cancel_requested_at: now()}))
  end

  @doc """
  Deterministically materializes `plan` into `run`'s staging directory.

  Returns `{:ok, run}` with `run.state` either `"completed"` or `"canceled"`
  (cancellation is a deliberate stop, not a failure), or `{:error, reason,
  run}` with `run.state == "failed"` and the partial staging directory
  already removed.
  """
  @spec build(Run.t(), Plan.t(), keyword()) :: {:ok, Run.t()} | {:error, atom(), Run.t()}
  def build(%Run{} = run, %Plan{} = plan, opts \\ []) do
    hook = Keyword.get(opts, :after_kit_vendored, fn -> :ok end)

    plan
    |> build_steps(hook)
    |> Enum.reduce_while({:ok, run}, &run_step/2)
    |> finish()
  end

  defp authorize_and_start(plan, worker_id, negotiated_grants, idempotency_key) do
    with :ok <- ensure_ready_and_confirmed(plan),
         :ok <- ensure_unchanged(plan),
         {:ok, manifest} <- build_manifest(plan),
         :ok <- InitializationDispatch.authorize_grant(negotiated_grants, @capability_grant) do
      create_and_build(plan, worker_id, manifest.dispatch_id, idempotency_key)
    end
  end

  defp create_and_build(plan, worker_id, dispatch_id, idempotency_key) do
    case create_run(plan, worker_id, dispatch_id, idempotency_key) do
      {:ok, run} -> build(run, plan)
      {:error, changeset} -> create_run_error(changeset, idempotency_key)
    end
  end

  # A concurrent caller may have inserted the same idempotency key between
  # this call's own `existing_run/1` lookup and its insert attempt; that race
  # is resolved the same way as an ordinary retry, by returning the row that
  # won.
  defp create_run_error(changeset, idempotency_key) do
    if unique_idempotency_violation?(changeset) do
      existing_run(idempotency_key)
    else
      {:error, changeset}
    end
  end

  defp unique_idempotency_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:idempotency_key, {_msg, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  defp ensure_ready_and_confirmed(%Plan{current_field: "ready", confirmed_at: %DateTime{}}),
    do: :ok

  defp ensure_ready_and_confirmed(%Plan{current_field: "ready"}),
    do: {:error, :plan_not_confirmed}

  defp ensure_ready_and_confirmed(%Plan{}), do: {:error, :plan_not_ready}

  # The plan-staleness re-check: re-fetches the plan by id, re-derives its
  # live confirmation snapshot, hashes it exactly the way
  # `RepositoryInitialization`'s own `persist_confirmation/2` does (canonical
  # JSON, sha256 hex), and compares against the *live* row's own
  # `confirmation_digest` — never the passed-in `plan` struct's fields. This
  # is what makes the changed-input invalidation proof real: it catches a
  # bound field that changed without going through the invalidation path
  # `set_kit_choice/2` normally guarantees, not just a plan the caller passed
  # in stale.
  defp ensure_unchanged(%Plan{id: id}) do
    case RepositoryInitialization.get_plan(id) do
      {:ok, live_plan} -> compare_digest(live_plan)
      {:error, :not_found} -> {:error, :plan_changed}
    end
  end

  defp compare_digest(%Plan{confirmation_digest: nil}), do: {:error, :plan_changed}

  defp compare_digest(live_plan) do
    case RepositoryInitialization.confirmation_snapshot(live_plan) do
      {:ok, snapshot} -> compare_digest(live_plan, snapshot)
      {:error, :plan_not_ready} -> {:error, :plan_changed}
    end
  end

  defp compare_digest(live_plan, snapshot) do
    {:ok, encoded} = CanonicalJson.encode(snapshot)
    digest = encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if digest == live_plan.confirmation_digest, do: :ok, else: {:error, :plan_changed}
  end

  # Never carries a real path: `agent_ref`/`instructions` only ever name the
  # plan id and its kit choice, matching the "runtime, worker, provider, and
  # repository credentials remain outside agent-readable content" boundary —
  # even though nothing here is actually dispatched to an agent.
  defp build_manifest(plan) do
    InitializationManifest.new(%{
      "manifest_version" => InitializationManifest.manifest_version(),
      "device_workspace_id" => plan.device_workspace_id,
      "dispatch_id" => WorkerProtocol.generate_id(),
      "capability_grant" => @capability_grant,
      "agent_ref" => %{"kind" => "staging_builder"},
      "instructions" => %{
        "kind" => "staging_build",
        "plan_id" => plan.id,
        "kit_choice" => plan.kit_choice
      }
    })
  end

  defp existing_run(idempotency_key) do
    case Repo.get_by(Run, idempotency_key: idempotency_key) do
      %Run{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end

  defp create_run(plan, worker_id, dispatch_id, idempotency_key) do
    %Run{}
    |> Run.create_changeset(%{
      plan_id: plan.id,
      device_workspace_id: plan.device_workspace_id,
      worker_id: worker_id,
      dispatch_id: dispatch_id,
      idempotency_key: idempotency_key,
      state: "pending",
      kit_choice: plan.kit_choice,
      kit_package_id: plan.kit_package_id,
      kit_package_digest: plan.kit_package_digest
    })
    |> Repo.insert()
  end

  ## Build pipeline

  defp build_steps(plan, hook) do
    [
      &mark_running/1,
      &prepare_workspace/1,
      &record_staging_prepared/1,
      &write_readme(&1, plan),
      &checkpoint/1,
      &vendor_kit(&1, plan),
      &run_hook(&1, hook),
      &checkpoint/1,
      &git_setup/1
    ]
  end

  defp run_step(step, {:ok, run}) do
    case step.(run) do
      {:ok, run} -> {:cont, {:ok, run}}
      {:canceled, run} -> {:halt, {:canceled, run}}
      {:error, reason} -> {:halt, {:error, reason, run}}
    end
  end

  defp run_step(_step, halted), do: {:halt, halted}

  defp finish({:ok, run}) do
    {:ok, completed} =
      update_run(Run.state_changeset(run, %{state: "completed", finished_at: now()}))

    {:ok, completed}
  end

  defp finish({:canceled, run}), do: {:ok, run}

  defp finish({:error, reason, run}), do: {:error, reason, fail(run, reason)}

  defp mark_running(run) do
    update_run(Run.state_changeset(run, %{state: "running", started_at: now()}))
  end

  defp prepare_workspace(run) do
    case StagingWorkspace.prepare(run) do
      {:ok, _staging_path} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_staging_prepared(run) do
    append_event(run, "progress", %{"step" => "staging_prepared"})
  end

  defp write_readme(run, plan) do
    case StagingWorkspace.join(run, "README.md") do
      {:ok, absolute} -> write_readme_file(run, absolute, plan)
      {:error, reason} -> {:error, reason}
    end
  end

  # `absolute` was proven contained by `StagingWorkspace.join/2` immediately
  # before this call, from the fixed literal `"README.md"` — not a traversal
  # sink. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_readme_file(run, absolute, plan) do
    case File.write(absolute, readme_content(plan)) do
      :ok ->
        append_event(run, "progress", %{"step" => "skeleton_written", "files" => ["README.md"]})

      {:error, _reason} ->
        {:error, :staging_write_failed}
    end
  end

  defp readme_content(%Plan{purpose: purpose}) do
    body =
      if is_binary(purpose) and String.trim(purpose) != "" do
        String.trim(purpose)
      else
        "Purpose not yet recorded."
      end

    "# Repository\n\n" <> body <> "\n"
  end

  # A cancellation request is checked only here and again after kit
  # vendoring — coarse-grained, not preemptive, which is proportionate for
  # how little work a run this small actually does. Reloads the run so a
  # request recorded by a concurrent caller is seen even though `run` was
  # read earlier in this pipeline.
  defp checkpoint(run) do
    reloaded = Repo.get!(Run, run.id)

    if reloaded.cancel_requested_at do
      cancel(reloaded)
    else
      {:ok, reloaded}
    end
  end

  defp cancel(run) do
    cleanup_staging(run)

    {:ok, canceled} =
      update_run(Run.state_changeset(run, %{state: "canceled", finished_at: now()}))

    {:canceled, canceled}
  end

  defp vendor_kit(run, %Plan{kit_choice: "declined"}), do: {:ok, run}

  defp vendor_kit(run, %Plan{kit_choice: "included", kit_package_digest: digest}) do
    case fetch_verified_package(digest) do
      {:ok, package} -> vendor_package(run, package)
      {:error, reason} -> {:error, reason}
    end
  end

  defp vendor_package(run, package) do
    files = get_in(package.file_manifest, ["files"]) || []

    case vendor_files(run, files) do
      {:ok, run} ->
        append_event(run, "evidence", %{
          "step" => "kit_vendored",
          "kit_package_digest" => package.digest,
          "file_count" => length(files)
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Re-fetches and re-verifies the package rather than trusting the plan's
  # snapshot alone — the "package tamper" proof surface: a package removed
  # from, or no longer matching, the catalog refuses the whole run instead of
  # silently vendoring nothing.
  defp fetch_verified_package(digest) when is_binary(digest) do
    case RepositoryKits.get_by_digest(digest) do
      {:ok, %{digest: ^digest} = package} -> {:ok, package}
      {:ok, _mismatched} -> {:error, :kit_package_unavailable}
      {:error, :not_found} -> {:error, :kit_package_unavailable}
    end
  end

  defp fetch_verified_package(_digest), do: {:error, :kit_package_unavailable}

  defp vendor_files(run, files) when is_list(files) do
    Enum.reduce_while(files, {:ok, run}, fn file, {:ok, run} ->
      case vendor_file(run, file) do
        {:ok, run} -> {:cont, {:ok, run}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp vendor_files(_run, _files), do: {:error, :kit_package_unavailable}

  defp vendor_file(run, %{"path" => path, "content" => encoded, "sha256" => expected_sha} = file) do
    executable? = Map.get(file, "executable") == true

    with {:ok, relative} <- validate_kit_path(path),
         {:ok, content} <- decode_and_verify(encoded, expected_sha),
         {:ok, absolute} <- StagingWorkspace.join(run, relative),
         :ok <- write_kit_file(absolute, content, executable?) do
      {:ok, run}
    end
  end

  defp vendor_file(_run, _file), do: {:error, :kit_file_invalid}

  # Re-validates the manifest path independently of `StagingWorkspace.join/2`'s
  # own guard and of `RepositoryKits.publish_package/2`'s publish-time check —
  # the "path escape" proof surface for a manifest entry that somehow
  # smuggled a traversal path past those.
  defp validate_kit_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :kit_path_invalid}
      String.starts_with?(path, "/") -> {:error, :kit_path_invalid}
      String.contains?(path, <<0>>) -> {:error, :kit_path_invalid}
      ".." in Path.split(path) -> {:error, :kit_path_invalid}
      true -> {:ok, path}
    end
  end

  defp validate_kit_path(_path), do: {:error, :kit_path_invalid}

  defp decode_and_verify(encoded, expected_sha)
       when is_binary(encoded) and is_binary(expected_sha) do
    case Base.decode64(encoded) do
      {:ok, content} -> verify_content(content, expected_sha)
      :error -> {:error, :kit_file_invalid}
    end
  end

  defp decode_and_verify(_encoded, _expected_sha), do: {:error, :kit_file_invalid}

  defp verify_content(content, expected_sha) do
    actual = content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    if actual == String.downcase(expected_sha) do
      {:ok, content}
    else
      {:error, :kit_file_tampered}
    end
  end

  # The absolute path was proven contained by `StagingWorkspace.join/2`
  # immediately before this call, from an already-validated relative kit
  # path — not a traversal sink. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_kit_file(absolute, content, executable?) do
    with :ok <- File.mkdir_p(Path.dirname(absolute)),
         :ok <- File.write(absolute, content) do
      maybe_chmod(absolute, executable?)
    else
      {:error, _reason} -> {:error, :staging_write_failed}
    end
  end

  defp maybe_chmod(_absolute, false), do: :ok

  # `absolute` is the same `StagingWorkspace.join/2`-contained path
  # `write_kit_file/3` just wrote to immediately before this call — not a
  # traversal sink. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_chmod(absolute, true) do
    case File.chmod(absolute, 0o755) do
      :ok -> :ok
      {:error, _reason} -> {:error, :staging_write_failed}
    end
  end

  defp run_hook(run, hook) do
    hook.()
    {:ok, run}
  end

  # `git init`/`git config` here are this module's own fixed, trusted
  # commands — never a kit-provided path or argument, unlike the "no-hook"
  # rule for vendored `scripts`, which are written but never invoked as a
  # subprocess.
  defp git_setup(run) do
    with {:ok, staging_path} <- StagingWorkspace.staging_path(run),
         :ok <- ensure_git_available(),
         :ok <- git_init(staging_path),
         :ok <- disable_git_hooks(staging_path) do
      append_event(run, "progress", %{"step" => "git_initialized"})
    end
  end

  defp ensure_git_available do
    if System.find_executable("git"), do: :ok, else: {:error, :git_unavailable}
  end

  defp git_init(staging_path) do
    case System.cmd("git", ["init", "--quiet", staging_path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :git_init_failed}
    end
  end

  # Pointing `core.hooksPath` at a directory that is created but never
  # populated is a portable way to neutralize the sample hooks `git init`
  # itself writes into `.git/hooks`, without depending on `/dev/null` being a
  # valid hooks-path value on every supported operating system.
  #
  # The hooks directory is a fixed subpath of the staging directory `git
  # init` just created, itself already proven contained — not a traversal
  # sink. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp disable_git_hooks(staging_path) do
    disabled_dir = Path.join([staging_path, ".git", "hooks-disabled"])
    File.mkdir_p!(disabled_dir)

    case System.cmd("git", ["-C", staging_path, "config", "core.hooksPath", disabled_dir],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :git_init_failed}
    end
  end

  defp fail(run, reason) do
    cleanup_staging(run)

    event = build_event("failed", %{"reason" => to_string(reason)})

    {:ok, failed} =
      update_run(
        Run.state_changeset(run, %{
          state: "failed",
          failure_reason: to_string(reason),
          finished_at: now(),
          progress: run.progress ++ [event]
        })
      )

    failed
  end

  defp cleanup_staging(run) do
    case StagingWorkspace.staging_path(run) do
      {:ok, path} -> File.rm_rf!(path)
      {:error, _reason} -> :ok
    end
  end

  defp append_event(run, type, payload) do
    event = build_event(type, payload)
    update_run(Run.progress_changeset(run, %{progress: run.progress ++ [event]}))
  end

  defp build_event(type, payload) do
    %{"type" => type, "occurred_at" => now() |> DateTime.to_iso8601(), "payload" => payload}
  end

  defp update_run(changeset) do
    case Repo.update(changeset) do
      {:ok, run} -> {:ok, run}
      {:error, _changeset} -> {:error, :run_transition_failed}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
