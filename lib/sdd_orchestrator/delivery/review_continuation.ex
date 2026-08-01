defmodule SddOrchestrator.Delivery.ReviewContinuation do
  @moduledoc """
  What a rejected review does to the run that produced the work.

  A rejection is not a new run. The branch, the workspace, and everything the
  earlier attempts proved stay exactly where they are, and only the attempt
  ordering and the fence move forward. That is the same promise a retry and an
  accepted blocking answer already make, for the same reason: sending work back
  must not cost the run the context it accumulated, or every rejection would be
  paid for twice.

  What leaves here is a plan rather than a transaction. `Review` owns the verdict
  record, and the continuation has to land in the same commit as that verdict:
  two commits would strand a rejected feature in `Ready for review` whenever the
  second one never ran, and a crash would make that permanent. So this module
  contributes steps and payload, and the caller commits them once.

  Whether the feedback changes the approved product agreement is the reviewer's
  own declaration, never an inference drawn from the text. An agent deciding what
  the agreement means is precisely what the specification write-back exists to
  prevent. A declared contradiction therefore opens a blocking question, pauses
  the run, and enqueues nothing: no attempt may start against a manifest the
  agreement no longer supports. The current attempt is deliberately left current,
  because that is what lets an accepted answer resume this run rather than
  needing a new one.

  Nothing a reviewer writes reaches the manifest. The branch, the worker, and the
  agent are read from the run and the configured execution boundary, so feedback
  cannot steer the next attempt onto a different branch or a different worker.
  """

  alias SddOrchestrator.Delivery.{
    AgentRun,
    BlockingQuestion,
    DeliveryStore,
    ExecutionManifest,
    Feature,
    RunAttempt,
    Start
  }

  alias SddOrchestrator.Delivery.Worker.Workspace

  @type authority :: DeliveryStore.authority()

  @type request :: %{
          required(:feature) => Feature.t(),
          required(:run) => AgentRun.t(),
          required(:attempt) => RunAttempt.t(),
          required(:feedback) => String.t(),
          required(:contradicts_agreement?) => boolean(),
          optional(:opts) => keyword()
        }

  @type plan :: %{
          records: [DeliveryStore.step()],
          commands: [DeliveryStore.step()],
          payload: map()
        }

  @type error ::
          :question_already_open
          | :run_not_continuable
          | Workspace.error()
          | atom()

  # The one column rejected work returns to, whichever way the rejection went.
  @column "in_development"

  @reason "review_feedback"
  @operation "resume"

  # Said once, beside the reviewer's own words, so a responder is never left
  # guessing what answering will actually do.
  @context "The reviewer reported that this feedback changes the approved product agreement. " <>
             "The answer is written back to the specification before development continues."

  @spec column() :: String.t()
  def column, do: @column

  @spec continuation_reason() :: String.t()
  def continuation_reason, do: @reason

  @doc """
  Builds the steps and payload one rejection adds to its verdict's commit.

  Returns an error rather than a partial plan when the continuation cannot be
  expressed at all, so a caller never commits half of it. A run that has already
  ended, and a run already waiting on a question of its own, are both refused by
  name: neither can be continued, and reporting that is more useful than a
  rejected changeset a caller cannot interpret.
  """
  @spec plan(authority(), request()) :: {:ok, plan()} | {:error, error()}
  def plan(authority, request) do
    request = Map.put_new(request, :opts, [])

    with {:ok, manifest} <- manifest(request.run, request.attempt, request.opts) do
      if request.contradicts_agreement? do
        block(authority, request, manifest)
      else
        continue(request, manifest)
      end
    end
  end

  @doc """
  The execution manifest the next attempt of a rejected run is bound to.

  Exposed because the manifest is the contract the worker replays against, so
  what it says about the branch, the continuation reason, and the attempt it
  follows has to be provable without reaching into a commit.
  """
  @spec manifest(AgentRun.t(), RunAttempt.t(), keyword()) ::
          {:ok, ExecutionManifest.t()} | {:error, atom()}
  def manifest(%AgentRun{} = run, %RunAttempt{} = attempt, opts \\ []) do
    config = Keyword.merge(Start.execution_config(), opts)

    ExecutionManifest.new(%{
      "manifest_version" => ExecutionManifest.manifest_version(),
      "project_id" => run.project_id,
      "feature_id" => run.feature_id,
      "run_id" => run.id,
      "attempt_number" => next_attempt_number(run, attempt),
      "approved_slice" => run.approved_slice,
      "starting_revision_id" => run.starting_revision_id,
      "starting_revision_digest" => run.starting_revision_digest,
      "effective_revision_id" => run.effective_revision_id,
      "effective_revision_digest" => run.effective_revision_digest,
      "repository_base_revision" => Keyword.fetch!(config, :repository_base_revision),
      "target_branch" => run.branch,
      "required_checks" => Keyword.get(config, :required_checks, []),
      "agent_ref" => Keyword.get(config, :agent_ref, %{}),
      "worker_ref" => Keyword.get(config, :worker_ref, %{}),
      "continuation" => %{
        "reason" => @reason,
        "prior_attempt_number" => attempt.attempt_number
      }
    })
  end

  # The run's own ordering wins over the attempt it was read from, so a stale
  # attempt cannot reopen a number the run has already moved past.
  defp next_attempt_number(run, attempt),
    do: max(attempt.attempt_number, run.current_attempt_number) + 1

  defp continue(request, manifest) do
    with {:ok, run_step} <- continued_run(request.run, manifest.attempt_number) do
      digest = ExecutionManifest.digest(manifest)

      {:ok,
       %{
         records:
           supersede(request.attempt) ++
             [
               run_step,
               {:feature, {:transition_feature, request.feature, @column, []}},
               {:attempt, {:insert_attempt, attempt_attrs(request, manifest, digest)}}
             ],
         commands: [command(request.run, digest, request.opts)],
         payload: %{
           "column" => @column,
           "blocked_for_specification" => false,
           "continuation_reason" => @reason,
           "attempt_number" => manifest.attempt_number
         }
       }}
    end
  end

  # A run that is already executing only needs its attempt ordering advanced: the
  # transition table has no `running` to `running` move, and offering one would
  # be rejected as an illegal transition rather than understood as a
  # continuation. A pending, blocked, or failed run genuinely restarts, which is
  # the single write `resume_run` exists for. A run that ended has nothing left
  # to continue at all, and saying so plainly beats a changeset error nobody
  # downstream can read.
  defp continued_run(%AgentRun{state: "running"} = run, attempt_number),
    do: {:ok, {:run, {:advance_attempt_number, run, attempt_number}}}

  defp continued_run(%AgentRun{state: state} = run, attempt_number) do
    if AgentRun.legal_transition?(state, "running") do
      {:ok,
       {:run,
        {:resume_run, run, run.effective_revision_id, run.effective_revision_digest,
         attempt_number}}}
    else
      {:error, :run_not_continuable}
    end
  end

  # A reviewer decides after the work stopped, so the attempt they judged is
  # usually still current and has to end before its successor can exist. One that
  # already ended is left alone: ending it twice is the stale write the
  # one-current-attempt rule would reject anyway.
  defp supersede(%RunAttempt{} = attempt) do
    if RunAttempt.current?(attempt) do
      [{:superseded, {:transition_attempt, attempt, "superseded"}}]
    else
      []
    end
  end

  defp attempt_attrs(%{run: run, attempt: attempt}, manifest, digest) do
    %{
      run_id: run.id,
      attempt_number: manifest.attempt_number,
      continuation_reason: @reason,
      effective_revision_id: run.effective_revision_id,
      effective_revision_digest: run.effective_revision_digest,
      manifest_digest: digest,
      required_checks: manifest.required_checks,
      fence_token: attempt.fence_token + 1
    }
  end

  defp command(run, digest, opts) do
    {:command,
     {:enqueue_command,
      %{
        id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
        project_id: run.project_id,
        run_id: run.id,
        attempt_id: {:ref, :attempt, :id},
        operation: @operation,
        expected_state_version: run.state_version,
        manifest_digest: digest,
        # A person is waiting on this one, so there is nothing transient to wait
        # out before it is delivered.
        due_at: Keyword.get(opts, :now, DateTime.utc_now())
      }}}
  end

  # The manifest is built even here, although nothing is dispatched, because it
  # is how the run's workspace is located: the worker derives that directory from
  # the same project and run identities, and inventing a second rule for it would
  # be inventing a second answer.
  defp block(authority, request, manifest) do
    with :ok <- no_open_question(authority, request.run),
         {:ok, workspace} <- Workspace.working_directory(manifest) do
      {:ok,
       %{
         records:
           paused_run(request.run) ++
             [
               {:feature, {:transition_feature, request.feature, @column, [status: "blocked"]}},
               {:question, {:insert_blocking_question, question_attrs(request, workspace)}}
             ],
         commands: [],
         payload: %{
           "column" => @column,
           "blocked_for_specification" => true,
           "question_id" => {:ref, :question, :id},
           "attempt_number" => request.attempt.attempt_number
         }
       }}
    end
  end

  # A run that never started executing has nothing to pause, and the transition
  # table admits `blocked` only from `running`. What a reader sees is the same
  # either way: the feature carries the `Blocked` status and the question is
  # open, so the pause is real without a state move that would be illegal.
  defp paused_run(%AgentRun{state: state} = run) do
    if AgentRun.legal_transition?(state, "blocked") do
      [{:run, {:transition_run, run, "blocked", []}}]
    else
      []
    end
  end

  # A run may hold one open question at a time. Stacking a second on top of one
  # somebody is already answering would leave two competing decisions on one run,
  # which is the state the open-question index exists to make impossible.
  defp no_open_question(authority, run) do
    case DeliveryStore.open_question(authority, run.project_id, run.id) do
      {:ok, _open} -> {:error, :question_already_open}
      :error -> :ok
    end
  end

  # The branch comes from the run, never from the feedback, so a blocked
  # continuation records the branch the work is actually on.
  defp question_attrs(%{run: run, attempt: attempt, feedback: feedback}, workspace) do
    %{
      project_id: run.project_id,
      feature_id: run.feature_id,
      run_id: run.id,
      attempt_id: attempt.id,
      question: bounded(feedback, BlockingQuestion.max_question_bytes()),
      context: @context,
      checkpoint: %{},
      branch: run.branch,
      workspace_path: workspace,
      asked_at: DateTime.utc_now()
    }
  end

  # A question is bounded more tightly than feedback is, so the longest feedback
  # a reviewer may write would otherwise be feedback no question could carry. The
  # verdict record holds the whole text and stays authoritative for it; this is
  # the part a responder reads on screen.
  defp bounded(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp bounded(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, size} ->
      grown = size + byte_size(grapheme)

      if grown > max_bytes, do: {:halt, {kept, size}}, else: {:cont, {[grapheme | kept], grown}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
