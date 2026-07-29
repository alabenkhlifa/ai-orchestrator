defmodule SddOrchestrator.Delivery.ScreenshotEvidence do
  @moduledoc """
  Whether a screenshot applies at all, decided by the capture step that ran.

  Applicability is reported by the worker as one typed capture result —
  `captured`, `inapplicable`, `unsupported`, or `failed` — and never by a
  per-feature flag, a project-wide setting, or an agent's account of its own
  work. An agent that could declare its own work non-visual could excuse itself
  from the proof the requirement exists to demand, and a flag set long before
  the run cannot tell a visual feature from a backend-only one beside it.

  Absence is therefore an explicit typed record rather than silence. Each
  reported result maps onto one of the outcomes the `evidence` table already
  holds, so a reader can tell "nothing to capture" (`missing`) from "capture was
  not possible" (`unsupported`) from "capture broke" (`failed`), and none of the
  three can be mistaken for a screenshot nobody bothered to take.

  What this module exists to refuse is the fourth case. A `captured` result is
  believed only when the bytes it names are actually held by that project's own
  artifact store, address the digest the record declares, and agree with it
  about redaction — and only when the worker currently attached negotiated the
  capture capability at all. Each of those is refused outright rather than
  quietly downgraded to an absence, because a weakened claim is the invented
  evidence this rule forbids. The store check is the durable one: the bytes had
  to survive an authenticated upload before the event naming them ever arrived,
  so it cannot be satisfied by describing a capture that never happened.
  """

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact
  alias SddOrchestrator.Delivery.CommandTransport.Channel
  alias SddOrchestrator.Delivery.Evidence

  # The one evidence kind this module owns. Every other kind passes through
  # untouched, so the check path keeps the rules it already had.
  @kind "screenshot"

  # The optional capability a worker has to have negotiated before a capture it
  # reports can be believed.
  @capability "evidence.screenshot"

  @capture_results ~w(captured inapplicable unsupported failed)

  # Reported result to recorded outcome. No new outcome value is introduced:
  # the table's four are exactly the four states a reader has to tell apart.
  @outcomes %{
    "captured" => "passed",
    "inapplicable" => "missing",
    "unsupported" => "unsupported",
    "failed" => "failed"
  }

  # The typed reason an absence carries, derived from the recorded outcome so it
  # cannot drift from it and cannot be narrated into something else.
  @reasons %{
    "missing" => "no_visual_result",
    "unsupported" => "capture_unsupported",
    "failed" => "capture_failed"
  }

  @type authority :: ArtifactStore.authority()

  @type error ::
          :invalid_capture_result
          | :capture_commit_required
          | :artifact_missing
          | :digest_mismatch
          | :redaction_mismatch
          | :capture_unsupported_by_worker
          | :unexpected_artifact
          | :capture_reason_required

  @doc "The evidence kind whose applicability this module decides."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "The optional worker capability a believable capture requires."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The typed results a capture step may report."
  @spec capture_results() :: [String.t()]
  def capture_results, do: @capture_results

  @doc "The outcome one reported capture result records, if it is a known one."
  @spec outcome_for(String.t()) :: String.t() | nil
  def outcome_for(capture_result), do: Map.get(@outcomes, capture_result)

  @doc """
  Binds one `screenshot` evidence event to the capture result it reports.

  The reported result decides the recorded outcome, so the two can never
  disagree in the stored row. Attributes for every other kind are returned
  unchanged, which is what keeps this a decision about screenshots rather than
  a second gate on required checks.
  """
  @spec bind(authority(), Ecto.UUID.t(), map(), map()) :: {:ok, map()} | {:error, error()}
  def bind(authority, project_id, %{kind: @kind} = attrs, payload) do
    with {:ok, capture_result} <- capture_result(payload),
         attrs = Map.put(attrs, :outcome, Map.fetch!(@outcomes, capture_result)),
         :ok <- applicable?(authority, project_id, capture_result, attrs) do
      {:ok, attrs}
    end
  end

  def bind(_authority, _project_id, attrs, _payload), do: {:ok, attrs}

  @doc """
  The typed metadata a reader needs in order to judge one screenshot result.

  There is deliberately no URL, no artifact reference, and no byte here. The
  bytes of a stored capture reach a person only through an authorized fetch
  against the project's own storage authority, so presentation reports that an
  artifact is available and what it is, never how to reach it.

  Availability is read now rather than assumed from the outcome: a capture
  proved at ingestion can still have been removed by retention or erasure
  afterwards, and a reader must see that instead of a broken promise.
  """
  @spec presentation(authority(), Evidence.t()) :: map() | nil
  def presentation(authority, %Evidence{kind: @kind} = evidence) do
    artifact = stored(authority, evidence)

    %{
      evidence_id: evidence.id,
      kind: @kind,
      name: evidence.name,
      outcome: evidence.outcome,
      capture_result: reported_result(evidence.outcome),
      reason: Map.get(@reasons, evidence.outcome),
      artifact_available?: not is_nil(artifact),
      content_type: artifact && artifact.content_type,
      byte_size: artifact && artifact.byte_size,
      redacted: evidence.redacted,
      digest: evidence.digest,
      branch: evidence.branch,
      commit_sha: evidence.commit_sha,
      attempt_id: evidence.attempt_id,
      recorded_at: evidence.recorded_at,
      capture_command: evidence.command,
      exit_code: evidence.exit_code,
      superseded?: not Evidence.current?(evidence)
    }
  end

  def presentation(_authority, %Evidence{}), do: nil

  defp capture_result(payload) when is_map(payload) do
    case Map.get(payload, "capture_result") do
      result when result in @capture_results -> {:ok, result}
      _unreported -> {:error, :invalid_capture_result}
    end
  end

  defp capture_result(_payload), do: {:error, :invalid_capture_result}

  # A believed capture has to survive every one of these. None of them is a
  # judgement about the picture; each is a fact about state that already exists
  # independently of this event.
  defp applicable?(authority, project_id, "captured", attrs) do
    with :ok <- commit_named?(attrs),
         {:ok, artifact} <- stored_artifact(authority, project_id, attrs),
         :ok <- digest_agrees?(artifact, attrs),
         :ok <- redaction_agrees?(artifact, attrs) do
      capable_worker?(project_id)
    end
  end

  # An absence claim must not smuggle content. Whatever the reported reason, a
  # result that says there is no screenshot cannot also name one.
  defp applicable?(_authority, _project_id, capture_result, attrs) do
    case no_artifact?(attrs) do
      :ok -> reason_given?(capture_result, attrs)
      {:error, _reason} = refusal -> refusal
    end
  end

  # The commit is what makes a screenshot proof of anything: a picture with no
  # commit behind it cannot be checked against the work offered for review.
  defp commit_named?(%{commit_sha: commit_sha})
       when is_binary(commit_sha) and byte_size(commit_sha) > 0,
       do: :ok

  defp commit_named?(_attrs), do: {:error, :capture_commit_required}

  # The durable gate. The bytes had to pass an authenticated upload into this
  # project's own store before this event could name them, so a capture that
  # never happened has nothing to point at.
  defp stored_artifact(authority, project_id, %{artifact_ref: ref}) when is_binary(ref) do
    case ArtifactStore.stat(authority, project_id, ref) do
      {:ok, %Artifact{} = artifact} -> {:ok, artifact}
      {:error, :not_found} -> {:error, :artifact_missing}
    end
  end

  defp stored_artifact(_authority, _project_id, _attrs), do: {:error, :artifact_missing}

  # The reference addresses a digest, and the record declares one. A record that
  # declares a different digest describes bytes other than the ones stored.
  defp digest_agrees?(%Artifact{digest: digest}, %{digest: digest}), do: :ok
  defp digest_agrees?(_artifact, _attrs), do: {:error, :digest_mismatch}

  # Redaction is a privacy claim about the same bytes twice. A row saying a
  # capture was redacted while the artifact says it was not is refused rather
  # than resolved in either direction.
  defp redaction_agrees?(%Artifact{redacted: redacted}, attrs) do
    if redacted == (Map.get(attrs, :redacted) || false),
      do: :ok,
      else: {:error, :redaction_mismatch}
  end

  # A worker that never negotiated the capture capability cannot have taken a
  # meaningful screenshot, so its claim to have done so is refused. When no
  # worker is attached at all there is no contract to read and nothing to refuse
  # on: the artifact already had to survive an upload, and that proof stands on
  # its own.
  defp capable_worker?(project_id) do
    case Channel.attached(project_id) do
      [] -> :ok
      workers -> capability_negotiated?(workers)
    end
  end

  defp capability_negotiated?(workers) do
    if Enum.any?(workers, fn {_pid, contract} ->
         @capability in Map.get(contract, :capabilities, [])
       end),
       do: :ok,
       else: {:error, :capture_unsupported_by_worker}
  end

  defp no_artifact?(%{artifact_ref: nil}), do: :ok
  defp no_artifact?(_attrs), do: {:error, :unexpected_artifact}

  # A capture that broke has to say what it ran. "It failed" with nothing behind
  # it is the narrative this whole path exists to keep out of the record, so the
  # bounded capture command is required and the shared command limit bounds it.
  defp reason_given?("failed", %{command: command})
       when is_binary(command) and byte_size(command) > 0,
       do: :ok

  defp reason_given?("failed", _attrs), do: {:error, :capture_reason_required}
  defp reason_given?(_capture_result, _attrs), do: :ok

  defp stored(authority, %Evidence{artifact_ref: ref, project_id: project_id})
       when is_binary(ref) do
    case ArtifactStore.stat(authority, project_id, ref) do
      {:ok, %Artifact{} = artifact} -> artifact
      {:error, :not_found} -> nil
    end
  end

  defp stored(_authority, _evidence), do: nil

  defp reported_result(outcome) do
    Enum.find_value(@outcomes, fn {result, mapped} -> mapped == outcome && result end)
  end
end
