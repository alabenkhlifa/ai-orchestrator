defmodule SddOrchestrator.ProjectAssistant.FakeModelCompletionAdapter do
  @moduledoc """
  Deterministic `ModelCompletionAdapter` test double for specs/12 Task 7. No
  live model call, no network.

  Scenarios are keyed off `request.question_text`'s prefix, mirroring
  `FakeRepositoryObservationAdapter`'s `repository_ref`-keyed convention.
  Because a request always carries the already-assembled `context_content`,
  most scenarios build a claim directly from whatever the current context
  actually holds, so the same fixture proves both "a real fact resolves"
  and "a fabricated or stale fact does not" without hand-maintained ids
  drifting out of sync with the test's own fixtures:

    * `"spec-valid: "` — cites the current context's first specification
      with its exact current revision id.
    * `"spec-stale: "` — cites the current context's first specification id
      with a revision id that is not the current one.
    * `"spec-fabricated: "` — cites a specification id absent from context.
    * `"board-valid: "` — cites the current context's first board feature.
    * `"board-fabricated: "` — cites a feature id absent from context.
    * `"run-valid: "` — cites the current context's first recent run.
    * `"evidence-valid: "` — cites the current context's first accepted
      evidence item.
    * `"repository-valid: "` — cites `"lib/app.ex"` lines 1..2 (any path
      resolves against the fake repository adapter's default `lines/1`
      clause unless the paired repository fixture denies or fails it).
    * `"repository-secret: "` — cites `".env"` line 1, a configured denied
      path, to prove an inaccessible citation fails closed.
    * `"mixed: "` — one valid stored-context specification claim *and* one
      repository claim (`lib/app.ex` lines 1..2) together, so a caller can
      prove that a dropped repository claim (worker offline, or an unstable
      scan) still leaves the stored-context claim standing — AC-10's
      "worker-offline answer contains only current stored project facts."
    * `"uncited-material: "` — one material claim with no citation at all.
    * `"conflicting: "` — two valid board+spec claims plus a
      candidate-declared `:conflicting` marker.
    * `"partial: "` — one valid claim plus a candidate-declared `:partial`
      marker.
    * `"fails: " <> reason` — `{:error, String.to_existing_atom(reason)}`.
    * `"echo-question: "` — one plain, non-material claim whose text embeds
      the exact `question_text` this adapter received (specs/12 Task 9's
      own fixture addition), so a caller can prove
      `SddOrchestrator.ProjectAssistant.SecretRedactor` redacted the
      question before it became model input: whatever secret-shaped
      substring appears in the persisted answer is exactly (and only) what
      the model actually received.
    * `"repository-secret-content: "` — cites a path whose name itself
      embeds a high-confidence secret pattern (an AWS-access-key shape),
      lines 1..1 (specs/12 Task 9's own fixture addition). The default
      `lines/1` clause below echoes the path into the returned content, so
      this proves a citation excerpt is redacted even when the *path*
      itself was never denied by `RepositoryExclusions` — content-level
      redaction is a distinct boundary from path-level denial.
    * any other prefix — one plain, non-material claim with no citation.
  """
  @behaviour SddOrchestrator.ProjectAssistant.ModelCompletionAdapter

  @impl true
  def complete(%{question_text: "fails: " <> reason}),
    do: {:error, String.to_existing_atom(reason)}

  def complete(%{question_text: "echo-question: " <> _rest = received_question_text}) do
    {:ok,
     %{
       claims: [
         %{text: "You asked: #{received_question_text}", material: false, citation: nil}
       ],
       markers: []
     }}
  end

  def complete(%{question_text: "repository-secret-content: " <> _rest}) do
    claims = [
      material_claim("The repository shows this at a leaked-key path.", %{
        type: :repository,
        path: "lib/AKIAABCDEFGHIJKLMNOP.ex",
        start_line: 1,
        end_line: 1
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "spec-valid: " <> _rest, context_content: content}) do
    [entry | _rest] = content["specifications"]

    claims = [
      material_claim("The current specification is #{entry["title"]}.", %{
        type: :specification,
        specification_id: entry["id"],
        revision_id: entry["revision_id"]
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "spec-stale: " <> _rest, context_content: content}) do
    [entry | _rest] = content["specifications"]

    claims = [
      material_claim("The specification says something from an old revision.", %{
        type: :specification,
        specification_id: entry["id"],
        revision_id: "superseded-revision-id"
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "spec-fabricated: " <> _rest}) do
    claims = [
      material_claim("The specification says something invented.", %{
        type: :specification,
        specification_id: "nonexistent-specification-id",
        revision_id: "nonexistent-revision-id"
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "board-valid: " <> _rest, context_content: content}) do
    [entry | _rest] = content["board"] |> Map.values() |> List.flatten()

    claims = [
      material_claim("The feature #{entry["title"]} is on the board.", %{
        type: :board,
        feature_id: entry["id"]
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "board-fabricated: " <> _rest}) do
    claims = [
      material_claim("An invented feature is on the board.", %{
        type: :board,
        feature_id: "nonexistent-feature-id"
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "run-valid: " <> _rest, context_content: content}) do
    [entry | _rest] = content["recent_runs"]

    claims = [
      material_claim("The most recent run is in state #{entry["state"]}.", %{
        type: :run,
        run_id: entry["run_id"]
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "evidence-valid: " <> _rest, context_content: content}) do
    [entry | _rest] = content["accepted_evidence"]

    claims = [
      material_claim("The accepted evidence outcome is #{entry["outcome"]}.", %{
        type: :evidence,
        evidence_id: entry["id"]
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "repository-valid: " <> _rest}) do
    claims = [
      material_claim("The repository shows this at lib/app.ex:1-2.", %{
        type: :repository,
        path: "lib/app.ex",
        start_line: 1,
        end_line: 2
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "mixed: " <> _rest, context_content: content}) do
    [entry | _rest] = content["specifications"]

    claims = [
      material_claim("The current specification is #{entry["title"]}.", %{
        type: :specification,
        specification_id: entry["id"],
        revision_id: entry["revision_id"]
      }),
      material_claim("The repository shows this at lib/app.ex:1-2.", %{
        type: :repository,
        path: "lib/app.ex",
        start_line: 1,
        end_line: 2
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "repository-secret: " <> _rest}) do
    claims = [
      material_claim("The repository shows this at .env:1.", %{
        type: :repository,
        path: ".env",
        start_line: 1,
        end_line: 1
      })
    ]

    {:ok, %{claims: claims, markers: []}}
  end

  def complete(%{question_text: "uncited-material: " <> _rest}) do
    {:ok,
     %{
       claims: [
         %{text: "This is stated as fact with nothing behind it.", material: true, citation: nil}
       ],
       markers: []
     }}
  end

  def complete(%{question_text: "conflicting: " <> _rest, context_content: content}) do
    [spec | _rest] = content["specifications"]
    [feature | _rest] = content["board"] |> Map.values() |> List.flatten()

    claims = [
      material_claim("Source A says the specification is #{spec["title"]}.", %{
        type: :specification,
        specification_id: spec["id"],
        revision_id: spec["revision_id"]
      }),
      material_claim("Source B says the feature #{feature["title"]} disagrees.", %{
        type: :board,
        feature_id: feature["id"]
      })
    ]

    markers = [%{type: :conflicting, detail: "Two current sources describe this differently."}]
    {:ok, %{claims: claims, markers: markers}}
  end

  def complete(%{question_text: "partial: " <> _rest, context_content: content}) do
    [entry | _rest] = content["specifications"]

    claims = [
      material_claim("The current specification is #{entry["title"]}.", %{
        type: :specification,
        specification_id: entry["id"],
        revision_id: entry["revision_id"]
      })
    ]

    markers = [%{type: :partial, detail: "Only part of the question could be answered."}]
    {:ok, %{claims: claims, markers: markers}}
  end

  def complete(%{question_text: _other}) do
    {:ok,
     %{
       claims: [
         %{text: "This is a general, non-material remark.", material: false, citation: nil}
       ],
       markers: []
     }}
  end

  defp material_claim(text, citation), do: %{text: text, material: true, citation: citation}
end
