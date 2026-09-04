defmodule SddOrchestratorWeb.FeatureDetailLive do
  @moduledoc """
  One feature's detail screen.

  This screen is where a feature's lifecycle actually changes. It shows the
  current column, any visible status, who created the feature and who is
  assigned, and the gated action available from the current column — never a
  free choice of destination.

  Later tasks fill this frame in with guided requirements, readiness, the start
  action, run activity, evidence, and review. What is fixed here is the shape:
  the current state, one authorized action at a time, and no way to set a column
  directly.
  """
  use SddOrchestratorWeb, :live_view

  alias SddOrchestrator.Delivery.{
    Activity,
    Answers,
    Assignment,
    Blocking,
    Cancellation,
    Comments,
    DeliveryStore,
    EvidencePresentation,
    Features,
    GuidedRequirements,
    LocalWorkerRuntimeProjection,
    ParticipantGuard,
    PreviewPresentation,
    ProcessingDisclosure,
    QuestionRouting,
    Readiness,
    ReadinessAssessment,
    Retry,
    Review,
    ReviewDecision,
    Start,
    Suggestions
  }

  alias SddOrchestrator.SpecificationStore

  @column_labels %{
    "draft" => "Draft",
    "ready_for_development" => "Ready for development",
    "in_development" => "In development",
    "ready_for_review" => "Ready for review",
    "done" => "Done"
  }

  @status_labels %{"blocked" => "Blocked", "failed" => "Failed"}

  # The gated action offered from each column. A column with no entry offers
  # nothing until the task that owns its action delivers it.
  @gated_actions %{
    "draft" => "Resolve the remaining blockers to make this ready for development.",
    "ready_for_development" => "Start development when you're ready.",
    "in_development" => "Development is running. Progress appears here.",
    "ready_for_review" => "Review the result and approve or send it back.",
    "done" => "This feature is done."
  }

  @comment_messages %{
    empty_comment: "Write something before posting.",
    comment_too_long: "That comment is too long. Shorten it and try again.",
    redacted_content: "Remove the address or credential from that comment before posting.",
    duplicate_comment: "That comment was already posted.",
    not_found: "This feature is no longer available."
  }

  @answer_messages %{
    empty_answer: "Write your decision before continuing.",
    answer_too_long: "That answer is too long. Shorten it and try again.",
    question_mismatch: "This question changed while you were reading it.",
    no_open_question: "This question has already been answered.",
    revision_conflict: "The specification changed while you were answering. Try again.",
    no_specification: "This project has no specification to write the answer into."
  }

  # A refused save always leaves the stored revision exactly as it was, so every
  # sentence here says what to do next rather than what broke. The head moving
  # is the one a person can act on: their words are still in the form, and a
  # reload shows what the other save wrote.
  @requirements_messages %{
    stale_revision:
      "This feature was saved by someone else while you were writing. Reload the page to " <>
        "read that version, then make your change again.",
    revision_conflict:
      "This save could not be recorded. Reload the page and make your change again.",
    no_specification: "This feature has no specification to save into.",
    document_too_large: "That is too long to save. Shorten it and try again.",
    revision_too_large: "That is too long to save. Shorten it and try again."
  }

  @requirements_unsaved "That did not save, and nothing changed. Try again."

  # Three readiness states the section shows and the lifecycle actions answer
  # with. Each is written once and rendered wherever it applies, so the note a
  # person reads and the refusal a press returns cannot drift apart.
  @readiness_check_first "Check readiness first."

  @readiness_stale_note "The requirements changed after this check. Check readiness again."

  @readiness_blocked_note "Something still blocks this feature. " <>
                            "Clear the blockers above, then check readiness again."

  # A refused check leaves the last verdict exactly as it was. Each sentence
  # says what to do next, because the reader can act on the words in the form
  # or on pressing again, never on the shape of the failure.
  @readiness_messages %{
    no_specification: "This feature has no specification to check.",
    guidance_timeout: "The guidance model did not answer in time. Try again.",
    guidance_unavailable: "The guidance model could not be reached. Try again.",
    not_dismissible: "That one blocks development, so it cannot be dismissed.",
    stale_assessment: "This changed while you were reading it. Check readiness again.",
    not_found: @readiness_check_first
  }

  @readiness_unchecked "Readiness could not be checked, and nothing changed. Try again."

  # What the page may say when no model took part. It states this deployment,
  # not the reader's computer, and it never implies a model judged anything.
  @readiness_not_configured "No guidance model is configured here. " <>
                              "These findings come from the guided parts alone."

  # Every start precondition named once. `Start.preconditions/3` decides which
  # are met and where each is resolved, so these maps only put words to the
  # answer it gives. The label names the item in both states; the note and the
  # link are read only when the item is unmet.
  @precondition_labels %{
    ready: "Ready, with a readiness check about these exact words",
    boundary: "The processing boundary confirmed",
    execution_profile: "An approved execution profile",
    worker: "A worker connected for this project",
    ai_connection: "One AI connection to run this"
  }

  # What is true now, and the one thing to do about it. The worker line states
  # only what the control plane can see, which is its own connections. It cannot
  # see the Mac, so the rest is offered as two branches the reader picks from.
  @precondition_notes %{
    ready:
      "The readiness check is missing, or it is about older words. " <>
        "Check readiness again, then make this feature ready.",
    boundary: "Read what this run will do, above, and confirm it.",
    execution_profile:
      "This project has no approved execution profile. Assess the repository, then approve one.",
    worker:
      "No worker is connected to this project right now. " <>
        "Connect this project to a Mac, or open the worker app on the Mac it is connected to.",
    ai_connection:
      "More than one active AI connection could run this. Leave one active for this project."
  }

  @precondition_actions %{
    ready: "Go to the readiness check",
    boundary: "Read the boundary above",
    execution_profile: "Open the execution profile",
    worker: "Open the project's connection",
    ai_connection: "Open AI connections"
  }

  # Two of the five pages are the owner's own. A participant is told who
  # resolves those rather than being handed a link that will not open for them.
  # It says nothing about starting, which stays theirs to do.
  @precondition_owner_routes [:project_connection, :ai_connections]

  @precondition_owner_only "The project owner resolves this one."

  # The refusals `Start.start/4` answers with that no precondition already puts
  # words to. Everything a precondition covers is answered with that item's own
  # sentence instead, so the list above the button and the answer below it read
  # the same. Each of these says what the control plane saw and what to do, not
  # what happened on anybody's machine.
  @start_refusals %{
    already_started: "This feature already has a run going. Nothing new was started.",
    no_specification: "This feature has no specification to start from.",
    invalid_manifest:
      "This project's development settings cannot produce this run's instructions. " <>
        "Nothing started, and that has to be fixed first."
  }

  @start_unstarted "That did not start, and nothing changed. Try again."

  # A lifecycle move this page can no longer make. Naming the shape of the
  # refusal would describe a race to somebody who can only act on one thing:
  # reading where the feature actually is now.
  @lifecycle_refused "This feature changed while you were looking at it. " <>
                       "Reload the page and try again."

  @retry_messages %{
    no_failed_run: "This run is going again already.",
    no_attempt: "There is nothing recorded to continue from.",
    stale_state: "This changed while you were looking at it. Try again."
  }

  @cancel_messages %{
    already_canceled: "This run was already canceled.",
    no_active_run: "There is no run to cancel.",
    stale_state: "This changed while you were looking at it. Try again."
  }

  # Every way an execution manifest can be refused says one thing to a reviewer:
  # the instructions the next attempt needs cannot be built from this project's
  # settings. Telling the seventeen shapes apart would describe an operator's
  # problem to somebody who cannot act on any of them.
  @manifest_unusable "This project's development settings cannot produce the next attempt, " <>
                       "so nothing was sent back. That has to be fixed before this work continues."

  @manifest_reasons ~w(
    invalid_manifest missing_manifest_field unknown_manifest_field
    unsupported_manifest_version invalid_manifest_identity invalid_attempt_number
    invalid_revision_id invalid_revision_digest invalid_base_revision
    invalid_target_branch invalid_required_checks too_many_required_checks
    invalid_required_check duplicate_required_check manifest_too_large
    invalid_continuation invalid_continuation_reason
  )a

  # The rejection rule lives in the domain, so the screen only puts words to the
  # answer it gave. Nothing here re-implements the limit or the blank check,
  # which is what keeps the two from disagreeing. Sending work back now also
  # continues the run, so everything that continuation can refuse is answered
  # here too rather than reaching a reviewer as an atom.
  @review_messages Map.merge(
                     Map.new(@manifest_reasons, &{&1, @manifest_unusable}),
                     %{
                       feedback_required: "Say what needs to change before sending this back.",
                       feedback_too_long: "That feedback is too long. Shorten it and try again.",
                       not_in_review:
                         "This feature is not waiting for a review decision anymore.",
                       not_verified:
                         "Nothing recorded proves this work, so there is nothing to decide about.",
                       stale_state: "This changed while you were looking at it. Try again.",
                       not_found: "This feature is no longer available.",
                       unknown_run:
                         "The run this work came from is no longer here, so there is nothing to send it back to.",
                       no_attempt:
                         "Nothing is recorded for this run to continue from, so it cannot be sent back.",
                       run_not_continuable:
                         "This run has already ended, so the work cannot continue from it.",
                       question_already_open:
                         "This run is already waiting on a decision. Answer that one before sending more back.",
                       workspace_root_unconfigured:
                         "This installation has nowhere for the work to continue in, so nothing was sent back.",
                       workspace_escape:
                         "This run's own working directory could not be confirmed, so nothing was sent back."
                     }
                   )

  # Nothing is written unless the whole verdict and its continuation commit
  # together, so an unrecognised refusal can say plainly that nothing changed
  # rather than implying the reviewer did something wrong.
  @review_unaccepted "That decision could not be recorded, and nothing changed. Try again."

  # What a recorded verdict is called on the screen. The stored value stays a
  # machine token; only this map turns it into a person's word for it.
  @review_outcome_labels %{"approved" => "Approved", "rejected" => "Sent back"}

  # A rejection is the negative outcome on this screen, so it carries the error
  # icon and colour rather than being told apart from an approval by tone alone.
  @review_outcome_icons %{"approved" => "circle-check", "rejected" => "circle-alert"}

  # Every refused artifact read says exactly this, whether the item never had
  # bytes, belongs to another project, was removed by retention, or is being
  # asked for by someone who is no longer a participant. Distinguishing them
  # would be the disclosure the fetch seam exists to prevent.
  @artifact_unavailable "That proof is not available."

  @evidence_kind_labels %{
    "required_check" => "Required check",
    "screenshot" => "Screenshot",
    "preview" => "Preview"
  }

  # The four recorded outcomes. `superseded` is deliberately not one of them: an
  # item that was replaced still passed or failed, and flattening the two into a
  # single state would hide which.
  @evidence_state_labels %{
    "passed" => "Passed",
    "failed" => "Failed",
    "missing" => "Missing",
    "unsupported" => "Unsupported"
  }

  @evidence_state_variants %{
    "passed" => "ok",
    "failed" => "err",
    "missing" => "err",
    "unsupported" => "warn"
  }

  @evidence_state_icons %{
    "passed" => "circle-check",
    "failed" => "circle-alert",
    "missing" => "circle-alert",
    "unsupported" => "triangle-alert"
  }

  # Where the result came from. An agent's account of its own work is not an
  # allowed source at all, so there is nothing here for one.
  @evidence_source_labels %{
    "check" => "The check's own command",
    "worker" => "The worker that ran it"
  }

  @capture_reason_messages %{
    "no_visual_result" => "This work produced nothing to capture.",
    "capture_unsupported" => "This environment could not capture a screenshot.",
    "capture_failed" => "The capture itself broke."
  }

  # Every state a preview can be presented in, absence included. `not_configured`
  # and `none` are different answers on purpose: one project never had a preview
  # path, the other has one and has not verified anything yet.
  @preview_state_labels %{
    "not_configured" => "No preview path",
    "none" => "Not started",
    "pending" => "Deploying",
    "ready" => "Ready",
    "failed" => "Failed",
    "timed_out" => "Timed out",
    "expired" => "Expired",
    "superseded" => "Replaced"
  }

  # An expired preview is not a failed one. It reached the end of a lifetime
  # somebody configured, which is a warning at most, while a provider that
  # refused or never answered is an error.
  @preview_state_variants %{
    "not_configured" => "neutral",
    "none" => "neutral",
    "pending" => "info",
    "ready" => "ok",
    "failed" => "err",
    "timed_out" => "err",
    "expired" => "warn",
    "superseded" => "neutral"
  }

  @preview_state_icons %{
    "not_configured" => "info",
    "none" => "info",
    "pending" => "loader",
    "ready" => "circle-check",
    "failed" => "circle-alert",
    "timed_out" => "circle-alert",
    "expired" => "triangle-alert",
    "superseded" => "refresh-cw"
  }

  # A preview failure is recorded as a machine token, never as the provider's own
  # words. The sentence is written here; the token itself is shown separately as
  # a code, so an unrecognised one is never dressed up as prose and never hidden.
  @preview_failure_messages %{
    "preview_request_timeout" => "The preview provider did not answer in time.",
    "preview_request_rejected" => "The request was refused before it reached the provider.",
    "invalid_preview_response" => "The provider answered with something this project cannot use.",
    "preview_not_configured" => "No preview provider is configured for this project.",
    "preview_not_authorized" => "This project has no authorized preview path.",
    "preview_path_not_authorized" => "That preview path is not authorized for this project.",
    "provider_failed" => "The preview provider refused this deployment.",
    "provider_error" => "The preview provider broke while handling this deployment.",
    "provider_unavailable" => "The preview provider was unavailable.",
    "quota_exhausted" => "The preview provider has no capacity left for this project."
  }

  @preview_cleanup_labels %{
    "requested" => "Release requested",
    "done" => "Released",
    "failed" => "Release failed"
  }

  @verification_reasons %{
    "required_check_contract_unknown" =>
      "This attempt has no recorded list of required checks, so there was nothing to verify against.",
    "commit_identity_missing" => "The claim named no commit to verify.",
    "branch_identity_missing" => "The claim named no branch to verify.",
    "branch_mismatch" => "The claim named a branch this run does not own.",
    "revision_identity_missing" => "The claim named no specification revision.",
    "revision_mismatch" => "The claim named a revision this attempt is not working from.",
    "required_check_failed" => "A required check failed.",
    "required_check_missing" => "A required check has no result for this commit.",
    "required_check_unsupported" => "A required check could not run in this environment.",
    "screenshot_capture_failed" => "A screenshot capture broke."
  }

  # A failure reason is a worker's code. It is shown as a sentence a person can
  # act on, and an unrecognised code is reported rather than hidden.
  @failure_messages %{
    "agent_exit_recoverable" => "The coding agent stopped before it finished.",
    "incompatible_protocol" => "This worker speaks a version this project cannot use.",
    "invalid_authorization" => "The worker was not allowed to do this work.",
    "limits_exhausted" => "This run reached a configured limit.",
    "malformed_manifest" => "The instructions sent to the worker were not usable.",
    "missing_configuration" => "Something this run needs is not configured.",
    "provider_unavailable" => "The model provider was unavailable.",
    "rate_limited" => "The provider is rate limiting this project.",
    "transport_lost" => "The connection to the worker was lost.",
    "unsafe_workspace" => "The workspace was not in a safe state to work in.",
    "worker_unavailable" => "The configured worker was unavailable."
  }

  @impl true
  def handle_event("answer", %{"answer" => %{"body" => body}}, socket) do
    socket
    |> storage_authority()
    |> Answers.accept(
      socket.assigns.actor,
      %{project: socket.assigns.project, feature: socket.assigns.feature},
      socket.assigns.question && socket.assigns.question.id,
      body
    )
    |> case do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:answer_body, "")
         |> assign(:answer_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:answer_body, body)
         |> assign(
           :answer_error,
           Map.get(@answer_messages, reason, "That answer was not accepted.")
         )}
    end
  end

  # The typed words are kept in the form and nowhere else until the person
  # saves. Nothing here writes them to a log or an activity entry.
  def handle_event("validate_requirements", %{"requirements" => parts}, socket) do
    {:noreply,
     socket
     |> assign(:requirements_parts, normalize_requirements(parts))
     |> assign(:requirements_error, nil)}
  end

  def handle_event("save_requirements", %{"requirements" => parts}, socket) do
    document = GuidedRequirements.render(parts)

    socket
    |> assign(:requirements_parts, GuidedRequirements.parse(document))
    |> save_requirements(document)
  end

  # Readiness is checked when the person asks for it, never as a side effect of
  # opening the page. A verdict that appeared on its own would be about words
  # somebody was still writing.
  def handle_event("check_readiness", _params, socket) do
    socket
    |> storage_authority()
    |> Readiness.assess(socket.assigns.actor, %{
      project: socket.assigns.project,
      feature: socket.assigns.feature
    })
    |> case do
      {:ok, assessment} ->
        {:noreply,
         socket
         |> assign(:readiness, assessment)
         |> assign(:readiness_error, nil)
         |> assign_start_preconditions()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply, assign(socket, :readiness_error, readiness_message(reason))}
    end
  end

  # The stored version travels with the press, so a dismissal aimed at the list
  # that was on screen is refused once readiness has been checked again.
  def handle_event("dismiss_suggestion", %{"id" => finding_id}, socket) do
    case socket.assigns.readiness do
      nil ->
        {:noreply, assign(socket, :readiness_error, readiness_message(:not_found))}

      assessment ->
        dismiss_suggestion(socket, assessment, finding_id)
    end
  end

  # Ready is a decision, so the press is answered against the verdict the page
  # is showing. What the screen does not offer is refused here too: a page left
  # open can still send this event after the words moved on.
  def handle_event("make_ready", _params, socket) do
    case make_ready_state(
           socket.assigns.feature,
           socket.assigns.readiness,
           socket.assigns.requirements_revision_id,
           socket.assigns.requirements_digest
         ) do
      :ready -> promote_feature(socket)
      refused -> {:noreply, assign(socket, :lifecycle_error, make_ready_refusal(refused))}
    end
  end

  # The way back out of `Ready for development`. It moves the column and nothing
  # else: the written words, the verdict, and its findings stay exactly as they
  # are, so the person picks up where they left off.
  def handle_event("back_to_draft", _params, socket) do
    feature = socket.assigns.feature

    socket.assigns.project_id
    |> Features.transition(socket.assigns.actor, feature, "draft",
      expected_state_version: feature.state_version
    )
    |> case do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:lifecycle_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, updated)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, _reason} ->
        {:noreply, assign(socket, :lifecycle_error, @lifecycle_refused)}
    end
  end

  def handle_event("retry", _params, socket) do
    socket
    |> storage_authority()
    |> Retry.retry_now(socket.assigns.actor, %{
      project: socket.assigns.project,
      feature: socket.assigns.feature
    })
    |> case do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:retry_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :retry_error,
           Map.get(@retry_messages, reason, "That retry was not accepted.")
         )}
    end
  end

  def handle_event("cancel", _params, socket) do
    socket
    |> storage_authority()
    |> Cancellation.cancel(socket.assigns.actor, %{
      project: socket.assigns.project,
      feature: socket.assigns.feature
    })
    |> case do
      {:ok, results} ->
        {:noreply,
         socket
         |> assign(:cancel_error, nil)
         |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :cancel_error,
           Map.get(@cancel_messages, reason, "That cancellation was not accepted.")
         )}
    end
  end

  def handle_event("approve", _params, socket) do
    socket
    |> storage_authority()
    |> Review.approve(socket.assigns.actor, review_subject(socket))
    |> apply_review(socket, socket.assigns.review_feedback, socket.assigns.review_contradicts?)
  end

  def handle_event("reject", %{"review" => %{"feedback" => feedback} = review}, socket) do
    contradicts? = declared?(review)

    socket
    |> storage_authority()
    |> Review.reject(socket.assigns.actor, review_subject(socket), feedback,
      contradicts_agreement?: contradicts?
    )
    |> apply_review(socket, feedback, contradicts?)
  end

  def handle_event("validate_review", %{"review" => %{"feedback" => feedback} = review}, socket) do
    {:noreply,
     socket
     |> assign(:review_feedback, feedback)
     |> assign(:review_contradicts?, declared?(review))
     |> assign(:review_error, nil)}
  end

  def handle_event("confirm_boundary", %{"digest" => digest}, socket) do
    # Deliberately not the mounted assign: the agreement must be checked against
    # the boundary in force right now, or a configuration change during the
    # dialog would be confirmed anyway.
    socket.assigns.project_id
    |> ProcessingDisclosure.confirm(socket.assigns.actor, digest)
    |> case do
      {:ok, _confirmation} ->
        {:noreply, socket |> assign_disclosure() |> assign_start_preconditions()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      # The configuration moved while the dialog was open, so the person is
      # shown the boundary that is actually in force rather than agreeing to
      # one that no longer exists.
      {:error, _reason} ->
        {:noreply,
         socket
         |> assign_disclosure()
         |> assign(:boundary_changed?, true)
         |> assign_start_preconditions()}
    end
  end

  # The readout the person pressed can already be out of date, so every item is
  # asked again here rather than trusted from the screen. A worker that went
  # away between the two is refused with the sentence that item now shows, and
  # nothing is created. Only a fully met list reaches `Start.start/4`, which
  # re-checks everything it owns for itself.
  def handle_event("start_development", _params, socket) do
    socket = assign_start_preconditions(socket)

    case Enum.find(socket.assigns.start_preconditions, &(not &1.met?)) do
      nil -> start_development(socket)
      unmet -> {:noreply, assign(socket, :start_error, precondition_note(unmet.key))}
    end
  end

  def handle_event("comment", %{"comment" => %{"body" => body}}, socket) do
    socket.assigns.project_id
    |> Comments.add(socket.assigns.actor, socket.assigns.feature.id, body)
    |> case do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> assign(:comment_body, "")
         |> assign(:comment_error, nil)
         |> refresh_activity()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:comment_body, body)
         |> assign(:comment_error, Map.fetch!(@comment_messages, reason))}
    end
  end

  def handle_event("validate_comment", %{"comment" => %{"body" => body}}, socket) do
    {:noreply, socket |> assign(:comment_body, body) |> assign(:comment_error, nil)}
  end

  # The bytes are read now rather than at render, because participation is
  # re-checked on every read and the person pressing this may have left the
  # project since the list was drawn.
  def handle_event("view_evidence", %{"id" => evidence_id}, socket) do
    socket
    |> storage_authority()
    |> EvidencePresentation.inline_artifact(
      socket.assigns.project_id,
      evidence_id,
      socket.assigns.actor
    )
    |> case do
      {:ok, artifact} ->
        {:noreply,
         socket
         |> assign(:evidence_artifact, artifact)
         |> assign(:evidence_artifact_error, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:evidence_artifact, nil)
         |> assign(:evidence_artifact_error, @artifact_unavailable)}
    end
  end

  def handle_event("hide_evidence", _params, socket) do
    {:noreply, socket |> assign(:evidence_artifact, nil) |> assign(:evidence_artifact_error, nil)}
  end

  def handle_event("assign", %{"assignment" => %{"account_id" => account_id}}, socket) do
    socket.assigns.project_id
    |> Assignment.assign(socket.assigns.actor, socket.assigns.feature, blank_to_nil(account_id))
    |> apply_assignment(socket)
  end

  def handle_event("assign_to_me", _params, socket) do
    socket.assigns.project_id
    |> Assignment.assign_to_me(socket.assigns.actor, socket.assigns.feature)
    |> apply_assignment(socket)
  end

  def handle_event(
        "link_specification",
        %{"specification" => %{"specification_id" => ""}},
        socket
      ) do
    socket.assigns.project_id
    |> Features.unlink_specification(socket.assigns.actor, socket.assigns.feature)
    |> apply_specification_link(socket)
  end

  def handle_event(
        "link_specification",
        %{"specification" => %{"specification_id" => specification_id}},
        socket
      ) do
    socket
    |> storage_authority()
    |> Features.link_specification(
      socket.assigns.project_id,
      socket.assigns.actor,
      socket.assigns.feature,
      specification_id
    )
    |> apply_specification_link(socket)
  end

  # A rejected assignment says what went wrong without revealing whether the
  # chosen person exists elsewhere in the product.
  defp apply_assignment({:ok, feature}, socket) do
    {:noreply,
     socket
     |> assign_feature(socket.assigns.project_id, socket.assigns.actor, feature)
     |> assign(:assignment_error, nil)}
  end

  defp apply_assignment({:error, :unauthorized}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/projects")}

  defp apply_assignment({:error, reason}, socket),
    do: {:noreply, assign(socket, :assignment_error, assignment_message(reason))}

  defp assignment_message(:invalid_target),
    do: "That person is not on this project anymore. Pick someone from the list."

  defp assignment_message(_reason),
    do: "This feature changed while you were looking at it. It has been refreshed."

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(account_id), do: account_id

  defp apply_specification_link({:ok, feature}, socket) do
    {:noreply,
     socket
     |> assign_feature(socket.assigns.project_id, socket.assigns.actor, feature)
     |> assign(:specification_link_error, nil)}
  end

  defp apply_specification_link({:error, :unauthorized}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/projects")}

  defp apply_specification_link({:error, reason}, socket),
    do: {:noreply, assign(socket, :specification_link_error, specification_link_message(reason))}

  defp specification_link_message(:already_linked),
    do:
      "That specification is already linked to another feature. Pick a different one, " <>
        "or clear the other feature's link first."

  defp specification_link_message(_reason),
    do: "This feature changed while you were looking at it. It has been refreshed."

  # Only the four guided parts are carried, exactly as typed. Trimming happens
  # when the document is rendered, so a person is not fighting the field for a
  # blank line while they are still writing in it.
  defp normalize_requirements(parts) do
    Map.new(GuidedRequirements.keys(), fn key -> {key, requirements_value(parts, key)} end)
  end

  defp requirements_value(parts, key) do
    case Map.get(parts, key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  end

  # The save goes against the revision the page read, never against whatever is
  # current now. A head that moved is somebody else's save, and appending over
  # it would drop their words with nobody seeing it happen.
  defp save_requirements(socket, document) do
    project_id = socket.assigns.project_id

    with {:ok, member} <-
           ParticipantGuard.authorize_action(project_id, socket.assigns.actor, :answer_question),
         {:ok, expected, carried} <- requirements_base(socket),
         {:ok, appended} <-
           SpecificationStore.append_revision(
             storage_authority(socket),
             project_id,
             socket.assigns.feature.specification_id,
             expected,
             %{
               revision_id: Ecto.UUID.generate(),
               documents: Map.put(carried, :requirements, document),
               actor_ref: member.account_id
             }
           ) do
      {:noreply, saved_requirements(socket, appended)}
    else
      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply, assign(socket, :requirements_error, requirements_message(reason))}
    end
  end

  defp requirements_base(%{assigns: %{requirements_revision_id: nil}}),
    do: {:error, :no_specification}

  defp requirements_base(%{assigns: assigns}),
    do: {:ok, assigns.requirements_revision_id, assigns.requirements_carried}

  # The stored document is read back rather than the typed text kept, so the
  # form shows what was actually written.
  defp saved_requirements(socket, %{revision: revision}) do
    socket
    |> assign(:requirements_revision_id, revision.id)
    |> assign(:requirements_digest, revision.content_digest)
    |> assign(:requirements_carried, carried_documents(revision))
    |> assign(:requirements_parts, GuidedRequirements.parse(revision.requirements_document))
    |> assign(:requirements_error, nil)
    |> assign_start_preconditions()
  end

  # The design and tasks documents belong to the coding agent. The form carries
  # them forward exactly as they are, so writing requirements never edits them.
  defp carried_documents(revision),
    do: %{design: revision.design_document, tasks: revision.tasks_document}

  defp requirements_message(reason) when is_atom(reason),
    do: Map.get(@requirements_messages, reason, @requirements_unsaved)

  defp requirements_message(_reason), do: @requirements_unsaved

  defp dismiss_suggestion(socket, assessment, finding_id) do
    socket.assigns.project_id
    |> Suggestions.dismiss(
      socket.assigns.actor,
      socket.assigns.feature.id,
      finding_id,
      assessment.version
    )
    |> case do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:readiness, updated)
         |> assign(:readiness_error, nil)
         |> assign_start_preconditions()}

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply, assign(socket, :readiness_error, readiness_message(reason))}
    end
  end

  # One clause, because `Suggestions.dismiss/5` only ever refuses with an atom.
  # The guarded pair this replaced kept an unreachable fallback that Dialyzer
  # reported, and `Map.get/3`'s own default already answers for a reason this
  # screen has no wording for.
  defp readiness_message(reason),
    do: Map.get(@readiness_messages, reason, @readiness_unchecked)

  # The state version travels in the operation key, so a double press from one
  # screen is absorbed while a feature that went back to draft can be made ready
  # again rather than answering with the first press's result.
  defp promote_feature(socket) do
    feature = socket.assigns.feature

    socket
    |> storage_authority()
    |> Suggestions.promote(
      socket.assigns.actor,
      %{project: socket.assigns.project, feature: feature},
      "ready:#{feature.id}:#{feature.state_version}"
    )
    |> case do
      # The absorbed repeat carries the earlier activity and no feature, so the
      # feature is read back either way and both presses land on one screen.
      {:ok, _outcome} ->
        reload_feature(socket)

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      {:error, reason} ->
        {:noreply, assign(socket, :lifecycle_error, promote_message(reason))}
    end
  end

  # The feature the page rendered travels into the start, so its `state_version`
  # is the version the move is locked against: a press from a screen the feature
  # has moved on from is refused rather than applied to whatever it became.
  defp start_development(socket) do
    socket
    |> storage_authority()
    |> Start.start(socket.assigns.actor, %{
      project: socket.assigns.project,
      feature: socket.assigns.feature
    })
    |> case do
      {:ok, _results} ->
        run_begun(socket)

      {:error, :unauthorized} ->
        {:noreply, push_navigate(socket, to: ~p"/projects")}

      # Nothing was created, so the readout is worked out again and the reason
      # is put beside the button the person pressed.
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:start_error, start_message(reason))
         |> assign_start_preconditions()}
    end
  end

  # The run is now the worker's to do, and everything it reports arrives as this
  # project's worker traffic. The page listens from here on and reads the feature
  # back, so the run's acknowledgement and its progress appear through the
  # sections that already render a running run.
  defp run_begun(socket) do
    socket
    |> watch_worker()
    |> assign(:start_error, nil)
    |> reload_feature()
  end

  # One subscription for as long as this page lives. What arrives is never read
  # for its content: a worker envelope is taken only as a sign to read the
  # stored history again, so nothing a worker says can reach the screen without
  # passing the checks that make it durable first.
  defp watch_worker(%{assigns: %{watching_worker?: true}} = socket), do: socket

  defp watch_worker(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        SddOrchestrator.PubSub,
        SddOrchestratorWeb.WorkerChannel.topic(socket.assigns.project_id)
      )

      assign(socket, :watching_worker?, true)
    else
      socket
    end
  end

  defp start_message(:not_ready), do: precondition_note(:ready)
  defp start_message(:boundary_unconfirmed), do: precondition_note(:boundary)
  defp start_message(:no_execution_profile), do: precondition_note(:execution_profile)

  defp start_message({:ai_connection_selection_required, _eligible_ids}),
    do: precondition_note(:ai_connection)

  defp start_message(reason) when is_atom(reason),
    do: Map.get(@start_refusals, reason, @start_unstarted)

  defp start_message(_reason), do: @start_unstarted

  defp reload_feature(socket) do
    project_id = socket.assigns.project_id
    actor = socket.assigns.actor

    case Features.fetch(project_id, actor, socket.assigns.feature.id) do
      {:ok, feature} ->
        {:noreply,
         socket
         |> assign(:lifecycle_error, nil)
         |> assign_feature(project_id, actor, feature)}

      {:error, _reason} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project_id}/features")}
    end
  end

  # The domain refuses a blocker on its own, and it says the same thing the
  # screen already says, so the reader gets one instruction either way.
  defp promote_message(:not_ready), do: @readiness_blocked_note
  defp promote_message(_reason), do: @lifecycle_refused

  defp make_ready_refusal(:unchecked), do: @readiness_check_first
  defp make_ready_refusal(:stale), do: @readiness_stale_note
  defp make_ready_refusal(:blocked), do: @readiness_blocked_note
  defp make_ready_refusal(:not_draft), do: @lifecycle_refused

  defp review_subject(socket),
    do: %{project: socket.assigns.project, feature: socket.assigns.feature}

  # Whether acting on this feedback would change the approved product agreement
  # is the reviewer's own declaration. An absent control is `false`, and nothing
  # here reads the feedback to guess: inferring the agreement is exactly what the
  # specification write-back exists to prevent.
  defp declared?(%{"contradicts_agreement" => "true"}), do: true
  defp declared?(_review), do: false

  # A decision that was already made for this attempt answers `applied?: false`
  # and hands back what is on record, so the screen refreshes from the result
  # either way rather than treating a second press as a failure.
  defp apply_review({:ok, results}, socket, _feedback, _contradicts?) do
    {:noreply,
     socket
     |> assign(:review_feedback, "")
     |> assign(:review_contradicts?, false)
     |> assign(:review_error, nil)
     |> assign_feature(socket.assigns.project_id, socket.assigns.actor, results.feature)}
  end

  defp apply_review({:error, :unauthorized}, socket, _feedback, _contradicts?),
    do: {:noreply, push_navigate(socket, to: ~p"/projects")}

  # The declaration is kept along with the words, because a refused submission
  # that silently cleared it would send the next press somewhere the reviewer
  # did not choose.
  defp apply_review({:error, reason}, socket, feedback, contradicts?) do
    {:noreply,
     socket
     |> assign(:review_feedback, feedback)
     |> assign(:review_contradicts?, contradicts?)
     |> assign(:review_error, Map.get(@review_messages, reason, @review_unaccepted))}
  end

  # A worker said something about this project. What it said is deliberately
  # ignored; the feature and its history are read back instead, which is the
  # only place a worker's word becomes something a person may read.
  @impl true
  def handle_info({:worker_event, _envelope}, socket), do: {:noreply, reread_feature(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Unlike `reload_feature/1` this leaves the page's messages alone. A run's own
  # progress must never quietly clear a refusal somebody is still reading.
  defp reread_feature(socket) do
    project_id = socket.assigns.project_id
    actor = socket.assigns.actor

    case Features.fetch(project_id, actor, socket.assigns.feature.id) do
      {:ok, feature} -> assign_feature(socket, project_id, actor, feature)
      {:error, _reason} -> socket
    end
  end

  @impl true
  def mount(%{"id" => project_id, "feature_id" => feature_id}, _session, socket) do
    actor = actor(socket)

    case Features.fetch(project_id, actor, feature_id) do
      {:ok, feature} ->
        {:ok, assign_feature(socket, project_id, actor, feature)}

      {:error, :unauthorized} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/projects/#{project_id}/features")}
    end
  end

  defp actor(socket) do
    identity = socket.assigns[:current_hosted_identity]
    account = socket.assigns[:current_account]

    %{
      account_id: (account && account.id) || (identity && identity.account_id),
      hosted_identity_id: identity && identity.id
    }
  end

  defp assign_feature(socket, project_id, actor, feature) do
    members = ParticipantGuard.current_members(project_id, actor)

    socket
    |> assign(:page_title, feature.title)
    |> assign(:project_id, project_id)
    |> assign(:actor, actor)
    |> assign(:feature, feature)
    |> assign(:names, Map.new(members, &{&1.account_id, &1.display_name}))
    |> assign(:members, members)
    |> assign(:owner?, owner?(project_id, actor))
    |> assign(:responsible, QuestionRouting.responder_label(project_id, feature))
    |> assign(:question_for_me?, QuestionRouting.tagged?(project_id, feature, actor))
    |> assign(:question, open_question(project_id, actor, feature))
    |> assign(:project, SddOrchestrator.Repo.get(SddOrchestrator.Projects.Project, project_id))
    |> assign_failed_run(actor, feature)
    |> assign_cancelable_run(actor, feature)
    |> assign_evidence(actor, feature)
    |> assign_preview(actor, feature)
    |> assign_review(actor, feature)
    |> assign_available_specifications(project_id, actor, feature)
    |> assign_requirements(feature)
    |> assign_readiness(project_id, actor, feature)
    |> assign(:answer_body, socket.assigns[:answer_body] || "")
    |> assign(:answer_error, socket.assigns[:answer_error])
    |> assign(:assignment_error, socket.assigns[:assignment_error])
    |> assign(:specification_link_error, socket.assigns[:specification_link_error])
    |> assign(:lifecycle_error, socket.assigns[:lifecycle_error])
    |> assign(:start_error, socket.assigns[:start_error])
    |> assign(:watching_worker?, socket.assigns[:watching_worker?] || false)
    |> assign(:comment_body, socket.assigns[:comment_body] || "")
    |> assign(:comment_error, socket.assigns[:comment_error])
    |> load_activity(project_id, actor, feature)
    |> assign_runtime_projection(actor)
    |> assign_disclosure()
    |> assign_start_preconditions()
  end

  # The same fail-closed check this screen already passed, re-asked for its role
  # so the owner-only navigation destination is offered to the owner alone. It
  # adds no second authorization concept.
  defp owner?(project_id, actor) do
    case ParticipantGuard.authorize(project_id, actor) do
      {:ok, %{role: :owner}} -> true
      _other -> false
    end
  end

  # The link picker is owner-only because the specification list it offers is
  # only reachable through the owner-mapped specification-store authority. A
  # non-owner viewer, or an owner whose store is momentarily unreachable, gets
  # an empty list rather than a crash or a control nobody could complete.
  defp assign_available_specifications(socket, project_id, actor, feature) do
    available =
      if socket.assigns.owner? do
        socket
        |> storage_authority()
        |> Features.available_specifications(project_id, actor, feature)
        |> case do
          {:ok, specifications} -> specifications
          {:error, _reason} -> []
        end
      else
        []
      end

    assign(socket, :available_specifications, available)
  end

  # The verdict already on record, if there is one. A reader who cannot see it
  # sees nothing rather than an error, which is the answer the rest of this
  # screen gives someone outside the project.
  defp assign_readiness(socket, project_id, actor, feature) do
    assessment =
      case Readiness.current(project_id, actor, feature.id) do
        {:ok, assessment} -> assessment
        {:error, _reason} -> nil
      end

    socket
    |> assign(:readiness, assessment)
    |> assign(:readiness_error, socket.assigns[:readiness_error])
  end

  # The feature's own requirements, read once and then held. Every later action
  # on this screen leaves them alone, so words typed and not yet saved survive a
  # comment or an answer, and the revision the save is checked against stays the
  # one the page actually showed.
  defp assign_requirements(socket, feature) do
    if Map.has_key?(socket.assigns, :requirements_parts) do
      socket
    else
      load_requirements(socket, feature)
    end
  end

  # The revision's digest is held beside its id because a verdict is bound to
  # both. That pair is what lets the readiness section tell a verdict about the
  # words on screen from one about words that have since changed.
  defp load_requirements(socket, feature) do
    case current_specification(socket, feature) do
      {:ok, %{revision: revision}} ->
        socket
        |> assign(:requirements_revision_id, revision.id)
        |> assign(:requirements_digest, revision.content_digest)
        |> assign(:requirements_carried, carried_documents(revision))
        |> assign(:requirements_parts, GuidedRequirements.parse(revision.requirements_document))
        |> assign(:requirements_error, nil)

      :error ->
        socket
        |> assign(:requirements_revision_id, nil)
        |> assign(:requirements_digest, nil)
        |> assign(:requirements_carried, nil)
        |> assign(:requirements_parts, GuidedRequirements.parse(""))
        |> assign(:requirements_error, nil)
    end
  end

  # Only the feature's own linked specification is ever read here. A feature
  # created before it owned one, or a store that refuses, reads as nothing to
  # write into rather than as another specification of the project.
  defp current_specification(_socket, %{specification_id: nil}), do: :error

  defp current_specification(socket, feature) do
    socket
    |> storage_authority()
    |> SpecificationStore.get_current(socket.assigns.project_id, feature.specification_id)
    |> case do
      {:ok, current} -> {:ok, current}
      {:error, _reason} -> :error
    end
  end

  # The stopped run this reader may restart, if any. Resolved after the project
  # is assigned, because the storage authority is derived from it.
  defp assign_failed_run(socket, actor, feature) do
    failed_run =
      case Retry.pending(storage_authority(socket), actor, %{
             project: socket.assigns.project,
             feature: feature
           }) do
        {:ok, run} -> run
        {:error, :unauthorized} -> nil
      end

    socket
    |> assign(:failed_run, failed_run)
    |> assign(:retry_error, socket.assigns[:retry_error])
  end

  # The run this reader may end, if any. The domain applies the narrow
  # initiator-or-owner rule, so the action is absent for a participant whose
  # press would be refused rather than shown and then denied.
  defp assign_cancelable_run(socket, actor, feature) do
    cancelable_run =
      case Cancellation.cancelable(storage_authority(socket), actor, %{
             project: socket.assigns.project,
             feature: feature
           }) do
        {:ok, run} -> run
        {:error, :unauthorized} -> nil
      end

    socket
    |> assign(:cancelable_run, cancelable_run)
    |> assign(:cancel_error, socket.assigns[:cancel_error])
  end

  # Everything this feature ever proved, superseded and absent results included,
  # beside the completion gate's own conclusion. A reader who cannot read
  # evidence sees no evidence rather than an error, which is the same answer the
  # rest of this screen gives someone outside the project.
  defp assign_evidence(socket, actor, feature) do
    authority = storage_authority(socket)
    project_id = socket.assigns.project_id

    evidence =
      case EvidencePresentation.list(authority, project_id, actor, feature.id) do
        {:ok, items} -> items
        {:error, :unauthorized} -> []
      end

    verification =
      case EvidencePresentation.verification(authority, project_id, actor, feature.id) do
        {:ok, verdict} -> verdict
        {:error, :unauthorized} -> nil
      end

    socket
    |> assign(:evidence, evidence)
    |> assign(:verification, verification)
    |> assign(:evidence_artifact, socket.assigns[:evidence_artifact])
    |> assign(:evidence_artifact_error, socket.assigns[:evidence_artifact_error])
  end

  # Whether this feature has a preview, and what became of it. A reader who
  # cannot read evidence is shown the same nothing a project with no preview path
  # shows, so the section never becomes a way to learn about a project from
  # outside it.
  defp assign_preview(socket, actor, feature) do
    preview =
      case PreviewPresentation.summary(
             storage_authority(socket),
             socket.assigns.project_id,
             actor,
             feature.id
           ) do
        {:ok, summary} -> summary
        {:error, :unauthorized} -> PreviewPresentation.unavailable()
      end

    assign(socket, :preview, preview)
  end

  # Whether this reader may end the review, and whatever verdict is already on
  # record. The domain applies the responsible-or-owner rule itself, so an
  # approve or reject control is absent for someone whose press would be refused
  # rather than shown and then denied. Someone who is no longer a participant is
  # shown the same nothing the rest of this screen shows them, verdict included.
  defp assign_review(socket, actor, feature) do
    authority = storage_authority(socket)

    project_id = socket.assigns.project_id

    {reviewable?, decision, blocked_for_spec?} =
      case Review.reviewable(authority, actor, %{
             project: socket.assigns.project,
             feature: feature
           }) do
        {:ok, reviewable?} ->
          decision = Review.decision(authority, project_id, feature)
          {reviewable?, decision, rejection_blocked?(authority, project_id, feature, decision)}

        {:error, :unauthorized} ->
          {false, nil, false}
      end

    socket
    |> assign(:reviewable?, reviewable?)
    |> assign(:review_decision, decision)
    |> assign(:review_blocked_for_spec?, blocked_for_spec?)
    |> assign(:review_feedback, socket.assigns[:review_feedback] || "")
    |> assign(:review_contradicts?, socket.assigns[:review_contradicts?] || false)
    |> assign(:review_error, socket.assigns[:review_error])
  end

  # Only a rejection has an outcome to tell apart, so the history is read only
  # when there is a note that depends on it.
  defp rejection_blocked?(authority, project_id, feature, %{decision: "rejected"}),
    do: Review.blocked_for_specification?(authority, project_id, feature)

  defp rejection_blocked?(_authority, _project_id, _feature, _decision), do: false

  defp assign_disclosure(socket) do
    disclosure = ProcessingDisclosure.describe()

    socket
    |> assign(:disclosure, disclosure)
    |> assign(
      :disclosure_confirmed?,
      ProcessingDisclosure.confirmed?(socket.assigns.project_id, socket.assigns.actor, disclosure)
    )
    |> assign(:boundary_changed?, socket.assigns[:boundary_changed?] || false)
  end

  # The readout describes this instant and is kept nowhere, so it is worked out
  # again wherever something it reads can have moved: the feature, the verdict,
  # the written words, or the boundary confirmation.
  defp assign_start_preconditions(socket) do
    assign(
      socket,
      :start_preconditions,
      Start.preconditions(storage_authority(socket), socket.assigns.actor, %{
        project: socket.assigns.project,
        feature: socket.assigns.feature
      })
    )
  end

  defp load_activity(socket, project_id, actor, feature) do
    case Activity.list(project_id, actor, feature.id, limit: Activity.max_limit()) do
      {:ok, entries} ->
        socket
        |> assign(:activity, Enum.filter(entries, &(&1.type == "progress")))
        |> assign(:comments, Enum.filter(entries, &(&1.type == "comment")))
        |> assign(:current_run_id, current_run_id(entries))

      {:error, :unauthorized} ->
        socket
        |> assign(:activity, [])
        |> assign(:comments, [])
        |> assign(:current_run_id, nil)
    end
  end

  defp refresh_activity(socket) do
    load_activity(
      socket,
      socket.assigns.project_id,
      socket.assigns.actor,
      socket.assigns.feature
    )
  end

  # The most recent "run_started" entry names the run currently associated with
  # this feature, in whatever state it is now — not only a live or cancelable
  # one. Entries arrive in ascending authoritative order, so the last match is
  # the most recent start.
  defp current_run_id(entries) do
    entries
    |> Enum.filter(&(&1.type == "run_started"))
    |> List.last()
    |> case do
      nil -> nil
      entry -> entry.run_id
    end
  end

  # The pinned-connection runtime projection for the feature's current run, if
  # any. A feature that has never started, a run whose activity carries no
  # attempt yet, an ungoverned run, and a viewer with no legitimate access all
  # degrade to the same `nil` — nothing to show, never an error banner (see
  # specs/34-local-worker-runtime-governance/design.md, "Present the result
  # next to the run's existing activity view").
  defp assign_runtime_projection(socket, actor) do
    assign(socket, :runtime_projection, resolve_runtime_projection(socket, actor))
  end

  defp resolve_runtime_projection(socket, actor) do
    project_id = socket.assigns.project_id

    with run_id when is_binary(run_id) <- socket.assigns[:current_run_id],
         authority <- storage_authority(socket),
         {:ok, run} <- DeliveryStore.fetch_run(authority, project_id, run_id),
         {:ok, attempt} <- DeliveryStore.current_attempt(authority, project_id, run.id),
         {:ok, member} <- ParticipantGuard.authorize(project_id, actor),
         {:ok, result} <-
           LocalWorkerRuntimeProjection.for_run(
             run,
             attempt,
             project_id,
             member.account_id,
             actor
           ) do
      runtime_projection(result)
    else
      _absent -> nil
    end
  end

  defp runtime_projection(:ungoverned), do: nil
  defp runtime_projection({audience, projection}), do: {audience, projection}

  # The question the run is waiting on, if any. A blocked feature keeps its
  # place in `In development`, so the question is what tells a reader why the
  # column stopped moving.
  defp open_question(project_id, actor, feature) do
    case Blocking.for_feature(project_id, actor, feature.id) do
      {:ok, question} -> question
      {:error, :unauthorized} -> nil
    end
  end

  # A question that is not this reader's to answer says so, rather than telling
  # everyone who opens the feature that it is waiting on them.
  defp question_heading(true), do: "Waiting on your decision"
  defp question_heading(false), do: "Waiting on a decision"

  # The delivery store dispatches on the project's owning authority, so the
  # screen has to hand it the same value the domain would. A project whose
  # workspace cannot be resolved yields `nil`, which every store call refuses
  # rather than guessing a store.
  defp storage_authority(%{assigns: %{project: %{workspace_id: workspace_id}}}),
    do: SddOrchestrator.Repo.get(SddOrchestrator.Accounts.PersonalWorkspace, workspace_id)

  defp storage_authority(_socket), do: nil

  defp name(_names, nil), do: nil
  defp name(names, account_id), do: Map.get(names, account_id)

  defp failure_message(nil), do: "The run stopped without recording a reason."

  defp failure_message(reason),
    do: Map.get(@failure_messages, reason, "The run stopped: #{reason}")

  defp guided_parts, do: GuidedRequirements.structure()

  defp requirements_body(parts, key), do: Map.get(parts, key, "")

  # Read only inside the block the checked verdict guards, so there is no
  # absent-assessment clause to keep in step with it.
  defp readiness_blockers(assessment), do: ReadinessAssessment.blockers(assessment)

  defp readiness_suggestions(assessment), do: ReadinessAssessment.suggestions(assessment)

  # The page says a model was not asked only when the stored verdict says so.
  # It never infers it from an empty finding list, which is also what a model
  # that found nothing answers.
  defp guidance_unconfigured?(assessment),
    do: not ReadinessAssessment.guidance_configured?(assessment)

  defp readiness_not_configured, do: @readiness_not_configured

  defp readiness_stale_note, do: @readiness_stale_note

  # A verdict judged one exact revision. Once the specification has moved past
  # it, the findings on screen describe words nobody is looking at any more, so
  # the section says so instead of letting an old answer stand for a new one.
  defp readiness_stale?(nil, _revision_id, _digest), do: false

  defp readiness_stale?(assessment, revision_id, digest)
       when is_binary(revision_id) and is_binary(digest),
       do: not ReadinessAssessment.current_for?(assessment, revision_id, digest)

  defp readiness_stale?(_assessment, _revision_id, _digest), do: true

  # Whether this feature may be made ready, and when it may not, which state
  # says so. The control and the press read this one answer, so nothing is
  # offered that would be refused and nothing is refused that was offered.
  defp make_ready_state(%{lifecycle_column: "draft"}, nil, _revision_id, _digest), do: :unchecked

  defp make_ready_state(%{lifecycle_column: "draft"}, assessment, revision_id, digest) do
    cond do
      readiness_stale?(assessment, revision_id, digest) -> :stale
      not ReadinessAssessment.start_available?(assessment) -> :blocked
      true -> :ready
    end
  end

  defp make_ready_state(_feature, _assessment, _revision_id, _digest), do: :not_draft

  defp make_ready?(feature, assessment, revision_id, digest),
    do: make_ready_state(feature, assessment, revision_id, digest) == :ready

  # The only column a feature comes back from. `In development` is a running
  # agent's, and ending that is cancellation rather than a change of mind.
  defp back_to_draft?(%{lifecycle_column: "ready_for_development"}), do: true
  defp back_to_draft?(_feature), do: false

  defp column_label(column), do: Map.fetch!(@column_labels, column)
  defp status_label(status), do: Map.get(@status_labels, status)
  defp gated_action(column), do: Map.fetch!(@gated_actions, column)

  ## Start preconditions

  defp precondition_label(key), do: Map.fetch!(@precondition_labels, key)
  defp precondition_note(key), do: Map.fetch!(@precondition_notes, key)
  defp precondition_action(key), do: Map.fetch!(@precondition_actions, key)
  defp precondition_owner_only, do: @precondition_owner_only

  # Whether the start may be offered at all: the readout above the button, with
  # every item met. The control and the press read this one list, so nothing is
  # offered that the press would then refuse.
  defp start_offered?(preconditions), do: Enum.all?(preconditions, & &1.met?)

  # Whether the acting person can open the page that resolves one item. The
  # role comes from the `ParticipantGuard` answer this screen already holds, so
  # the readout cannot offer a destination the route itself would refuse.
  defp precondition_linkable?(route, owner?),
    do: owner? or route not in @precondition_owner_routes

  # The page that resolves one precondition, for the three that are elsewhere.
  defp precondition_navigate(:repository_profile, project_id),
    do: ~p"/projects/#{project_id}/profile"

  defp precondition_navigate(:project_connection, project_id),
    do: ~p"/projects/#{project_id}/overview"

  defp precondition_navigate(:ai_connections, _project_id), do: ~p"/ai-connections"
  defp precondition_navigate(_route, _project_id), do: nil

  # The place on this page that resolves one precondition, for the two that are
  # here. Both are sections the reader can already see.
  defp precondition_anchor(:readiness), do: "#readiness-heading"
  defp precondition_anchor(:processing_boundary), do: "#start-disclosure-heading"
  defp precondition_anchor(_route), do: nil

  defp transfer_summary(%{leaves_authoritative_store: false}),
    do: "Stays in this project's own store"

  defp transfer_summary(%{transfers: transfers}),
    do: "Leaves this project's store: " <> Enum.join(transfers, ", ")

  ## Local worker runtime projection

  defp runtime_audience({:owner, _projection}), do: "owner"
  defp runtime_audience({:participant, _projection}), do: "participant"

  defp runtime_owner?({:owner, _projection}), do: true
  defp runtime_owner?({:participant, _projection}), do: false

  defp runtime_field({_audience, projection}, key), do: Map.get(projection, key)

  defp runtime_snapshot({_audience, projection}), do: projection.snapshot

  defp runtime_elapsed({_audience, %{snapshot: %{elapsed_seconds: seconds}}}) do
    minutes = div(seconds, 60)
    remaining = rem(seconds, 60)
    "#{minutes}m #{remaining}s"
  end

  defp runtime_quota_summary(%{state: :unknown}), do: "Unknown"
  defp runtime_quota_summary(%{status: status}), do: "Last reported: #{status}"
  defp runtime_quota_summary(_quota), do: "Unknown"

  ## Verification evidence

  defp evidence_kind_label(kind), do: Map.get(@evidence_kind_labels, kind, "Evidence")
  defp evidence_state_label(outcome), do: Map.get(@evidence_state_labels, outcome, outcome)
  defp evidence_state_variant(outcome), do: Map.get(@evidence_state_variants, outcome, "neutral")
  defp evidence_state_icon(outcome), do: Map.get(@evidence_state_icons, outcome, "info")

  defp evidence_source_label(source),
    do: Map.get(@evidence_source_labels, source, "Recorded by #{source}")

  defp capture_reason_message(nil), do: nil
  defp capture_reason_message(reason), do: Map.get(@capture_reason_messages, reason)

  defp verification_reason_message(nil), do: "The run did not say why."

  defp verification_reason_message(reason),
    do: Map.get(@verification_reasons, reason, "The run refused completion: #{reason}")

  defp redaction_label(true), do: "Redacted before it was stored"
  defp redaction_label(_redacted), do: "Not redacted"

  # A duration is proof of how long the command actually took, so a sub-second
  # result keeps its milliseconds instead of rounding to a reassuring `0 s`.
  defp duration_label(nil), do: "Not recorded"
  defp duration_label(milliseconds) when milliseconds < 1_000, do: "#{milliseconds} ms"

  defp duration_label(milliseconds),
    do: "#{Float.round(milliseconds / 1_000, 1)} s"

  defp byte_size_label(nil), do: nil
  defp byte_size_label(bytes) when bytes < 1_024, do: "#{bytes} bytes"
  defp byte_size_label(bytes), do: "#{Float.round(bytes / 1_024, 1)} KB"

  defp recorded_label(nil), do: "Not recorded"

  defp recorded_label(%DateTime{} = recorded_at),
    do: Calendar.strftime(recorded_at, "%Y-%m-%d %H:%M UTC")

  defp exit_code_label(nil), do: "Not recorded"
  defp exit_code_label(exit_code), do: to_string(exit_code)

  defp check_names(names), do: Enum.join(names, ", ")

  defp viewing?(%{evidence_id: evidence_id}, %{id: evidence_id}), do: true
  defp viewing?(_artifact, _item), do: false

  ## Preview

  defp preview_state_label(state), do: Map.get(@preview_state_labels, state, "Unknown")
  defp preview_state_variant(state), do: Map.get(@preview_state_variants, state, "neutral")
  defp preview_state_icon(state), do: Map.get(@preview_state_icons, state, "info")

  defp preview_cleanup_label(state), do: Map.get(@preview_cleanup_labels, state)

  # An unrecognised code still gets a sentence, because a preview that stopped
  # for a reason this screen has never seen is exactly the one a reader most
  # needs to be told about. The code itself renders beside it as a code.
  defp preview_failure_message(nil), do: "The preview stopped without recording a reason."

  defp preview_failure_message(reason) do
    Map.get(
      @preview_failure_messages,
      reason,
      "The preview stopped for a reason this project does not recognise."
    )
  end

  ## Review

  # The section keeps its heading after the decision is made, because the
  # recorded verdict has nowhere else on this screen to live. It stops claiming
  # the feature is waiting once it no longer is.
  defp review_heading("ready_for_review"), do: "Ready for review"
  defp review_heading(_column), do: "Reviewed"

  defp review_outcome_label(%{decision: outcome}),
    do: Map.get(@review_outcome_labels, outcome, outcome)

  defp review_outcome_icon(%{decision: outcome}),
    do: Map.get(@review_outcome_icons, outcome, "info")

  defp review_outcome_class(%{decision: "approved"}), do: "border-ok-fg/40 bg-ok-bg"
  defp review_outcome_class(_decision), do: "border-err-fg/40 bg-err-bg"

  defp review_outcome_text_class(%{decision: "approved"}), do: "text-ok-fg"
  defp review_outcome_text_class(_decision), do: "text-err-fg"

  # Which of the two things this rejection set in motion, read from the flag the
  # rejection recorded rather than re-derived here. The feature's `Blocked`
  # status cannot answer it — that is also true once the continued run blocks on
  # a question of the agent's own, and telling a reviewer their words paused the
  # run when they did not would be worse than saying nothing.
  defp rejection_outcome(true), do: "blocked"
  defp rejection_outcome(_blocked?), do: "continued"

  defp rejection_note(blocked_for_specification?) do
    if blocked_for_specification? do
      "This feedback is on record and was reported as changing what was agreed. Nothing was sent " <>
        "to the agent: the run is paused on the question above until that is decided and written " <>
        "into the specification. The branch and everything already proved are kept."
    else
      "This feedback is on record. The feature is back in development, and the same run continues " <>
        "on the same branch as a further attempt working from it. Everything already proved is kept."
    end
  end

  # One labelled preview fact, kept apart from the evidence section's own facts
  # so a selector for one can never match the other.
  attr :label, :string, required: true
  attr :test, :string, required: true
  attr :value, :string, default: nil
  attr :class, :any, default: nil

  defp preview_fact(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-baseline gap-x-2 gap-y-0.5", @class]}>
      <dt class="whitespace-nowrap text-ink-muted">{@label}</dt>
      <dd class="min-w-0 break-all text-ink" data-preview-fact={@test}>{@value}</dd>
    </div>
    """
  end

  # One labelled provenance value. The label never wraps and the value may,
  # because a broken label reads as a different field while a broken commit or
  # digest is still the same value.
  attr :label, :string, required: true
  attr :test, :string, required: true
  attr :value, :string, default: nil
  attr :class, :any, default: nil

  defp evidence_fact(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-baseline gap-x-2 gap-y-0.5", @class]}>
      <dt class="whitespace-nowrap text-ink-muted">{@label}</dt>
      <dd class="min-w-0 break-all text-ink" data-evidence-fact={@test}>{@value}</dd>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <.app_shell max_width="max-w-2xl">
      <div data-screen="feature-detail" data-feature-id={@feature.id}>
        <%!-- One feature lives under the board, so `Features` is the current
        destination without being this exact page. --%>
        <.project_nav
          project_id={@project_id}
          current={:features}
          exact?={false}
          owner?={@owner?}
          class="mb-6"
        />

        <.live_component
          module={SddOrchestratorWeb.ProjectAssistantPanel}
          id={"project-assistant-" <> @project_id}
          project_id={@project_id}
          actor={@actor}
          account={@current_account}
        />

        <h1 class="text-xl font-bold text-ink" data-feature-title>{@feature.title}</h1>

        <div class="mt-3 flex flex-wrap items-center gap-2">
          <span
            class="rounded-full border border-line-strong px-2.5 py-1 text-xs text-ink-muted"
            data-feature-column
          >
            {column_label(@feature.lifecycle_column)}
          </span>
          <span
            :if={status_label(@feature.status)}
            class="inline-flex items-center gap-1.5 rounded-full border border-err-fg/40 bg-err-bg px-2.5 py-1 text-xs text-err-fg"
            data-feature-status
          >
            <.lucide name="circle-alert" class="size-3.5" />
            {status_label(@feature.status)}
          </span>
        </div>

        <%!-- The feature's own words come first: this is what a person opens
        the page to write, and everything below it judges or acts on it. --%>
        <section
          class="mt-6 rounded-lg border border-line bg-surface p-4"
          aria-labelledby="requirements-heading"
          data-requirements
        >
          <h2 id="requirements-heading" class="text-[13px] font-semibold text-ink">
            What this feature should do
          </h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Write it in your own words. Each save keeps a new version, so nothing you wrote
            before is lost.
          </p>

          <p
            :if={is_nil(@requirements_revision_id)}
            class="mt-3 text-[13px] leading-relaxed text-ink-muted"
            data-requirements-unavailable
          >
            This feature has no specification of its own, so there is nowhere to write this
            down yet.
          </p>

          <form
            :if={@requirements_revision_id}
            id="requirements-form"
            phx-change="validate_requirements"
            phx-submit="save_requirements"
            class="mt-4"
            data-requirements-form
          >
            <div :for={part <- guided_parts()} class="mt-4 first:mt-0">
              <label
                for={"requirements-#{part.key}"}
                class="block text-[13px] font-semibold text-ink"
              >
                {part.label}
              </label>
              <textarea
                id={"requirements-#{part.key}"}
                name={"requirements[#{part.key}]"}
                rows="3"
                aria-describedby={"requirements-#{part.key}-hint"}
                class={[
                  "mt-1.5 w-full rounded-lg border bg-surface px-3 py-2 text-sm text-ink outline-none",
                  "focus:outline-solid focus:outline-2 focus:outline-offset-0 focus:outline-focus",
                  (@requirements_error && "border-err-fg") || "border-line-strong focus:border-focus"
                ]}
                phx-debounce="200"
                data-requirements-part={part.key}
              >{requirements_body(@requirements_parts, part.key)}</textarea>
              <p
                id={"requirements-#{part.key}-hint"}
                class="mt-2 text-xs text-ink-muted"
                data-requirements-hint={part.key}
              >
                {part.hint}
              </p>
            </div>

            <p
              :if={@requirements_error}
              class="mt-4 flex items-start gap-1.5 text-xs text-err-fg"
              data-requirements-error
            >
              <.lucide name="circle-alert" class="size-3.5 flex-none" />
              {@requirements_error}
            </p>

            <.button type="submit" class="mt-4 w-full sm:w-auto" data-save-requirements>
              <.lucide name="check" class="size-4" /> Save
            </.button>
          </form>
        </section>

        <%!-- What the words above still need. Blockers first, because they are
        the only ones that stop development. --%>
        <section
          class="mt-6 rounded-lg border border-line bg-surface p-4"
          aria-labelledby="readiness-heading"
          data-readiness
        >
          <h2 id="readiness-heading" class="text-[13px] font-semibold text-ink">
            What is still missing
          </h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Check this before development starts. Every empty part is a blocker.
          </p>

          <.button
            type="button"
            phx-click="check_readiness"
            class="mt-3 w-full sm:w-auto"
            data-check-readiness
          >
            <.lucide name="circle-check" class="size-4" /> Check readiness
          </.button>

          <p
            :if={@readiness_error}
            class="mt-3 flex items-start gap-1.5 text-xs text-err-fg"
            data-readiness-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@readiness_error}
          </p>

          <p
            :if={is_nil(@readiness)}
            class="mt-3 text-[13px] leading-relaxed text-ink-muted"
            data-readiness-unchecked
          >
            This has not been checked yet.
          </p>

          <div :if={@readiness} data-readiness-checked>
            <%!-- The verdict comes first when it is about older words, because
            everything under it is then a judgement of text nobody can see. --%>
            <div
              :if={readiness_stale?(@readiness, @requirements_revision_id, @requirements_digest)}
              class="mt-3"
              data-readiness-stale
            >
              <.notice variant="warn" icon="triangle-alert">
                {readiness_stale_note()}
              </.notice>
            </div>

            <p
              :if={guidance_unconfigured?(@readiness)}
              class="mt-3 text-[13px] leading-relaxed text-ink-muted"
              data-readiness-guidance="not_configured"
            >
              {readiness_not_configured()}
            </p>

            <div :if={readiness_blockers(@readiness) != []} class="mt-4" data-readiness-blockers>
              <h3 class="text-[13px] font-semibold text-ink">Blockers</h3>
              <ul class="mt-2 flex flex-col gap-2">
                <li
                  :for={finding <- readiness_blockers(@readiness)}
                  class="rounded-lg border border-err-fg/40 bg-err-bg p-3"
                  data-readiness-blocker={finding["id"]}
                >
                  <p class="flex items-start gap-1.5 text-[13px] font-semibold text-err-fg">
                    <.lucide name="circle-alert" class="size-3.5 flex-none" />
                    {finding["summary"]}
                  </p>
                  <p class="mt-1 text-[13px] leading-relaxed text-ink">
                    {finding["explanation"]}
                  </p>
                </li>
              </ul>
            </div>

            <div
              :if={readiness_suggestions(@readiness) != []}
              class="mt-4"
              data-readiness-suggestions
            >
              <h3 class="text-[13px] font-semibold text-ink">Suggestions</h3>
              <ul class="mt-2 flex flex-col gap-2">
                <li
                  :for={finding <- readiness_suggestions(@readiness)}
                  class="rounded-lg border border-line p-3"
                  data-readiness-suggestion={finding["id"]}
                >
                  <p class="flex items-start gap-1.5 text-[13px] font-semibold text-ink">
                    <.lucide name="info" class="size-3.5 flex-none" />
                    {finding["summary"]}
                  </p>
                  <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                    {finding["explanation"]}
                  </p>
                  <.button
                    type="button"
                    variant="secondary"
                    size="sm"
                    phx-click="dismiss_suggestion"
                    phx-value-id={finding["id"]}
                    class="mt-3 w-full sm:w-auto"
                    data-dismiss-suggestion={finding["id"]}
                  >
                    <.lucide name="x" class="size-4" /> Dismiss
                  </.button>
                </li>
              </ul>
            </div>

            <p
              :if={readiness_blockers(@readiness) == [] and readiness_suggestions(@readiness) == []}
              class="mt-3 text-[13px] leading-relaxed text-ink"
              data-readiness-clear
            >
              Nothing is blocking this feature.
            </p>
          </div>

          <%!-- The two moves the board withholds. They live with the findings
          because the findings are what decides whether either is offered. --%>
          <p
            :if={@lifecycle_error}
            class="mt-4 flex items-start gap-1.5 text-xs text-err-fg"
            data-lifecycle-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@lifecycle_error}
          </p>

          <div
            :if={
              make_ready?(@feature, @readiness, @requirements_revision_id, @requirements_digest) or
                back_to_draft?(@feature)
            }
            class="mt-4 flex flex-col gap-3 sm:flex-row"
          >
            <.button
              :if={make_ready?(@feature, @readiness, @requirements_revision_id, @requirements_digest)}
              type="button"
              phx-click="make_ready"
              class="w-full sm:w-auto"
              data-make-ready
            >
              <.lucide name="check" class="size-4" /> Make ready
            </.button>

            <.button
              :if={back_to_draft?(@feature)}
              type="button"
              variant="secondary"
              phx-click="back_to_draft"
              class="w-full sm:w-auto"
              data-back-to-draft
            >
              <.lucide name="arrow-left" class="size-4" /> Back to draft
            </.button>
          </div>
        </section>

        <section
          :if={@feature.lifecycle_column == "ready_for_review" or @review_decision}
          class="mt-6 rounded-lg border border-ok-fg/40 bg-ok-bg p-4"
          aria-labelledby="review-handoff-heading"
          data-review-handoff
        >
          <h2
            id="review-handoff-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-ok-fg"
          >
            <.lucide name="circle-check" class="size-4 flex-none" />
            <span class="whitespace-nowrap">{review_heading(@feature.lifecycle_column)}</span>
          </h2>

          <div :if={@feature.lifecycle_column == "ready_for_review"}>
            <p class="mt-2 text-[13px] leading-relaxed text-ink">
              Development finished and every required check passed for the commit below. Nothing is
              done until a person says so, and approving moves this feature to Done.
            </p>
            <p :if={is_nil(@review_decision)} class="mt-2 text-sm text-ink" data-review-responsible>
              Waiting on {@responsible || "the project owner"}.
            </p>
            <p :if={@verification} class="mt-2 text-xs text-ink-muted" data-review-branch>
              The work is on {@verification.branch}.
            </p>
            <p :if={@verification} class="mt-1 text-xs text-ink-muted" data-review-commit>
              Reviewing commit {@verification.commit_sha}.
            </p>
          </div>

          <%!-- The verdict is read from the decision record, never from the
          activity payload: the payload deliberately carries a bounded excerpt,
          and feedback a reviewer wrote in full must be readable in full by the
          person who has to act on it. --%>
          <div
            :if={@review_decision}
            class={["mt-4 rounded-lg border p-3.5", review_outcome_class(@review_decision)]}
            data-review-decision
            data-review-decision-outcome={@review_decision.decision}
          >
            <p class={[
              "flex items-center gap-1.5 text-[13px] font-semibold",
              review_outcome_text_class(@review_decision)
            ]}>
              <.lucide name={review_outcome_icon(@review_decision)} class="size-4 flex-none" />
              <span class="whitespace-nowrap" data-review-decision-label>
                {review_outcome_label(@review_decision)}
              </span>
            </p>

            <p class="mt-2 text-sm text-ink" data-review-decision-reviewer>
              Decided by {name(@names, @review_decision.reviewer_account_id) || "A former member"}.
            </p>

            <p
              :if={@review_decision.feedback}
              class="mt-2 whitespace-pre-line break-words text-sm text-ink"
              data-review-decision-feedback
            >
              {@review_decision.feedback}
            </p>

            <%!-- A rejection does not stop at the verdict: the work goes back to
            `In development` and the same run carries on, so the note says which
            of the two things this feedback actually set in motion rather than
            leaving a reader to read the moved column as a fault. --%>
            <p
              :if={@review_decision.decision == "rejected"}
              class="mt-2 text-xs text-ink-muted"
              data-review-decision-note
              data-review-decision-continuation={rejection_outcome(@review_blocked_for_spec?)}
            >
              {rejection_note(@review_blocked_for_spec?)}
            </p>

            <dl class="mt-3 flex flex-col gap-1.5 text-xs">
              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <dt class="whitespace-nowrap text-ink-muted">Branch</dt>
                <dd class="min-w-0 break-all text-ink" data-review-decision-branch>
                  {@review_decision.branch}
                </dd>
              </div>
              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
                <dt class="whitespace-nowrap text-ink-muted">Commit</dt>
                <dd class="min-w-0 break-all text-ink" data-review-decision-commit>
                  {@review_decision.commit_sha}
                </dd>
              </div>
            </dl>
          </div>

          <%!-- Only the two people the domain would accept are offered these
          controls. Everyone else reads the same state without a control whose
          press would be refused. --%>
          <div :if={@reviewable?} class="mt-4" data-review-controls>
            <.button type="button" phx-click="approve" class="w-full sm:w-auto" data-review-approve>
              <.lucide name="check" class="size-4" /> Approve
            </.button>

            <form
              id="review-form"
              phx-change="validate_review"
              phx-submit="reject"
              class="mt-4"
            >
              <label for="review-feedback" class="block text-[13px] font-semibold text-ink">
                Send it back with feedback
              </label>
              <textarea
                id="review-feedback"
                name="review[feedback]"
                rows="3"
                maxlength={ReviewDecision.max_feedback_bytes()}
                aria-required="true"
                aria-invalid={(@review_error && "true") || nil}
                aria-describedby={
                  (@review_error && "review-feedback-error") || "review-feedback-hint"
                }
                class={[
                  "mt-1.5 w-full rounded-lg border bg-surface px-3 py-2 text-sm text-ink outline-none",
                  "focus:outline-solid focus:outline-2 focus:outline-offset-0 focus:outline-focus",
                  (@review_error && "border-err-fg") || "border-line-strong focus:border-focus"
                ]}
                phx-debounce="200"
                data-review-feedback
              >{@review_feedback}</textarea>
              <p
                :if={@review_error}
                id="review-feedback-error"
                class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
                data-review-error
              >
                <.lucide name="circle-alert" class="size-3.5 flex-none" />
                {@review_error}
              </p>
              <p :if={!@review_error} id="review-feedback-hint" class="mt-2 text-xs text-ink-muted">
                Sending work back has to say what needs to change. The next attempt works from it.
              </p>

              <%!-- The reviewer declares this; it is never read out of what they
              wrote. An agent deciding what the approved agreement means is
              exactly what the specification write-back exists to prevent, so
              the product asks instead of inferring. --%>
              <label
                class="mt-4 flex items-start gap-2.5 text-[13px] font-semibold text-ink"
                data-review-contradiction-label
              >
                <input
                  type="checkbox"
                  name="review[contradicts_agreement]"
                  value="true"
                  checked={@review_contradicts?}
                  aria-describedby="review-contradiction-hint"
                  class={[
                    "mt-0.5 size-4 flex-none rounded border-line-strong",
                    "focus:outline-solid focus:outline-2 focus:outline-offset-2 focus:outline-focus"
                  ]}
                  data-review-contradiction
                />
                <span>This changes what we agreed to build</span>
              </label>
              <p
                id="review-contradiction-hint"
                class="mt-1.5 pl-7 text-xs text-ink-muted"
                data-review-contradiction-hint
              >
                Leave this off and the same run goes straight back to work from your feedback. Turn
                it on and the feedback is raised as a question for the specification instead, so the
                agreement is decided before any further attempt runs.
              </p>

              <.button
                variant="secondary"
                type="submit"
                class="mt-4 w-full sm:w-auto"
                data-review-reject
              >
                <.lucide name="arrow-left" class="size-4" /> Send back
              </.button>
            </form>
          </div>
        </section>

        <section
          :if={@failed_run}
          class="mt-6 rounded-lg border border-err-fg/40 bg-err-bg p-4"
          aria-labelledby="failed-run-heading"
          data-failed-run
        >
          <h2
            id="failed-run-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-err-fg"
          >
            <.lucide name="circle-alert" class="size-4 flex-none" /> Development stopped
          </h2>
          <p class="mt-2 text-sm text-ink" data-failed-reason>
            {failure_message(@failed_run.failure_reason)}
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-failed-branch>
            The work so far is kept on {@failed_run.branch}. Retrying continues it.
          </p>

          <p
            :if={@retry_error}
            class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
            data-retry-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@retry_error}
          </p>

          <.button type="button" phx-click="retry" class="mt-4 w-full sm:w-auto" data-retry-run>
            <.lucide name="refresh-cw" class="size-4" /> Retry
          </.button>
        </section>

        <section
          :if={@cancelable_run}
          class="mt-6 rounded-lg border border-line p-4"
          aria-labelledby="run-control-heading"
          data-run-control
        >
          <h2 id="run-control-heading" class="text-[13px] font-semibold text-ink">This run</h2>
          <p class="mt-2 text-xs text-ink-muted" data-run-branch>
            The work is on {@cancelable_run.branch}.
          </p>
          <p class="mt-2 text-xs text-ink-muted">
            Canceling is final. Everything recorded so far is kept, and picking this feature up again
            starts a new run on a new branch.
          </p>

          <p
            :if={@cancel_error}
            class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
            data-cancel-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@cancel_error}
          </p>

          <.button
            variant="secondary"
            type="button"
            phx-click="cancel"
            class="mt-4 w-full sm:w-auto"
            data-cancel-run
          >
            <.lucide name="x" class="size-4" /> Cancel run
          </.button>
        </section>

        <section
          :if={@runtime_projection}
          class="mt-6 rounded-lg border border-line p-4"
          aria-labelledby="runtime-projection-heading"
          data-runtime-projection
          data-runtime-audience={runtime_audience(@runtime_projection)}
        >
          <h2
            id="runtime-projection-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-ink"
          >
            <.lucide name="info" class="size-4 flex-none" /> AI runtime
          </h2>

          <dl class="mt-2 grid grid-cols-1 gap-x-4 gap-y-2 text-xs text-ink-muted sm:grid-cols-2">
            <div :if={runtime_owner?(@runtime_projection)} data-runtime-connection>
              <dt class="font-semibold text-ink">Connection</dt>
              <dd>
                {runtime_field(@runtime_projection, :provider)} · {runtime_field(
                  @runtime_projection,
                  :authentication_mode
                )}
              </dd>
            </div>
            <div data-runtime-model>
              <dt class="font-semibold text-ink">Model</dt>
              <dd>
                {runtime_field(@runtime_projection, :model)} ({runtime_field(
                  @runtime_projection,
                  :effort
                )} effort)
              </dd>
            </div>
            <div data-runtime-status>
              <dt class="font-semibold text-ink">Status</dt>
              <dd>
                {runtime_snapshot(@runtime_projection).status} · {runtime_elapsed(@runtime_projection)}
              </dd>
            </div>
            <div :if={runtime_owner?(@runtime_projection)} data-runtime-quota>
              <dt class="font-semibold text-ink">Quota</dt>
              <dd>{runtime_quota_summary(runtime_field(@runtime_projection, :quota))}</dd>
            </div>
            <div data-runtime-tokens>
              <dt class="font-semibold text-ink">Tokens</dt>
              <dd>Unknown</dd>
            </div>
            <div :if={runtime_owner?(@runtime_projection)} data-runtime-cost>
              <dt class="font-semibold text-ink">Cost</dt>
              <dd>Unknown</dd>
            </div>
          </dl>
        </section>

        <section
          :if={@question}
          class="mt-6 rounded-lg border border-err-fg/40 bg-err-bg p-4"
          aria-labelledby="blocking-question-heading"
          data-blocking-question
        >
          <h2
            id="blocking-question-heading"
            class="flex items-center gap-1.5 text-[13px] font-semibold text-err-fg"
          >
            <.lucide name="circle-alert" class="size-4 flex-none" />
            {question_heading(@question_for_me?)}
          </h2>
          <p class="mt-2 text-sm text-ink" data-question-text>{@question.question}</p>
          <p
            :if={@question.context}
            class="mt-2 text-[13px] leading-relaxed text-ink-muted"
            data-question-context
          >
            {@question.context}
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-question-responder>
            Answered by {@responsible || "the project owner"}.
          </p>
          <p class="mt-2 text-xs text-ink-muted" data-question-branch>
            The work so far is kept on {@question.branch}.
          </p>

          <form
            :if={@question_for_me?}
            id="answer-form"
            phx-submit="answer"
            class="mt-4"
            data-answer-form
          >
            <.text_field
              id="answer-body"
              name="answer[body]"
              label="Your decision"
              value={@answer_body}
              error={@answer_error}
              hint="This is written into the specification before the run continues."
              autocomplete="off"
            />
            <.button type="submit" class="mt-3 w-full sm:w-auto" data-submit-answer>
              <.lucide name="check" class="size-4" /> Answer and continue
            </.button>
          </form>
        </section>

        <dl class="mt-6 flex flex-col gap-3">
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Created by</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-creator>
              {name(@names, @feature.creator_account_id) || "A former member"}
            </dd>
          </div>
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Assigned to</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-assignee>
              {name(@names, @feature.assigned_account_id) || "Nobody yet"}
            </dd>
          </div>
          <div class="rounded-lg border border-line bg-surface p-3.5">
            <dt class="text-[13px] font-semibold text-ink-muted">Answers questions</dt>
            <dd class="mt-1 text-sm text-ink" data-feature-responsible>
              {@responsible || "The project owner"}
            </dd>
          </div>
        </dl>

        <section class="mt-6 rounded-lg border border-line bg-surface p-4" data-assignment>
          <h2 class="text-[13px] font-semibold text-ink">Who is working on this</h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Anyone on this project can pick who it is assigned to. Questions during development
            go to that person, or to whoever created the feature when nobody is assigned.
          </p>

          <form id="assignment-form" phx-change="assign" class="mt-4">
            <label for="assignment-account" class="block text-[13px] font-semibold text-ink">
              Assigned to
            </label>
            <select
              id="assignment-account"
              name="assignment[account_id]"
              class={[
                "mt-1.5 w-full h-10 rounded-lg border bg-surface px-3 text-sm text-ink outline-none",
                "focus:outline focus:outline-2 focus:outline-offset-0 focus:outline-focus",
                (@assignment_error && "border-err-fg") || "border-line-strong focus:border-focus"
              ]}
              aria-invalid={(@assignment_error && "true") || nil}
              aria-describedby={(@assignment_error && "assignment-error") || nil}
              data-assignment-select
            >
              <option value="" selected={is_nil(@feature.assigned_account_id)}>Nobody yet</option>
              <option
                :for={member <- @members}
                value={member.account_id}
                selected={member.account_id == @feature.assigned_account_id}
              >
                {member.display_name}
              </option>
            </select>
            <p
              :if={@assignment_error}
              id="assignment-error"
              class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
              data-assignment-error
            >
              <.lucide name="circle-alert" class="size-3.5 flex-none" />
              {@assignment_error}
            </p>
          </form>

          <div class="mt-3 flex flex-col gap-3 sm:flex-row sm:items-center">
            <.button
              type="button"
              variant="secondary"
              phx-click="assign_to_me"
              class="w-full sm:w-auto"
              data-assign-to-me
            >
              <.lucide name="user-round-pen" class="size-4" /> Assign to me
            </.button>
          </div>
        </section>

        <section
          :if={@owner?}
          class="mt-6 rounded-lg border border-line bg-surface p-4"
          data-specification-link
        >
          <h2 class="text-[13px] font-semibold text-ink">Linked specification</h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Link this feature to the specification it delivers, so other tools can find its
            board progress from that specification. Optional, and only you can change it.
          </p>

          <form id="specification-link-form" phx-change="link_specification" class="mt-4">
            <label
              for="specification-link-select"
              class="block text-[13px] font-semibold text-ink"
            >
              Specification
            </label>
            <select
              id="specification-link-select"
              name="specification[specification_id]"
              class={[
                "mt-1.5 w-full h-10 rounded-lg border bg-surface px-3 text-sm text-ink outline-none",
                "focus:outline focus:outline-2 focus:outline-offset-0 focus:outline-focus",
                (@specification_link_error && "border-err-fg") ||
                  "border-line-strong focus:border-focus"
              ]}
              aria-invalid={(@specification_link_error && "true") || nil}
              aria-describedby={(@specification_link_error && "specification-link-error") || nil}
              data-specification-link-select
            >
              <option value="" selected={is_nil(@feature.specification_id)}>Not linked</option>
              <option
                :for={spec <- @available_specifications}
                value={spec.id}
                selected={spec.id == @feature.specification_id}
              >
                {spec.title}
              </option>
            </select>
            <p
              :if={@specification_link_error}
              id="specification-link-error"
              class="mt-2 flex items-center gap-1.5 text-xs text-err-fg"
              data-specification-link-error
            >
              <.lucide name="circle-alert" class="size-3.5 flex-none" />
              {@specification_link_error}
            </p>
          </form>
        </section>

        <div class="mt-6 rounded-lg border border-line bg-surface p-4" data-gated-action>
          <p class="text-[13px] font-semibold text-ink">What happens next</p>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            {gated_action(@feature.lifecycle_column)}
          </p>
        </div>

        <section
          :if={@feature.lifecycle_column == "ready_for_development"}
          class="mt-6 rounded-lg border border-line bg-surface p-4"
          aria-labelledby="start-disclosure-heading"
          data-start-disclosure
          data-disclosure-confirmed={to_string(@disclosure_confirmed?)}
        >
          <h2 id="start-disclosure-heading" class="text-[13px] font-semibold text-ink">
            Before development starts
          </h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Starting development runs a coding agent against this project. Here is where that
            happens and what it can see.
          </p>

          <dl class="mt-3 flex flex-col gap-2 text-[13px]">
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Runs on</dt>
              <dd class="text-ink" data-disclosure-location>{@disclosure.execution_location}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Coding agent</dt>
              <dd class="text-ink" data-disclosure-agent>{@disclosure.agent_provider}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Model provider</dt>
              <dd class="text-ink" data-disclosure-model>{@disclosure.model_provider}</dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Preview</dt>
              <dd class="text-ink" data-disclosure-preview>
                {@disclosure.preview_provider || "No preview is configured"}
              </dd>
            </div>
            <div class="flex flex-wrap gap-1.5">
              <dt class="text-ink-muted">Project content</dt>
              <dd class="text-ink" data-disclosure-transfer>
                {transfer_summary(@disclosure)}
              </dd>
            </div>
          </dl>

          <div :if={@boundary_changed?} class="mt-3" data-disclosure-changed>
            <.notice variant="warn" icon="triangle-alert">
              This changed while you were reading it. Check it again before confirming.
            </.notice>
          </div>

          <p
            :if={@disclosure_confirmed?}
            class="mt-3 inline-flex items-center gap-1.5 text-[13px] text-ok-fg"
            data-disclosure-acknowledged
          >
            <.lucide name="circle-check" class="size-4" /> You confirmed this boundary.
          </p>

          <.button
            :if={not @disclosure_confirmed?}
            type="button"
            phx-click="confirm_boundary"
            phx-value-digest={@disclosure.digest}
            class="mt-3 w-full sm:w-auto"
            data-confirm-boundary
          >
            <.lucide name="check" class="size-4" /> I understand, continue
          </.button>

          <%!-- Every start precondition, met or not, with the one place each
          unmet one is resolved. It is a readout, not a hidden gate: a person who
          cannot start yet reads why here rather than finding no button. --%>
          <div class="mt-4 border-t border-line pt-4" data-start-preconditions>
            <h3 class="text-[13px] font-semibold text-ink">Before you can start</h3>
            <ul class="mt-2 flex flex-col gap-3">
              <li
                :for={item <- @start_preconditions}
                data-start-precondition={item.key}
                data-precondition-met={to_string(item.met?)}
              >
                <p class={[
                  "flex items-start gap-1.5 text-[13px]",
                  (item.met? && "text-ok-fg") || "text-err-fg"
                ]}>
                  <.lucide
                    name={(item.met? && "circle-check") || "circle-alert"}
                    class="size-3.5 flex-none translate-y-0.5"
                  />
                  {precondition_label(item.key)}
                </p>
                <p :if={not item.met?} class="mt-1 text-[13px] leading-relaxed text-ink-muted">
                  {precondition_note(item.key)}
                </p>
                <%!-- Three of the five are resolved on another page and two on
                this one, so a link carries whichever of the two destinations
                applies and `<.link>` renders the right anchor for it. --%>
                <.link
                  :if={not item.met? and precondition_linkable?(item.route, @owner?)}
                  navigate={precondition_navigate(item.route, @project_id)}
                  href={precondition_anchor(item.route)}
                  class="mt-1 inline-flex items-center gap-1.5 rounded text-[13px] font-semibold text-primary underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  data-precondition-route={item.key}
                >
                  {precondition_action(item.key)}
                  <.lucide name="arrow-right" class="size-3.5 flex-none" />
                </.link>
                <p
                  :if={not item.met? and not precondition_linkable?(item.route, @owner?)}
                  class="mt-1 text-[13px] leading-relaxed text-ink-muted"
                  data-precondition-owner-only={item.key}
                >
                  {precondition_owner_only()}
                </p>
              </li>
            </ul>

            <%!-- The last step of the start flow, and the only control that
            begins a run. It is offered only where the list above is fully met,
            and the press asks that same list again before anything happens. --%>
            <.button
              :if={start_offered?(@start_preconditions)}
              type="button"
              phx-click="start_development"
              class="mt-4 w-full sm:w-auto"
              data-start-development
            >
              <.lucide name="play" class="size-4" /> Start development
            </.button>

            <%!-- Read after the button is already gone in the case that matters
            most: the item that stopped the press is unmet again above, and this
            says which one it was. --%>
            <p
              :if={@start_error}
              class="mt-3 flex items-start gap-1.5 text-[13px] text-err-fg"
              data-start-error
            >
              <.lucide name="circle-alert" class="size-3.5 flex-none translate-y-0.5" />
              {@start_error}
            </p>
          </div>
        </section>

        <section class="mt-6" aria-labelledby="evidence-heading" data-evidence>
          <h2 id="evidence-heading" class="text-[13px] font-semibold text-ink">
            Verification evidence
          </h2>
          <p class="mt-1 text-[13px] leading-relaxed text-ink-muted">
            Every item here is a command that ran, kept exactly as it was recorded. A result a later
            run replaced stays visible, and so does a check that reported nothing.
          </p>

          <div
            :if={@verification}
            class={[
              "mt-3 rounded-lg border p-4",
              (@verification.verified? && "border-ok-fg/40 bg-ok-bg") || "border-err-fg/40 bg-err-bg"
            ]}
            data-verification
            data-verification-outcome={(@verification.verified? && "verified") || "refused"}
          >
            <h3 class={[
              "flex items-center gap-1.5 text-[13px] font-semibold",
              (@verification.verified? && "text-ok-fg") || "text-err-fg"
            ]}>
              <.lucide
                name={(@verification.verified? && "circle-check") || "circle-alert"}
                class="size-4 flex-none"
              />
              <span class="whitespace-nowrap" data-verification-label>
                {(@verification.verified? && "Verified") || "Not verified"}
              </span>
            </h3>

            <p
              :if={not @verification.verified?}
              class="mt-2 text-sm text-ink"
              data-verification-reason
            >
              {verification_reason_message(@verification.reason)}
            </p>

            <p class="mt-2 text-xs text-ink-muted" data-verification-counts>
              {@verification.passed_count} of {@verification.required_count} required checks passed
              for this commit.
            </p>

            <dl class="mt-2 flex flex-col gap-1.5 text-xs">
              <.evidence_fact
                :if={@verification.failed != []}
                label="Failed"
                test="verification-failed"
                value={check_names(@verification.failed)}
              />
              <.evidence_fact
                :if={@verification.missing != []}
                label="No result"
                test="verification-missing"
                value={check_names(@verification.missing)}
              />
              <.evidence_fact
                :if={@verification.unsupported != []}
                label="Could not run"
                test="verification-unsupported"
                value={check_names(@verification.unsupported)}
              />
              <.evidence_fact
                :if={@verification.screenshot_failed != []}
                label="Capture broke"
                test="verification-screenshot-failed"
                value={check_names(@verification.screenshot_failed)}
              />
              <.evidence_fact
                :if={@verification.branch}
                label="Branch"
                test="verification-branch"
                value={@verification.branch}
              />
              <.evidence_fact
                :if={@verification.commit_sha}
                label="Commit"
                test="verification-commit"
                value={@verification.commit_sha}
              />
            </dl>
          </div>

          <p
            :if={@evidence_artifact_error}
            class="mt-3 flex items-center gap-1.5 text-xs text-err-fg"
            role="alert"
            data-evidence-artifact-error
          >
            <.lucide name="circle-alert" class="size-3.5 flex-none" />
            {@evidence_artifact_error}
          </p>

          <ul :if={@evidence != []} class="mt-3 flex flex-col gap-3" data-evidence-list>
            <li
              :for={item <- @evidence}
              class="rounded-lg border border-line bg-surface p-3.5"
              data-evidence-item
              data-evidence-id={item.id}
              data-evidence-kind={item.kind}
              data-evidence-state={item.outcome}
              data-evidence-superseded={to_string(item.superseded?)}
            >
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="min-w-0 break-words text-sm font-semibold text-ink" data-evidence-name>
                  {item.name}
                </h3>
                <span class="whitespace-nowrap" data-evidence-type>
                  <.badge variant="neutral" icon="shield">{evidence_kind_label(item.kind)}</.badge>
                </span>
                <span class="whitespace-nowrap" data-evidence-state-label>
                  <.badge
                    variant={evidence_state_variant(item.outcome)}
                    icon={evidence_state_icon(item.outcome)}
                  >
                    {evidence_state_label(item.outcome)}
                  </.badge>
                </span>
                <span
                  :if={item.superseded?}
                  class="whitespace-nowrap"
                  data-evidence-superseded-label
                >
                  <.badge variant="neutral" icon="refresh-cw">Replaced</.badge>
                </span>
              </div>

              <p
                :if={item.superseded?}
                class="mt-2 text-xs text-ink-muted"
                data-evidence-replacement
              >
                A later result replaced this one. It stays here because what was proved before is
                part of how this commit was reached. Replaced by {item.replaced_by_ref}.
              </p>

              <p
                :if={capture_reason_message(item.capture_reason)}
                class="mt-2 text-xs text-ink-muted"
                data-evidence-capture-reason
              >
                {capture_reason_message(item.capture_reason)}
              </p>

              <dl class="mt-3 grid grid-cols-1 gap-x-5 gap-y-1.5 text-xs sm:grid-cols-2">
                <.evidence_fact label="Run" test="run" value={item.run_ref} />
                <.evidence_fact
                  label="Attempt"
                  test="attempt"
                  value={item.attempt_ref || "Not recorded"}
                />
                <.evidence_fact label="Branch" test="branch" value={item.branch} />
                <.evidence_fact
                  label="Source"
                  test="source"
                  value={evidence_source_label(item.source)}
                />
                <.evidence_fact
                  label="Recorded"
                  test="recorded"
                  value={recorded_label(item.recorded_at)}
                />
                <.evidence_fact
                  label="Duration"
                  test="duration"
                  value={duration_label(item.duration_ms)}
                />
                <.evidence_fact
                  :if={item.kind == "required_check"}
                  label="Exit code"
                  test="exit-code"
                  value={exit_code_label(item.exit_code)}
                />
                <.evidence_fact
                  label="Redaction"
                  test="redaction"
                  value={redaction_label(item.redacted)}
                />
                <.evidence_fact
                  :if={item.content_type}
                  label="Stored proof"
                  test="artifact"
                  value={"#{item.content_type}, #{byte_size_label(item.byte_size)}"}
                />
                <.evidence_fact
                  :if={item.command}
                  label="Command"
                  test="command"
                  value={item.command}
                  class="sm:col-span-2"
                />
                <.evidence_fact
                  label="Commit"
                  test="commit"
                  value={item.commit_sha}
                  class="sm:col-span-2"
                />
                <.evidence_fact
                  label="Digest"
                  test="digest"
                  value={item.digest}
                  class="sm:col-span-2"
                />
              </dl>

              <.button
                :if={item.artifact_available? and not viewing?(@evidence_artifact, item)}
                type="button"
                variant="secondary"
                phx-click="view_evidence"
                phx-value-id={item.id}
                class="mt-3 w-full sm:w-auto"
                data-view-evidence
              >
                <.lucide name="search" class="size-4" /> View this proof
              </.button>

              <div
                :if={viewing?(@evidence_artifact, item)}
                class="mt-3 rounded-lg border border-line bg-canvas p-3"
                data-evidence-artifact
              >
                <img
                  :if={@evidence_artifact.inline?}
                  src={@evidence_artifact.data}
                  alt={"The stored proof recorded for #{item.name}"}
                  class="max-w-full rounded border border-line"
                  data-evidence-image
                />
                <p
                  :if={not @evidence_artifact.inline?}
                  class="text-xs text-ink-muted"
                  data-evidence-not-viewable
                >
                  This proof is {@evidence_artifact.content_type}, which cannot be shown here.
                </p>
                <p class="mt-2 text-xs text-ink-muted" data-evidence-artifact-note>
                  {redaction_label(@evidence_artifact.redacted)}. It is read from this project's own
                  private store each time it is opened and has no address of its own.
                </p>

                <.button
                  type="button"
                  variant="secondary"
                  phx-click="hide_evidence"
                  class="mt-3 w-full sm:w-auto"
                  data-hide-evidence
                >
                  <.lucide name="x" class="size-4" /> Hide
                </.button>
              </div>
            </li>
          </ul>

          <p :if={@evidence == []} class="mt-3 text-xs text-ink-muted" data-evidence-empty>
            Nothing has been proved about this feature yet.
          </p>
        </section>

        <section
          class="mt-6"
          aria-labelledby="preview-heading"
          data-preview
          data-preview-state={@preview.state}
        >
          <h2 id="preview-heading" class="text-[13px] font-semibold text-ink">Preview</h2>
          <p
            class="mt-1 text-[13px] leading-relaxed text-ink-muted"
            data-preview-independence
          >
            A preview is a non-production deployment of one verified commit, offered so the work can
            be tried before anyone approves it. Whether it exists, is still deploying, or failed
            never decides whether this feature is verified or ready for review.
          </p>

          <p
            :if={not @preview.configured?}
            class="mt-3 text-xs text-ink-muted"
            data-preview-unavailable
          >
            This project has no authorized preview path, so nothing was deployed and there is no
            link to show. Review can go ahead without one.
          </p>

          <p
            :if={@preview.configured? and @preview.deployments == []}
            class="mt-3 text-xs text-ink-muted"
            data-preview-none
          >
            No preview has been deployed for this feature yet. One starts by itself once a run
            verifies, on {@preview.path}.
          </p>

          <ul :if={@preview.deployments != []} class="mt-3 flex flex-col gap-3" data-preview-list>
            <li
              :for={item <- @preview.deployments}
              class="rounded-lg border border-line bg-surface p-3.5"
              data-preview-item
              data-preview-id={item.id}
              data-preview-state={item.status}
              data-preview-current={to_string(item.current?)}
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class="whitespace-nowrap" data-preview-state-label>
                  <.badge
                    variant={preview_state_variant(item.status)}
                    icon={preview_state_icon(item.status)}
                  >
                    {preview_state_label(item.status)}
                  </.badge>
                </span>
                <span class="whitespace-nowrap" data-preview-nonproduction>
                  <.badge variant="neutral" icon="globe">Non-production</.badge>
                </span>
              </div>

              <p :if={item.link} class="mt-3 text-[13px]">
                <.link
                  href={item.link}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="inline-flex items-start gap-1.5 break-all rounded font-semibold text-primary underline underline-offset-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
                  data-preview-link
                >
                  <.lucide name="external-link" class="mt-0.5 size-4 flex-none" />
                  {item.link}
                </.link>
              </p>

              <p :if={item.link} class="mt-1 text-xs text-ink-muted" data-preview-link-note>
                This is a non-production deployment of {item.branch} from run {item.run_ref}, built
                from commit {item.commit_sha}. It opens in a new tab.
              </p>

              <p
                :if={item.link_withheld?}
                class="mt-3 flex items-start gap-1.5 text-xs text-warn-fg"
                data-preview-link-withheld
              >
                <.lucide name="triangle-alert" class="mt-0.5 size-3.5 flex-none" />
                This deployment reported ready without a link this project can safely open, so none
                is shown.
              </p>

              <p :if={item.failed?} class="mt-3 text-sm text-ink" data-preview-reason>
                {preview_failure_message(item.failure_reason)} It changes nothing about whether the
                work was verified.
              </p>

              <p
                :if={item.status == "expired"}
                class="mt-3 text-sm text-ink"
                data-preview-expired-note
              >
                This preview reached the end of its configured lifetime and is no longer served.
                Nothing failed.
              </p>

              <p
                :if={item.superseded?}
                class="mt-3 text-xs text-ink-muted"
                data-preview-replacement
              >
                A later verified commit replaced this preview. It stays here so what was deployed
                before is not rewritten. Replaced by {item.replaced_by_ref}.
              </p>

              <dl class="mt-3 grid grid-cols-1 gap-x-5 gap-y-1.5 text-xs sm:grid-cols-2">
                <.preview_fact label="Run" test="run" value={item.run_ref} />
                <.preview_fact
                  label="Attempt"
                  test="attempt"
                  value={item.attempt_ref || "Not recorded"}
                />
                <.preview_fact label="Provider" test="provider" value={item.provider} />
                <.preview_fact label="Path" test="path" value={item.path} />
                <.preview_fact
                  label="Requested"
                  test="requested"
                  value={recorded_label(item.requested_at)}
                />
                <.preview_fact
                  :if={item.ready_at}
                  label="Ready"
                  test="ready"
                  value={recorded_label(item.ready_at)}
                />
                <.preview_fact
                  :if={item.status == "pending"}
                  label="Times out"
                  test="timeout"
                  value={recorded_label(item.timeout_at)}
                />
                <.preview_fact
                  :if={item.expires_at}
                  label="Expires"
                  test="expires"
                  value={recorded_label(item.expires_at)}
                />
                <.preview_fact
                  :if={preview_cleanup_label(item.cleanup_state)}
                  label="Cleanup"
                  test="cleanup"
                  value={preview_cleanup_label(item.cleanup_state)}
                />
                <.preview_fact
                  :if={item.failure_reason}
                  label="Reason code"
                  test="reason-code"
                  value={item.failure_reason}
                />
                <.preview_fact
                  label="Branch"
                  test="branch"
                  value={item.branch}
                  class="sm:col-span-2"
                />
                <.preview_fact
                  label="Commit"
                  test="commit"
                  value={item.commit_sha}
                  class="sm:col-span-2"
                />
              </dl>
            </li>
          </ul>
        </section>

        <section class="mt-6" aria-labelledby="activity-heading" data-activity>
          <h2 id="activity-heading" class="text-[13px] font-semibold text-ink">
            Feature activity
          </h2>

          <ol :if={@activity != []} class="mt-3 flex flex-col gap-2">
            <li
              :for={entry <- @activity}
              class="min-w-0 rounded-lg border border-line bg-surface p-3.5"
              data-activity-entry
              data-activity-sequence={entry.sequence}
            >
              <p class="text-xs font-semibold text-ink-muted">Development progress</p>
              <p class="mt-1 break-words text-sm text-ink" data-activity-summary>
                {entry.payload["summary"] || "Development progress recorded."}
              </p>
              <p class="mt-2 text-xs text-ink-muted" data-activity-position>
                Attempt {entry.payload["attempt_number"]}, update {entry.payload["sequence"]}
              </p>
            </li>
          </ol>

          <p :if={@activity == []} class="mt-3 text-xs text-ink-muted" data-activity-empty>
            No development progress has been recorded yet.
          </p>
        </section>

        <section class="mt-6" data-comments>
          <h2 class="text-[13px] font-semibold text-ink">Comments</h2>

          <ul :if={@comments != []} class="mt-3 flex flex-col gap-2">
            <li
              :for={comment <- @comments}
              class="rounded-lg border border-line bg-surface p-3.5"
              data-comment
            >
              <p class="text-[13px] font-semibold text-ink" data-comment-author>
                {name(@names, comment.actor_account_id) || "A former member"}
              </p>
              <p class="mt-1 text-sm text-ink" data-comment-body>{comment.payload["body"]}</p>
            </li>
          </ul>

          <p :if={@comments == []} class="mt-3 text-xs text-ink-muted" data-comments-empty>
            Nothing said about this feature yet.
          </p>

          <form
            id="comment-form"
            phx-change="validate_comment"
            phx-submit="comment"
            class="mt-4"
          >
            <.text_field
              id="comment-body"
              name="comment[body]"
              label="Add a comment"
              value={@comment_body}
              error={@comment_error}
              hint="Comments explain the work. They never stand in for a required check."
              autocomplete="off"
              phx-debounce="200"
            />
            <.button type="submit" class="mt-3 w-full sm:w-auto" data-post-comment>
              <.lucide name="pencil" class="size-4" /> Post comment
            </.button>
          </form>
        </section>
      </div>
    </.app_shell>
    """
  end
end
