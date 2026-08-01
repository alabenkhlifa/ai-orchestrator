defmodule SddOrchestrator.Delivery.Previews do
  @moduledoc """
  The lifecycle of one branch preview, from a verified commit to its cleanup.

  A preview begins only where verification already ended. This module reads the
  verified completion the gate recorded and deploys exactly the commit named
  there — it never re-derives the verdict, never writes to the run, the attempt,
  or the feature, and has no way to make any of them say something different.
  That is deliberate and load-bearing: a failed, timed-out, or entirely absent
  preview must leave an otherwise verified feature exactly where it was.

  Identity is the binding. A request is bound to one run, one attempt, one
  branch, and one exact commit, and asking again for the same binding returns
  the deployment that already exists without touching the provider a second
  time. A commit that differs is not a retry; it is another deployment, and the
  one it replaced becomes `superseded` in the same commit that records it.

  Deadlines belong to the control plane, not to the provider. A provider that
  keeps answering "pending" past the configured request timeout has timed out
  whether or not it ever says so, and a ready deployment past its expiry is
  expired however recently it was reported ready. Both are recorded with their
  own status and reason, distinct from a provider that failed outright, because
  a reader deciding whether to wait, retry, or look elsewhere needs to know
  which of the three happened.

  Cleanup is a seam, not a policy. `cleanup/4` records a durable command before
  the provider is called, so a release interrupted by a restart stays visible as
  owed; when project deletion and cancellation need to release previews, this is
  the function they call. What either of them decides to release, and when, is
  theirs.
  """

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    DeliveryStore,
    PreviewAdapter,
    PreviewDeployment,
    VerificationCompletion
  }

  @activity_type "preview_updated"

  # Step names have to be atoms, so they come from a fixed list rather than from
  # data. One start supersedes the run's current previews, and the invariant
  # this function itself maintains means there is normally exactly one; the
  # bound only has to survive a rare concurrent double start, and anything past
  # it is superseded by the next verified attempt.
  @supersession_steps ~w(
    superseded_1 superseded_2 superseded_3 superseded_4
    superseded_5 superseded_6 superseded_7 superseded_8
  )a

  @type authority :: DeliveryStore.authority()

  @type result :: %{
          deployment: PreviewDeployment.t(),
          activity: ActivityEntry.t() | nil,
          changed?: boolean()
        }

  @type error :: :not_verified | PreviewAdapter.error() | DeliveryStore.error()

  @spec activity_type() :: String.t()
  def activity_type, do: @activity_type

  @doc """
  Starts the preview for whatever commit this run's attempt actually verified.

  The verified completion is read rather than supplied, so a caller cannot start
  a preview for a commit that was never proved, and a run with no verified
  completion is refused with `:not_verified` before any provider is contacted.
  A project with no preconfigured preview path is refused the same way, without
  a request.

  Asking twice for the same run, attempt, and commit answers with the deployment
  that already exists and makes no second provider request.
  """
  @spec start(authority(), Ecto.UUID.t(), AgentRun.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def start(authority, project_id, %AgentRun{} = run, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, verified} <- verified_binding(authority, project_id, run),
         {:ok, policy} <- PreviewAdapter.authorize(project_id, Keyword.get(opts, :path)) do
      case held(authority, project_id, run.id, verified) do
        {:ok, deployment} -> {:ok, %{deployment: deployment, activity: nil, changed?: false}}
        :error -> request(authority, project_id, run, verified, policy, now)
      end
    end
  end

  @doc """
  Records what became of a deployment that is still open.

  A terminal deployment is answered unchanged and without a provider call: a
  late status poll must never reopen a preview already reported failed. When the
  project's preview configuration has since been withdrawn, the deadlines are
  still applied, so a pending preview cannot outlive its timeout merely because
  nobody can ask about it any more.
  """
  @spec refresh(authority(), Ecto.UUID.t(), PreviewDeployment.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def refresh(authority, project_id, %PreviewDeployment{} = deployment, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    if PreviewDeployment.open?(deployment) do
      observed = observe(project_id, deployment, now)
      apply_observation(authority, project_id, deployment, observed, now)
    else
      {:ok, %{deployment: deployment, activity: nil, changed?: false}}
    end
  end

  @doc """
  Releases one deployment through the configured adapter.

  The command is recorded before the provider is asked, so an interrupted
  cleanup is still owed rather than forgotten, and a repeat call reuses the same
  command identifier instead of issuing a second one. A deployment already
  released is answered unchanged and the provider is not contacted.
  """
  @spec cleanup(authority(), Ecto.UUID.t(), PreviewDeployment.t(), keyword()) ::
          {:ok, result()} | {:error, error()}
  def cleanup(authority, project_id, %PreviewDeployment{} = deployment, opts \\ []) do
    reason = opts |> Keyword.get(:reason, :requested) |> PreviewAdapter.reason_token()

    if deployment.cleanup_state == "done" do
      {:ok, %{deployment: deployment, activity: nil, changed?: false}}
    else
      release(authority, project_id, deployment, reason)
    end
  end

  @doc "Lists one project's preview deployments, narrowed by the usual bindings."
  @spec list(authority(), Ecto.UUID.t(), keyword()) :: [PreviewDeployment.t()]
  def list(authority, project_id, opts \\ []),
    do: DeliveryStore.list_preview_deployments(authority, project_id, opts)

  @doc "The run's one deployment that a later attempt has not replaced."
  @spec current(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, PreviewDeployment.t()} | :error
  def current(authority, project_id, run_id) do
    authority
    |> list(project_id, run_id: run_id, current: true)
    |> List.last()
    |> case do
      nil -> :error
      deployment -> {:ok, deployment}
    end
  end

  # The commit is read from the recorded verified completion rather than taken
  # from a caller, which is what makes "the exact verified commit" a property of
  # the history instead of an argument someone can get wrong.
  defp verified_binding(authority, project_id, run) do
    case VerificationCompletion.verified_completion(
           authority,
           project_id,
           run.feature_id,
           run.id
         ) do
      {:ok, entry} -> binding(entry, run)
      :error -> {:error, :not_verified}
    end
  end

  defp binding(%ActivityEntry{attempt_id: attempt_id, payload: payload}, run)
       when is_binary(attempt_id) do
    commit = payload["commit_sha"]
    branch = payload["branch"]

    if is_binary(commit) and commit != "" and branch == run.branch do
      {:ok, %{attempt_id: attempt_id, branch: branch, commit_sha: commit}}
    else
      {:error, :not_verified}
    end
  end

  defp binding(_entry, _run), do: {:error, :not_verified}

  defp held(authority, project_id, run_id, verified) do
    authority
    |> list(project_id,
      run_id: run_id,
      attempt_id: verified.attempt_id,
      commit_sha: verified.commit_sha
    )
    |> List.last()
    |> case do
      nil -> :error
      deployment -> {:ok, deployment}
    end
  end

  defp request(authority, project_id, run, verified, policy, now) do
    request = provider_request(project_id, run, verified, policy)
    deadlines = deadlines(policy, now)

    settled =
      policy
      |> PreviewAdapter.request(request)
      |> answered()
      |> settle(deadlines, now)

    attrs = requested_attrs(request, settled, deadlines, now)

    steps =
      [{:deployment, {:insert_preview_deployment, attrs}}] ++
        supersession_steps(authority, project_id, run.id, verified) ++
        [{:activity, {:append_activity, activity_attrs(run, verified, attrs)}}]

    write(authority, project_id, steps)
  end

  defp provider_request(project_id, run, verified, policy) do
    binding = %{
      project_id: project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: verified.attempt_id,
      branch: verified.branch,
      commit_sha: verified.commit_sha,
      path: policy.path,
      provider: policy.provider
    }

    Map.put(binding, :request_key, PreviewAdapter.request_key(binding))
  end

  defp deadlines(policy, now) do
    %{
      timeout_at: DateTime.add(now, policy.request_timeout_ms, :millisecond),
      ttl_seconds: policy.ttl_seconds
    }
  end

  # A provider refusal is a recorded preview outcome, not a lost one. The
  # request that failed still produced a deployment record, because "the
  # provider said no" and "nobody ever asked" must not look the same to a reader.
  defp answered({:ok, observation}), do: observation
  defp answered({:error, :timeout}), do: stopped("timed_out", "preview_request_timeout")
  defp answered({:error, reason}), do: stopped("failed", Atom.to_string(reason))

  defp stopped(status, reason) do
    %{status: status, provider_ref: nil, link: nil, expires_at: nil, failure_reason: reason}
  end

  # The control plane's own answer, applied after the provider's, and the one
  # place a status becomes final. A provider that never stops saying "pending"
  # has still timed out, and a deployment past its expiry is expired however
  # recently it was reported ready.
  defp settle(observed, deadlines, now) do
    expires_at = expiry(observed, deadlines, now)

    cond do
      observed.status == "pending" and past?(deadlines.timeout_at, now) ->
        %{
          observed
          | status: "timed_out",
            link: nil,
            failure_reason: "preview_request_timeout",
            expires_at: expires_at
        }

      observed.status == "expired" or
          (observed.status == "ready" and past?(expires_at, now)) ->
        %{observed | status: "expired", link: nil, failure_reason: nil, expires_at: expires_at}

      true ->
        %{observed | expires_at: expires_at}
    end
  end

  # A provider that states its own expiry is believed; a ready deployment whose
  # provider says nothing gets the configured lifetime, so "expiry is displayed
  # when known" does not become "expiry is never known".
  defp expiry(%{expires_at: %DateTime{} = at}, _deadlines, _now), do: at

  defp expiry(%{status: "ready"}, %{ttl_seconds: ttl}, now) when is_integer(ttl) and ttl > 0,
    do: DateTime.add(now, ttl, :second)

  defp expiry(_observed, _deadlines, _now), do: nil

  defp past?(nil, _now), do: false
  defp past?(%DateTime{} = at, now), do: DateTime.compare(now, at) != :lt

  defp requested_attrs(request, settled, deadlines, now) do
    %{
      project_id: request.project_id,
      feature_id: request.feature_id,
      run_id: request.run_id,
      attempt_id: request.attempt_id,
      branch: request.branch,
      commit_sha: request.commit_sha,
      path: request.path,
      provider: request.provider,
      provider_ref: settled.provider_ref,
      link: usable_link(settled),
      status: settled.status,
      failure_reason: settled.failure_reason,
      requested_at: now,
      ready_at: ready_at(settled, now),
      timeout_at: deadlines.timeout_at,
      expires_at: settled.expires_at
    }
  end

  # A link is kept only while it leads somewhere. An expired, failed, or
  # timed-out deployment holding the URL it once served is how a reader ends up
  # sent to a preview that no longer exists.
  defp usable_link(%{status: "ready", link: link}), do: link
  defp usable_link(_settled), do: nil

  defp ready_at(%{status: "ready"}, now), do: now
  defp ready_at(_settled, _now), do: nil

  defp supersession_steps(authority, project_id, run_id, verified) do
    authority
    |> list(project_id, run_id: run_id, current: true)
    |> Enum.reject(
      &(&1.attempt_id == verified.attempt_id and &1.commit_sha == verified.commit_sha)
    )
    |> Enum.uniq_by(& &1.id)
    |> Enum.zip(@supersession_steps)
    |> Enum.map(fn {deployment, name} ->
      {name, {:supersede_preview_deployment, deployment, {:ref, :deployment, :id}}}
    end)
  end

  # The expiry already recorded is carried into the settlement, so a provider
  # that stops repeating it cannot make an expired deployment look ready again.
  # No new lifetime is invented here: only the original request may set one.
  defp observe(project_id, deployment, now) do
    deployment
    |> reported(project_id)
    |> carry_expiry(deployment)
    |> settle(%{timeout_at: deployment.timeout_at, ttl_seconds: nil}, now)
  end

  defp carry_expiry(%{expires_at: nil} = observed, deployment),
    do: %{observed | expires_at: deployment.expires_at}

  defp carry_expiry(observed, _deployment), do: observed

  # A withdrawn configuration is not an excuse to leave a preview pending
  # forever. What the record already says is carried forward and the deadlines
  # are still applied to it.
  defp reported(deployment, project_id) do
    case PreviewAdapter.authorize(project_id, deployment.path) do
      {:ok, policy} ->
        policy |> PreviewAdapter.status(status_request(deployment, policy)) |> answered()

      {:error, _withdrawn} ->
        recorded(deployment)
    end
  end

  # Named for what it builds — the provider's status request. It was `query/2`,
  # which made Sobelow read every call as a database query and fail the security
  # gate on two false positives. A name that says what this is costs nothing and
  # leaves no suppression to keep true.
  defp status_request(deployment, policy) do
    %{
      request_key: PreviewAdapter.request_key(deployment),
      provider: policy.provider,
      provider_ref: deployment.provider_ref
    }
  end

  defp recorded(deployment) do
    %{
      status: deployment.status,
      provider_ref: deployment.provider_ref,
      link: deployment.link,
      expires_at: deployment.expires_at,
      failure_reason: deployment.failure_reason
    }
  end

  # An observation that says nothing new writes nothing. Polling a preview that
  # is still pending must not append an activity entry every time somebody
  # looks.
  defp apply_observation(authority, project_id, deployment, settled, now) do
    attrs = observed_attrs(deployment, settled, now)

    if unchanged?(deployment, attrs) do
      {:ok, %{deployment: deployment, activity: nil, changed?: false}}
    else
      write(authority, project_id, [
        {:deployment, {:observe_preview_deployment, deployment, attrs}},
        {:activity, {:append_activity, observed_activity(deployment, attrs)}}
      ])
    end
  end

  defp unchanged?(deployment, attrs) do
    attrs.status == deployment.status and attrs.link == deployment.link and
      attrs.provider_ref == deployment.provider_ref and
      attrs.expires_at == deployment.expires_at
  end

  defp observed_attrs(deployment, settled, now) do
    %{
      status: settled.status,
      provider_ref: settled.provider_ref || deployment.provider_ref,
      link: usable_link(settled),
      failure_reason: settled.failure_reason,
      ready_at: deployment.ready_at || ready_at(settled, now),
      expires_at: settled.expires_at || deployment.expires_at
    }
  end

  defp release(authority, project_id, deployment, reason) do
    with {:ok, policy} <- PreviewAdapter.authorize(project_id, deployment.path),
         {:ok, requested} <- enqueue_cleanup(authority, project_id, deployment) do
      command = cleanup_command(requested, policy, reason)

      record_cleanup(
        authority,
        project_id,
        requested,
        cleanup_state(PreviewAdapter.cleanup(policy, command))
      )
    end
  end

  # The command becomes durable before the provider is contacted. A crash
  # between the two leaves a deployment that plainly still owes a release rather
  # than one that silently never got it.
  defp enqueue_cleanup(_authority, _project_id, %PreviewDeployment{cleanup_state: state} = held)
       when state != "none",
       do: {:ok, held}

  defp enqueue_cleanup(authority, project_id, deployment) do
    case write(authority, project_id, [
           {:deployment,
            {:record_preview_cleanup, deployment,
             %{cleanup_state: "requested", cleanup_command_id: cleanup_command_id(deployment)}}}
         ]) do
      {:ok, %{deployment: requested}} -> {:ok, requested}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_command_id(%PreviewDeployment{id: id}), do: "preview-cleanup:" <> id

  defp cleanup_command(deployment, policy, reason) do
    %{
      command_id: deployment.cleanup_command_id,
      request_key: PreviewAdapter.request_key(deployment),
      provider: policy.provider,
      provider_ref: deployment.provider_ref,
      reason: Atom.to_string(reason)
    }
  end

  defp cleanup_state(:ok), do: "done"
  defp cleanup_state({:error, _reason}), do: "failed"

  defp record_cleanup(authority, project_id, deployment, state) do
    write(authority, project_id, [
      {:deployment,
       {:record_preview_cleanup, deployment,
        %{cleanup_state: state, cleanup_command_id: deployment.cleanup_command_id}}}
    ])
  end

  defp activity_attrs(run, verified, attrs) do
    %{
      project_id: run.project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: verified.attempt_id,
      actor_kind: "system",
      type: @activity_type,
      payload: payload(attrs)
    }
  end

  defp observed_activity(deployment, attrs) do
    %{
      project_id: deployment.project_id,
      feature_id: deployment.feature_id,
      run_id: deployment.run_id,
      attempt_id: deployment.attempt_id,
      actor_kind: "system",
      type: @activity_type,
      payload:
        deployment
        |> Map.from_struct()
        |> Map.merge(attrs)
        |> payload()
    }
  end

  # A minimized projection: what the preview is doing, where the commit came
  # from, and the one safe link when there is one. Nothing the provider said in
  # its own words reaches a stored payload.
  defp payload(attrs) do
    %{
      "status" => attrs.status,
      "path" => attrs.path,
      "provider" => attrs.provider,
      "provider_ref" => attrs.provider_ref,
      "link" => attrs.link,
      "branch" => attrs.branch,
      "commit_sha" => attrs.commit_sha,
      "failure_reason" => attrs.failure_reason,
      "expires_at" => attrs.expires_at && DateTime.to_iso8601(attrs.expires_at)
    }
  end

  defp write(authority, project_id, steps) do
    case DeliveryStore.commit(authority, project_id, steps) do
      {:ok, results} ->
        {:ok,
         %{
           deployment: results.deployment,
           activity: Map.get(results, :activity),
           changed?: true
         }}

      {:error, _step, reason} ->
        {:error, reason}
    end
  end
end
