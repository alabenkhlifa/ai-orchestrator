defmodule SddOrchestrator.Delivery.Answers do
  @moduledoc """
  Accepting the answer to a blocking question and resuming the same run.

  The order here is the contract, not an implementation detail. The accepted
  answer is appended to the shared specification store *first*, under
  expected-head concurrency, and only a committed revision may resume anything.
  An answer that loses that race resumes nothing at all — otherwise a run would
  continue against an agreement the product never actually recorded, which is
  the exact failure the write-back exists to prevent.

  What resumes is the same run, on the same branch, in the same workspace.
  Only three things move: the attempt number, the fence token, and the
  effective revision. That is what lets accepted work survive a pause instead
  of being repeated, and what makes the older worker's fence useless the moment
  the next attempt exists.

  Nothing here depends on a live provider thread. The next attempt is
  reconstructable from its manifest, the accepted revision, and the preserved
  checkpoint alone, so a thread lost while a human was thinking costs nothing.
  """

  alias SddOrchestrator.Delivery.{
    Blocking,
    BlockingQuestion,
    DeliveryStore,
    ExecutionManifest,
    ExecutionProfile,
    QuestionRouting
  }

  alias SddOrchestrator.SpecificationStore

  @type authority :: DeliveryStore.authority()

  @type error ::
          :unauthorized
          | :no_open_question
          | :question_mismatch
          | :empty_answer
          | :answer_too_long
          | :no_specification
          | :revision_conflict
          | :unknown_run
          | :no_execution_profile
          | term()

  @max_answer_bytes 8_000

  @spec max_answer_bytes() :: pos_integer()
  def max_answer_bytes, do: @max_answer_bytes

  @doc """
  Records the accepted answer and continues the run it unblocked.

  Only the question's current responder may answer. Responsibility is resolved
  at this moment, so an answer from whoever was responsible yesterday is
  refused.
  """
  @spec accept(authority(), QuestionRouting.actor(), map(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def accept(
        authority,
        actor,
        %{project: project, feature: feature},
        question_id,
        answer,
        opts \\ []
      ) do
    with {:ok, member} <- QuestionRouting.authorize_answer(project.id, actor, feature),
         {:ok, text} <- validate(answer),
         {:ok, question} <- open_question(actor, project, feature, question_id),
         {:ok, run} <- fetch_run(authority, project, question),
         {:ok, attempt} <- current_attempt(authority, project, run),
         {:ok, revision} <- append_answer(authority, project, feature, question, text, member),
         {:ok, manifest} <-
           next_manifest(authority, project, feature, run, attempt, revision, opts) do
      resume(%{
        authority: authority,
        project: project,
        feature: feature,
        run: run,
        attempt: attempt,
        question: question,
        manifest: manifest,
        revision: revision,
        member: member,
        opts: opts
      })
    end
  end

  @doc "The open question a responder may answer right now, if there is one."
  @spec pending(authority(), QuestionRouting.actor(), map()) ::
          {:ok, BlockingQuestion.t() | nil} | {:error, :unauthorized}
  def pending(_authority, actor, %{project: project, feature: feature}),
    do: Blocking.for_feature(project.id, actor, feature.id)

  # The append is deliberately outside the resume transaction. The shared
  # specification store is a separate authority with its own concurrency rule,
  # and a distributed transaction across the two is exactly what the storage
  # design forbids. Appending first means the worst case is a recorded decision
  # whose resume failed — recoverable — rather than a run continuing against an
  # agreement that was never written.
  defp append_answer(authority, project, feature, question, text, member) do
    with {:ok, %{specifications: [entry | _rest]}} <-
           SpecificationStore.current_snapshot(authority, project.id),
         {:ok, current} <- SpecificationStore.get_current(authority, project.id, entry.id),
         {:ok, appended} <-
           SpecificationStore.append_revision(
             authority,
             project.id,
             entry.id,
             current.revision.id,
             %{
               revision_id: Ecto.UUID.generate(),
               documents: answered_documents(current, feature, question, text),
               actor_ref: member.account_id
             }
           ) do
      {:ok, appended.revision}
    else
      {:error, _reason} -> {:error, :revision_conflict}
      _unavailable -> {:error, :no_specification}
    end
  end

  # The answer becomes part of the requirements, because that is what makes it
  # durable and reviewable. The design and tasks documents are carried forward
  # unchanged: an answer resolves a product question, not a technical plan.
  defp answered_documents(current, feature, question, text) do
    %{
      requirements:
        current.revision.requirements_document <>
          "\n\n## Decision: #{feature.title}\n\n" <>
          "Question: #{question.question}\n\nAnswer: #{text}\n",
      design: current.revision.design_document,
      tasks: current.revision.tasks_document
    }
  end

  defp resume(%{authority: authority, project: project, revision: revision} = context) do
    context
    |> Map.put(:digest, ExecutionManifest.digest(context.manifest))
    |> then(&DeliveryStore.commit(authority, project.id, steps(&1)))
    |> case do
      {:ok, results} -> {:ok, Map.put(results, :revision, revision)}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # Seven records, seven steps, each written exactly once. The superseded
  # attempt and the new attempt are different records, which is what lets the
  # one-current-attempt index accept the insert.
  defp steps(%{
         project: project,
         feature: feature,
         run: run,
         attempt: attempt,
         question: question,
         manifest: manifest,
         revision: revision,
         member: member,
         digest: digest,
         opts: opts
       }) do
    [
      {:superseded, {:transition_attempt, attempt, "superseded"}},
      {:question, {:resolve_question, question, "answered", revision.id}},
      {:run, {:resume_run, run, revision.id, revision.content_digest, manifest.attempt_number}},
      {:feature, {:set_feature_status, feature, "none"}},
      {:attempt,
       {:insert_attempt,
        %{
          run_id: run.id,
          attempt_number: manifest.attempt_number,
          continuation_reason: "blocking_answer",
          effective_revision_id: revision.id,
          effective_revision_digest: revision.content_digest,
          manifest_digest: digest,
          required_checks: manifest.required_checks,
          fence_token: attempt.fence_token + 1
        }}},
      {:activity,
       {:append_activity,
        %{
          project_id: project.id,
          feature_id: feature.id,
          run_id: run.id,
          attempt_id: {:ref, :attempt, :id},
          actor_kind: "participant",
          actor_account_id: member.account_id,
          type: "question_answered",
          payload: %{
            "operation_key" => "answer:#{question.id}",
            "question_id" => question.id,
            "revision_id" => revision.id,
            "attempt_number" => manifest.attempt_number
          }
        }}},
      {:command,
       {:enqueue_command,
        %{
          id: Keyword.get(opts, :command_id, Ecto.UUID.generate()),
          project_id: project.id,
          run_id: run.id,
          attempt_id: {:ref, :attempt, :id},
          operation: "resume",
          expected_state_version: run.state_version,
          manifest_digest: digest
        }}}
    ]
  end

  # The branch comes from the run and the execution contract comes from the
  # profile the repository's owner approved, never from the answer, so a
  # resumed attempt cannot be pointed at a branch or a check the run does not
  # own.
  defp next_manifest(authority, project, feature, run, attempt, revision, opts) do
    with {:ok, profile_fields} <- ExecutionProfile.manifest_fields(authority, project.id) do
      %{
        "manifest_version" => ExecutionManifest.manifest_version(),
        "project_id" => project.id,
        "feature_id" => feature.id,
        "run_id" => run.id,
        "attempt_number" => attempt.attempt_number + 1,
        "approved_slice" => run.approved_slice,
        "starting_revision_id" => run.starting_revision_id,
        "starting_revision_digest" => run.starting_revision_digest,
        "effective_revision_id" => revision.id,
        "effective_revision_digest" => revision.content_digest,
        "target_branch" => run.branch,
        "agent_ref" => Keyword.get(opts, :agent_ref, %{}),
        "worker_ref" => Keyword.get(opts, :worker_ref, %{}),
        "continuation" => %{
          "reason" => "blocking_answer",
          "prior_attempt_number" => attempt.attempt_number
        }
      }
      |> Map.merge(profile_fields)
      |> ExecutionManifest.new()
    end
  end

  # The caller names the question it is answering, so an answer written against
  # a question that has since been resolved or superseded is refused rather
  # than silently applied to whatever is open now.
  defp open_question(actor, project, feature, question_id) do
    case Blocking.for_feature(project.id, actor, feature.id) do
      {:ok, %BlockingQuestion{id: ^question_id} = question} -> {:ok, question}
      {:ok, %BlockingQuestion{}} -> {:error, :question_mismatch}
      {:ok, nil} -> {:error, :no_open_question}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp fetch_run(authority, project, question) do
    case DeliveryStore.fetch_run(authority, project.id, question.run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, :unknown_run}
    end
  end

  defp current_attempt(authority, project, run) do
    case DeliveryStore.current_attempt(authority, project.id, run.id) do
      {:ok, attempt} -> {:ok, attempt}
      :error -> {:error, :no_current_attempt}
    end
  end

  defp validate(answer) when is_binary(answer) do
    trimmed = String.trim(answer)

    cond do
      trimmed == "" -> {:error, :empty_answer}
      byte_size(trimmed) > @max_answer_bytes -> {:error, :answer_too_long}
      true -> {:ok, trimmed}
    end
  end

  defp validate(_answer), do: {:error, :empty_answer}
end
