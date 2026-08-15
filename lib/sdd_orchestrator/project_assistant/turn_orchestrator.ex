defmodule SddOrchestrator.ProjectAssistant.TurnOrchestrator do
  @moduledoc """
  Turns bounded current context into one reviewable, grounded answer
  (AC-10, AC-11, AC-12) — the single entry point every later caller (a
  future Task 8 LiveView) uses to submit one question and receive one fully
  persisted turn.

  `answer/6` composes every earlier task's contract in the order design.md
  describes:

    1. `BoundaryGate.authorize_turn/5` (Task 2) — the pre-tool confirmation
       gate. Refuses before any read tool or model call runs, and before any
       turn is persisted, exactly like `RuntimeContract`'s own moduledoc
       anticipates ("a later task's turn orchestrator runs before ever
       calling this function").
    2. `RuntimeContract.open_turn/1` (Task 6) — pins the read-tool manifest,
       trusted skill bundle, and turn budget for the whole turn.
    3. `ProjectContextAssembler.assemble/3` (Task 3) — the default current
       stored context every question grounds in first ("Stored Context First
       And Source On Demand").
    4. `ModelCompletionAdapter.complete/1` (Task 7) — one candidate answer
       with claimed source references. A candidate is never trusted
       directly: every claimed citation is independently re-resolved below.
    5. When any claim requests a `:repository` citation,
       `RepositoryObserver.observe/4` (Task 4) — one fresh, per-turn
       observation. A worker-offline or source-denied outcome never fails
       the whole turn (AC-10): repository claims are dropped with an
       `:unavailable` marker and every stored-context claim still resolves.
       An unstable observation never yields a stable citation (AC-09,
       "no-stale-source-current rule"): repository claims are dropped with
       an `:unstable` marker instead.
    6. Each surviving repository claim's minimal excerpt is fetched through
       `RepositoryDiscoverer.lines/6` (Task 5) — itself authorization- and
       exclusion-checked, so a claim naming a denied path (a secret file, for
       example) fails closed without ever reaching a citation.
    7. `CitationResolver` (Task 7) resolves every remaining claim against
       already-fetched, already-authorized data. A claim that cannot be
       verified — fabricated, stale, or otherwise unresolvable — is dropped,
       never shown as fact (AC-11's claim-to-source validation). A
       `material: true` claim with no citation at all is dropped the same
       way: an uncited material claim is excluded, not silently presented.
    8. `TurnAnswerStore.persist/5` (Task 7) writes the complete turn and its
       citations atomically.

  A failure before context assembly (an unauthorized or since-revoked
  participant) never creates a turn row — the same fail-closed,
  no-existence-disclosure contract every other project-assistant surface
  uses. A failure at or after the model-completion step (model unavailable,
  timeout, or any other normalized reason) is `answer failure recovery`: it
  *does* persist, with `outcome: "failed"` and a normalized
  `failure_reason`, never a raw provider error or a fabricated answer.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.ProjectAssistant.{
    BoundaryGate,
    CitationResolver,
    Guard,
    ModelCompletionAdapter,
    ProjectContextAssembler,
    RepositoryDiscoverer,
    RepositoryObservation,
    RepositoryObserver,
    RuntimeContract,
    TurnAnswerStore,
    UncertaintyMarker
  }

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type actor :: Guard.actor()

  @unavailable_reasons ~w(unauthorized source_denied worker_unavailable)a

  @doc """
  Submits one question and returns the fully persisted, grounded turn.

  `opts`:
    * `:now` — defaults to `DateTime.utc_now/0`.
    * `:model_adapter` — defaults to `ModelCompletionAdapter.configured/0`.
    * `:adapter` — the `RepositoryObservationAdapter` passed through to
      `RepositoryObserver` and `RepositoryDiscoverer`; defaults to
      `RepositoryObservationAdapter.configured/0`.
    * `:worker_available` — passed through to `RepositoryObserver` and
      `RepositoryDiscoverer`.
    * every `BoundaryGate.authorize_turn/5` and `RuntimeContract.open_turn/1`
      option (budget overrides, requested skill, and so on).
  """
  @spec answer(authority(), String.t(), actor(), term(), String.t(), keyword()) ::
          {:ok, {term(), term(), [term()]}} | {:error, atom()}
  def answer(authority, project_id, actor, account, question_text, opts \\ []) do
    with :ok <- BoundaryGate.authorize_turn(authority, project_id, actor, account, opts),
         {:ok, contract} <- RuntimeContract.open_turn(opts) do
      run_turn(authority, project_id, actor, question_text, contract, opts)
    end
  end

  defp run_turn(authority, project_id, actor, question_text, contract, opts) do
    case ProjectContextAssembler.assemble(authority, project_id, actor) do
      {:error, reason} ->
        {:error, reason}

      {:ok, %{content: content, context_version: version}} ->
        complete_and_persist(
          authority,
          project_id,
          actor,
          question_text,
          content,
          version,
          contract,
          opts
        )
    end
  end

  defp complete_and_persist(
         authority,
         project_id,
         actor,
         question_text,
         content,
         version,
         contract,
         opts
       ) do
    model_adapter = Keyword.get(opts, :model_adapter, ModelCompletionAdapter.configured())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    request = %{question_text: question_text, context_content: content, context_version: version}

    case complete(contract, model_adapter, request) do
      {:error, reason} ->
        persist_failure(authority, project_id, actor, question_text, version, reason)

      {:ok, candidate, contract} ->
        {claims, markers} =
          resolve_claims(candidate, content, authority, project_id, actor, contract, now, opts)

        persist_answer(authority, project_id, actor, question_text, version, claims, markers)
    end
  end

  defp complete(contract, adapter, request) do
    with :ok <- RuntimeContract.authorize_model_call(contract),
         {:ok, candidate} <- adapter.complete(request),
         {:ok, contract} <- RuntimeContract.record_model_call(contract) do
      {:ok, candidate, contract}
    end
  end

  # --- claim resolution -----------------------------------------------

  # Bundles everything a per-claim resolution step needs beyond the claim
  # itself, the observation, and the threaded budget contract, purely to
  # keep every resolution function's arity small and uniform.
  defp env(authority, project_id, actor, now, opts),
    do: %{authority: authority, project_id: project_id, actor: actor, now: now, opts: opts}

  defp resolve_claims(candidate, content, authority, project_id, actor, contract, now, opts) do
    env = env(authority, project_id, actor, now, opts)
    claims = Map.get(candidate, :claims, [])
    needs_repository? = Enum.any?(claims, &repository_claim?/1)

    {observation_result, contract} =
      if needs_repository?,
        do: observe_repository(contract, env),
        else: {nil, contract}

    {results, _contract} =
      Enum.map_reduce(claims, contract, fn claim, acc_contract ->
        resolve_one_claim(claim, content, observation_result, acc_contract, env)
      end)

    kept =
      results
      |> Enum.filter(&match?({:kept, _}, &1))
      |> Enum.map(fn {:kept, claim_result} -> claim_result end)

    derived_markers = derive_markers(results)
    candidate_markers = normalize_candidate_markers(Map.get(candidate, :markers, []))

    {kept, derived_markers ++ candidate_markers}
  end

  defp repository_claim?(%{citation: %{type: :repository}}), do: true
  defp repository_claim?(_claim), do: false

  defp observe_repository(contract, env) do
    operation = "repository-state"

    with :ok <- RuntimeContract.authorize_call(contract, operation, 0, env.now),
         {:ok, observation} <-
           RepositoryObserver.observe(env.authority, env.project_id, env.actor, env.opts),
         {:ok, recorded_contract} <-
           RuntimeContract.record_call(
             contract,
             operation,
             0,
             byte_size(observation.after_digest),
             env.now
           ) do
      {{:ok, observation}, recorded_contract}
    else
      {:error, reason} -> {{:error, reason}, contract}
    end
  end

  defp resolve_one_claim(%{citation: nil, material: true}, _content, _observation, contract, _env) do
    {{:dropped, :excluded}, contract}
  end

  defp resolve_one_claim(
         %{citation: nil, material: false} = claim,
         _content,
         _observation,
         contract,
         _env
       ) do
    {{:kept, %{text: claim.text, citation: nil}}, contract}
  end

  defp resolve_one_claim(
         %{citation: %{type: :specification} = claimed} = claim,
         content,
         _observation,
         contract,
         _env
       ) do
    case CitationResolver.resolve_specification(claimed, content["specifications"]) do
      {:ok, reference} -> {kept(claim, "specification", reference), contract}
      {:error, :stale} -> {{:dropped, :stale}, contract}
      {:error, _reason} -> {{:dropped, :excluded}, contract}
    end
  end

  defp resolve_one_claim(
         %{citation: %{type: :board} = claimed} = claim,
         content,
         _observation,
         contract,
         _env
       ) do
    case CitationResolver.resolve_board(claimed, content["board"]) do
      {:ok, reference} -> {kept(claim, "board", reference), contract}
      {:error, _reason} -> {{:dropped, :excluded}, contract}
    end
  end

  defp resolve_one_claim(
         %{citation: %{type: :run} = claimed} = claim,
         content,
         _observation,
         contract,
         _env
       ) do
    case CitationResolver.resolve_run(claimed, content["recent_runs"]) do
      {:ok, reference} -> {kept(claim, "run", reference), contract}
      {:error, _reason} -> {{:dropped, :excluded}, contract}
    end
  end

  defp resolve_one_claim(
         %{citation: %{type: :evidence} = claimed} = claim,
         content,
         _observation,
         contract,
         _env
       ) do
    case CitationResolver.resolve_evidence(claimed, content["accepted_evidence"]) do
      {:ok, reference} -> {kept(claim, "evidence", reference), contract}
      {:error, _reason} -> {{:dropped, :excluded}, contract}
    end
  end

  defp resolve_one_claim(
         %{citation: %{type: :repository} = claimed} = claim,
         _content,
         observation_result,
         contract,
         env
       ) do
    resolve_repository_claim(claim, claimed, observation_result, contract, env)
  end

  # `observation_result` is `nil` only when no claim requested repository
  # grounding at all — unreachable from this repository-claim clause by
  # construction (`needs_repository?` is true iff a claim like this one
  # exists), kept only as a defensive fail-closed fallback.
  defp resolve_repository_claim(_claim, _claimed, nil, contract, _env) do
    {{:dropped, :unavailable}, contract}
  end

  defp resolve_repository_claim(_claim, _claimed, {:error, reason}, contract, _env) do
    marker = if reason in @unavailable_reasons, do: :unavailable, else: :excluded
    {{:dropped, marker}, contract}
  end

  defp resolve_repository_claim(
         _claim,
         _claimed,
         {:ok, %RepositoryObservation{stable?: false}},
         contract,
         _env
       ) do
    {{:dropped, :unstable}, contract}
  end

  defp resolve_repository_claim(
         claim,
         %{path: path, start_line: start_line, end_line: end_line} = claimed,
         {:ok, %RepositoryObservation{stable?: true} = observation},
         contract,
         env
       ) do
    operation = "repository-lines"

    with :ok <- RuntimeContract.authorize_call(contract, operation, 0, env.now),
         {:ok, %{content: excerpt}} <-
           RepositoryDiscoverer.lines(
             env.authority,
             env.project_id,
             env.actor,
             path,
             start_line..end_line,
             env.opts
           ),
         {:ok, recorded_contract} <-
           RuntimeContract.record_call(contract, operation, 0, byte_size(excerpt), env.now) do
      reference = CitationResolver.build_repository_reference(observation, claimed)
      {kept(claim, "repository", reference, truncate_excerpt(excerpt)), recorded_contract}
    else
      {:error, _reason} -> {{:dropped, :excluded}, contract}
    end
  end

  defp kept(claim, source_type, reference, excerpt \\ nil) do
    {:kept,
     %{
       text: claim.text,
       citation: %{source_type: source_type, reference: reference, excerpt: excerpt}
     }}
  end

  @max_excerpt_bytes 500

  defp truncate_excerpt(text) when byte_size(text) <= @max_excerpt_bytes, do: text

  defp truncate_excerpt(text) do
    binary_part(text, 0, @max_excerpt_bytes)
  end

  # --- markers -----------------------------------------------------------

  defp derive_markers(results) do
    results
    |> Enum.filter(&match?({:dropped, _type}, &1))
    |> Enum.map(fn {:dropped, type} -> type end)
    |> Enum.uniq()
    |> Enum.map(&UncertaintyMarker.new(&1, marker_detail(&1)))
    |> Enum.map(&UncertaintyMarker.to_map/1)
  end

  defp marker_detail(:unavailable),
    do:
      "Repository source was unavailable, so source-based claims were excluded from this answer."

  defp marker_detail(:unstable),
    do:
      "The repository working tree changed while it was being observed, so source-based claims from that scan were excluded rather than shown as current."

  defp marker_detail(:stale),
    do: "A claim referenced a superseded specification revision and was excluded."

  defp marker_detail(:excluded),
    do:
      "One or more claims could not be verified against current, authorized project data and were excluded."

  defp normalize_candidate_markers(markers) when is_list(markers) do
    markers
    |> Enum.map(&UncertaintyMarker.from_candidate/1)
    |> Enum.filter(&match?({:ok, _marker}, &1))
    |> Enum.map(fn {:ok, marker} -> UncertaintyMarker.to_map(marker) end)
  end

  defp normalize_candidate_markers(_markers), do: []

  # --- persistence ---------------------------------------------------

  defp persist_answer(authority, project_id, actor, question_text, version, claims, markers) do
    answer_text = compose_answer_text(claims)
    citations = Enum.map(claims, & &1.citation) |> Enum.reject(&is_nil/1)

    TurnAnswerStore.persist(authority, project_id, actor, question_text, %{
      answer_text: answer_text,
      context_version: version,
      uncertainty_markers: markers,
      outcome: "answered",
      failure_reason: nil,
      citations: citations
    })
  end

  defp persist_failure(authority, project_id, actor, question_text, version, reason) do
    TurnAnswerStore.persist(authority, project_id, actor, question_text, %{
      answer_text: nil,
      context_version: version,
      uncertainty_markers: [],
      outcome: "failed",
      failure_reason: normalize_failure_reason(reason),
      citations: []
    })
  end

  defp compose_answer_text(claims) do
    case claims |> Enum.map(& &1.text) |> Enum.reject(&(&1 in [nil, ""])) do
      [] -> nil
      texts -> Enum.join(texts, " ")
    end
  end

  defp normalize_failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_failure_reason(_reason), do: "answer_generation_failed"
end
