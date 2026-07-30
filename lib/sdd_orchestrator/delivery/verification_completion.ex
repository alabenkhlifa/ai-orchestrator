defmodule SddOrchestrator.Delivery.VerificationCompletion.Verdict do
  @moduledoc """
  What the completion gate concluded about one commit offered for review.

  The conclusion is a value rather than an effect, so what the control plane
  decided can be proven without letting it move anything. A refusal is not a
  bare `false`: it carries the machine-readable reason and the exact check names
  behind it, because the requirement is that missing or failed evidence stays
  visible rather than collapsing into "not verified".
  """

  @type outcome :: :verified | :refused

  @type reason ::
          :required_check_contract_unknown
          | :commit_identity_missing
          | :branch_identity_missing
          | :branch_mismatch
          | :revision_identity_missing
          | :revision_mismatch
          | :required_check_failed
          | :required_check_unsupported
          | :required_check_missing
          | :screenshot_capture_failed

  @type t :: %__MODULE__{
          outcome: outcome(),
          reason: reason() | nil,
          run_id: Ecto.UUID.t() | nil,
          attempt_id: Ecto.UUID.t() | nil,
          attempt_number: pos_integer() | nil,
          branch: String.t() | nil,
          revision_id: String.t() | nil,
          commit_sha: String.t() | nil,
          required: [String.t()],
          passed: [String.t()],
          failed: [String.t()],
          missing: [String.t()],
          unsupported: [String.t()],
          screenshots_failed: [String.t()]
        }

  defstruct outcome: :refused,
            reason: nil,
            run_id: nil,
            attempt_id: nil,
            attempt_number: nil,
            branch: nil,
            revision_id: nil,
            commit_sha: nil,
            required: [],
            passed: [],
            failed: [],
            missing: [],
            unsupported: [],
            screenshots_failed: []

  # What one activity payload may carry of a check list. The payload is bounded
  # at 4 KB and a configured check name may be far longer than a screen line, so
  # names are capped rather than trusted to fit. The count is always exact, and
  # the cut is by character rather than by byte so a truncated name is still
  # text a reader and a JSON encoder can both handle.
  @max_listed_names 5
  @max_name_characters 40

  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{outcome: :verified}), do: true
  def verified?(%__MODULE__{}), do: false

  @doc """
  The minimized projection one activity entry records.

  Counts are exact and names are bounded, so a reader can always tell how much
  was required from how much was proved even when the names are long. Nothing
  here is command output: what a check printed belongs to the private artifact
  its evidence digest addresses.
  """
  @spec payload(t()) :: map()
  def payload(%__MODULE__{} = verdict) do
    %{
      "outcome" => Atom.to_string(verdict.outcome),
      "reason" => verdict.reason && Atom.to_string(verdict.reason),
      "branch" => verdict.branch,
      "revision_id" => verdict.revision_id,
      "commit_sha" => verdict.commit_sha,
      "attempt_number" => verdict.attempt_number,
      "required_count" => length(verdict.required),
      "passed_count" => length(verdict.passed),
      "failed" => names(verdict.failed),
      "missing" => names(verdict.missing),
      "unsupported" => names(verdict.unsupported),
      "screenshot_failed" => names(verdict.screenshots_failed)
    }
  end

  defp names(list) do
    list
    |> Enum.take(@max_listed_names)
    |> Enum.map(&readable_name/1)
  end

  defp readable_name(name) when is_binary(name), do: String.slice(name, 0, @max_name_characters)
  defp readable_name(_unnamed), do: "(unnamed)"
end

defmodule SddOrchestrator.Delivery.VerificationCompletion do
  @moduledoc """
  Whether one attempt may claim success for the exact commit offered for review.

  A worker saying it finished proves nothing. What is checked here is that every
  check the attempt was *contractually* required to run has a current, passing,
  command-derived result recorded against that one commit, on the run's own
  branch, at the attempt's own effective revision. Anything short of that is
  refused, and the refusal names what was failing or absent.

  The contract is the attempt's own snapshot, taken from the manifest that bound
  it. Reading today's project configuration instead would let a check added or
  removed mid-run silently change what an already-finished attempt had to prove.
  An empty or absent snapshot is therefore *unknown*, never "nothing was
  required": a gate with nothing to check must refuse rather than pass, which is
  the entire difference between proof and an unsupported completion message.

  Results do not carry forward. Evidence belongs to one commit, so a later
  commit invalidates everything proved about the earlier one until the checks
  rerun — the point of binding a completion claim to an exact revision is that
  the thing reviewed is the thing that was proved. Superseded items never count
  either; the item that replaced one is what gets evaluated.

  Screenshots are conditional and stay conditional. A capture that *failed*
  refuses completion, because a broken capture is an unanswered question. An
  absent visual result and an environment that cannot capture do not, because
  requiring a screenshot universally is exactly what the requirement forbids.
  What each screenshot means was already decided by `ScreenshotEvidence` when it
  was recorded, and is read here rather than derived a second time.

  This module answers; it does not hand the feature to a reviewer. Moving work
  to `Ready for review` belongs to the handoff that consumes this verdict, so a
  verified completion is recorded as one ordered activity entry and nothing
  else. A refusal is recorded too — a worker that claims completion it has not
  earned leaves a visible trace rather than a silent no-op.
  """

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    DeliveryStore,
    EventIngestion,
    Evidence,
    EvidenceIngestion,
    RunAttempt,
    ScreenshotEvidence
  }

  alias SddOrchestrator.Delivery.VerificationCompletion.Verdict

  @type authority :: DeliveryStore.authority()

  @type error :: EventIngestion.error()

  # The event type this task owns. `EventIngestion` refuses it, which is what
  # keeps one owner per transition.
  @event_type "verification_completed"

  # The evidence kind a required check records. A screenshot and a preview are
  # different kinds and can never stand in for one.
  @required_check_kind "required_check"

  @verified_activity "verification_completed"
  @refused_activity "verification_refused"

  @spec event_type() :: String.t()
  def event_type, do: @event_type

  @spec verified_activity_type() :: String.t()
  def verified_activity_type, do: @verified_activity

  @spec refused_activity_type() :: String.t()
  def refused_activity_type, do: @refused_activity

  @doc """
  Applies one validated `verification_completed` worker event.

  The event earns nothing by arriving: `EventIngestion` proves the protocol
  schema, the current fence, and the attempt's sequence first, so a superseded
  worker can keep announcing success and change nothing. An event whose own
  identifier is already in the feature's history is answered with what it
  produced the first time rather than applied twice.
  """
  @spec ingest(authority(), Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, error()}
  def ingest(authority, project_id, envelope) do
    with {:ok, %{run: run, attempt: attempt}} <-
           EventIngestion.accept(authority, project_id, envelope, [@event_type]) do
      case recorded(authority, project_id, run.feature_id, envelope["event_id"]) do
        {:ok, entry} -> {:ok, %{applied?: false, activity: entry}}
        :error -> apply_verdict(authority, project_id, run, attempt, envelope)
      end
    end
  end

  @doc """
  Judges one completion claim without applying anything.

  `claim` is the worker's own account of what it finished: the branch, the
  effective revision, and the exact commit. Every one of them is checked against
  what the run and attempt actually own, because an identity a worker supplies
  is a claim rather than a fact.
  """
  @spec evaluate(authority(), Ecto.UUID.t(), AgentRun.t(), RunAttempt.t(), map()) :: Verdict.t()
  def evaluate(authority, project_id, %AgentRun{} = run, %RunAttempt{} = attempt, claim) do
    contract = attempt.required_checks || []

    verdict = %Verdict{
      run_id: run.id,
      attempt_id: attempt.id,
      attempt_number: attempt.attempt_number,
      branch: claim[:branch],
      revision_id: claim[:revision_id],
      commit_sha: claim[:commit_sha],
      required: Enum.map(contract, &check_name/1)
    }

    case identity_refusal(run, attempt, claim, contract) do
      nil -> against_evidence(authority, project_id, run, verdict, claim[:commit_sha])
      reason -> %{verdict | outcome: :refused, reason: reason}
    end
  end

  @doc """
  The verified completion recorded for one run, when there is one.

  The handoff to human review consumes this rather than re-deriving the verdict,
  so what a reviewer is offered is the same conclusion the history shows.
  """
  @spec verified_completion(authority(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ActivityEntry.t()} | :error
  def verified_completion(authority, project_id, feature_id, run_id) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.filter(&(&1.type == @verified_activity and &1.run_id == run_id))
    |> List.last()
    |> case do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  # A missing or mismatched identity is checked before any evidence is read.
  # Proof for a commit nobody can locate on a branch the run does not own is not
  # weaker proof; it is proof of something else.
  defp identity_refusal(run, attempt, claim, contract) do
    cond do
      contract == [] -> :required_check_contract_unknown
      blank?(claim[:commit_sha]) -> :commit_identity_missing
      blank?(claim[:branch]) -> :branch_identity_missing
      claim[:branch] != run.branch -> :branch_mismatch
      blank?(claim[:revision_id]) -> :revision_identity_missing
      claim[:revision_id] != attempt.effective_revision_id -> :revision_mismatch
      true -> nil
    end
  end

  defp against_evidence(authority, project_id, run, verdict, commit_sha) do
    evidence =
      authority
      |> EvidenceIngestion.current_for_commit(project_id, run.id, commit_sha)
      |> Enum.filter(&(&1.branch == run.branch))

    verdict
    |> classify_checks(evidence)
    |> classify_screenshots(evidence)
    |> conclude()
  end

  # Every required name is looked up rather than every result being counted, so
  # a check the contract never named cannot make up for one it did. A name with
  # no current result at all lands in `missing` beside one that reported nothing
  # to prove: both mean the same thing to a reader deciding whether to trust the
  # claim, and neither may be mistaken for a pass.
  defp classify_checks(verdict, evidence) do
    results = Map.new(check_results(evidence), &{&1.name, &1.outcome})

    Enum.reduce(verdict.required, verdict, fn name, acc ->
      case Map.get(results, name) do
        "passed" -> %{acc | passed: acc.passed ++ [name]}
        "failed" -> %{acc | failed: acc.failed ++ [name]}
        "unsupported" -> %{acc | unsupported: acc.unsupported ++ [name]}
        _absent_or_missing -> %{acc | missing: acc.missing ++ [name]}
      end
    end)
  end

  defp check_results(evidence), do: Enum.filter(evidence, &(&1.kind == @required_check_kind))

  # Applicability is read, never re-derived: `ScreenshotEvidence` already turned
  # the reported capture result into the recorded outcome, and deciding it twice
  # is how the two answers start to disagree.
  defp classify_screenshots(verdict, evidence) do
    failed =
      evidence
      |> Enum.filter(&screenshot_failure?/1)
      |> Enum.map(& &1.name)

    %{verdict | screenshots_failed: failed}
  end

  defp screenshot_failure?(%Evidence{kind: kind, outcome: "failed"}),
    do: kind == ScreenshotEvidence.kind()

  defp screenshot_failure?(%Evidence{}), do: false

  # A failure is louder than an absence, and an absence is louder than an
  # environment that could not run the check, so the reason a reader sees first
  # is the one that most needs answering.
  defp conclude(verdict) do
    cond do
      verdict.failed != [] -> refuse(verdict, :required_check_failed)
      verdict.missing != [] -> refuse(verdict, :required_check_missing)
      verdict.unsupported != [] -> refuse(verdict, :required_check_unsupported)
      verdict.screenshots_failed != [] -> refuse(verdict, :screenshot_capture_failed)
      true -> %{verdict | outcome: :verified, reason: nil}
    end
  end

  defp refuse(verdict, reason), do: %{verdict | outcome: :refused, reason: reason}

  defp apply_verdict(authority, project_id, run, attempt, envelope) do
    verdict = evaluate(authority, project_id, run, attempt, claim(envelope))

    authority
    |> DeliveryStore.commit(project_id, steps(run, attempt, verdict, envelope))
    |> case do
      {:ok, results} -> {:ok, results |> Map.put(:applied?, true) |> Map.put(:verdict, verdict)}
      {:error, _step, reason} -> {:error, reason}
    end
  end

  # Two records, two steps, each written exactly once. A second write to either
  # in one commit would be offered against the version its sibling just bumped
  # and rejected as stale. The run and the feature are deliberately untouched:
  # a refusal must change no completion state, and the move to human review is
  # not this module's to make.
  defp steps(run, attempt, verdict, envelope) do
    [
      {:attempt, {:observe_sequence, attempt, envelope["sequence"]}},
      {:activity,
       {:append_activity,
        %{
          project_id: run.project_id,
          feature_id: run.feature_id,
          run_id: run.id,
          attempt_id: attempt.id,
          actor_kind: "agent",
          type: activity_type(verdict),
          payload:
            verdict
            |> Verdict.payload()
            |> Map.put("operation_key", envelope["event_id"])
        }}}
    ]
  end

  defp activity_type(verdict) do
    if Verdict.verified?(verdict), do: @verified_activity, else: @refused_activity
  end

  # The worker names what it believes it finished. None of it is trusted; all of
  # it is compared against what the run and attempt already own.
  defp claim(envelope) do
    payload = Map.get(envelope, "payload", %{})

    %{
      branch: payload["branch"],
      revision_id: payload["revision_id"],
      commit_sha: payload["commit_sha"]
    }
  end

  defp check_name(check) when is_map(check), do: Map.get(check, "name")
  defp check_name(_check), do: nil

  defp blank?(value), do: not (is_binary(value) and value != "")

  defp recorded(authority, project_id, feature_id, operation_key) do
    authority
    |> DeliveryStore.list_activity(project_id, feature_id, limit: 200)
    |> Enum.find(&(&1.payload["operation_key"] == operation_key))
    |> case do
      nil -> :error
      entry -> {:ok, entry}
    end
  end
end
