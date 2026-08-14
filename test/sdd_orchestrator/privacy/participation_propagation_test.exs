defmodule SddOrchestrator.Privacy.ParticipationPropagationTest do
  @moduledoc """
  Proof for specs/28 Task 2 (AC-02, AC-03): idempotent participation deletion
  and anonymization propagation to every configured non-backup destination,
  restricted acknowledgement/retry/reconciliation state, and no restored
  access or identification independent of cleanup completion.
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Participation
  alias SddOrchestrator.Participation.{Boundary, Revocations}
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.Privacy.{
    ParticipationCleanupRequest,
    ParticipationPropagation,
    Rights
  }

  alias SddOrchestrator.Repo

  @fixed_destinations [:configured_processors, :caches, :indexes, :exports]

  describe "AC-02 destinations: the fixed allowlist" do
    test "destinations/0 is exactly the four fixed, ordered destinations" do
      assert ParticipationPropagation.destinations() == @fixed_destinations
    end

    test "the fixed destination set matches Rights' anonymization_propagation pending_propagation exactly" do
      %{project: project, identity: identity} = departed_participant()

      {:ok, %{propagation: propagation}} =
        Rights.assess_participation_attribution(project.id, identity.account.id)

      rights_destinations = Enum.map(propagation.pending_propagation, & &1.record)
      rights_actions = propagation.pending_propagation |> Enum.map(& &1.action) |> Enum.uniq()

      assert rights_destinations == ParticipationPropagation.destinations()
      assert rights_actions == [:anonymize]
    end
  end

  describe "AC-02 propagate/3: one request per destination" do
    test "issues exactly one request per fixed destination for an anonymization action" do
      subject_ref = Ecto.UUID.generate()

      assert {:ok, requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert length(requests) == 4
      assert Enum.map(requests, & &1.destination) == @fixed_destinations
      assert Enum.all?(requests, &(&1.action == :anonymize))
      assert Enum.all?(requests, &(&1.state == :pending))
      assert Enum.all?(requests, &(&1.subject_ref == subject_ref))
      assert Enum.all?(requests, &(&1.attempt_count == 0))
      assert Enum.all?(requests, &is_binary(&1.idempotency_key))
    end

    test "issues exactly one request per fixed destination for a deletion action" do
      subject_ref = Ecto.UUID.generate()

      assert {:ok, requests} = ParticipationPropagation.propagate(subject_ref, :delete)

      assert length(requests) == 4
      assert Enum.map(requests, & &1.destination) == @fixed_destinations
      assert Enum.all?(requests, &(&1.action == :delete))
    end

    test "the same subject may hold independent delete and anonymize requests" do
      subject_ref = Ecto.UUID.generate()

      {:ok, deletes} = ParticipationPropagation.propagate(subject_ref, :delete)
      {:ok, anonymizations} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert length(deletes) == 4
      assert length(anonymizations) == 4
      assert Repo.aggregate(ParticipationCleanupRequest, :count) == 8
    end
  end

  describe "AC-02 idempotency: a repeat call creates no duplicate rows" do
    test "propagating the same subject and action twice is idempotent" do
      subject_ref = Ecto.UUID.generate()

      {:ok, first_pass} = ParticipationPropagation.propagate(subject_ref, :anonymize)
      {:ok, second_pass} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert Enum.map(first_pass, & &1.id) == Enum.map(second_pass, & &1.id)

      assert Enum.map(first_pass, & &1.idempotency_key) ==
               Enum.map(second_pass, & &1.idempotency_key)

      assert Repo.aggregate(ParticipationCleanupRequest, :count) == 4
    end

    test "a repeat call never resets acknowledgement or retry progress already made" do
      subject_ref = Ecto.UUID.generate()

      {:ok, [processors_request | _rest]} =
        ParticipationPropagation.propagate(subject_ref, :anonymize)

      {:ok, acknowledged} = ParticipationPropagation.acknowledge(processors_request.id)
      assert acknowledged.state == :acknowledged

      {:ok, requests_after_repeat} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      reacknowledged =
        Enum.find(requests_after_repeat, &(&1.destination == :configured_processors))

      assert reacknowledged.id == processors_request.id
      assert reacknowledged.state == :acknowledged
      assert Repo.aggregate(ParticipationCleanupRequest, :count) == 4
    end

    test "the idempotency key is deterministic for the same subject, action, and destination" do
      subject_ref = Ecto.UUID.generate()

      assert ParticipationCleanupRequest.idempotency_key(subject_ref, :anonymize, :caches) ==
               ParticipationCleanupRequest.idempotency_key(subject_ref, :anonymize, :caches)

      refute ParticipationCleanupRequest.idempotency_key(subject_ref, :anonymize, :caches) ==
               ParticipationCleanupRequest.idempotency_key(subject_ref, :anonymize, :indexes)

      refute ParticipationCleanupRequest.idempotency_key(subject_ref, :anonymize, :caches) ==
               ParticipationCleanupRequest.idempotency_key(subject_ref, :delete, :caches)
    end
  end

  describe "AC-02 acknowledgement" do
    test "acknowledge/2 transitions a request to acknowledged and clears any failure state" do
      subject_ref = Ecto.UUID.generate()
      {:ok, [request | _rest]} = ParticipationPropagation.propagate(subject_ref, :delete)

      {:ok, failed} = ParticipationPropagation.fail(request.id, :timeout)
      assert failed.state == :retry_pending

      {:ok, acknowledged} = ParticipationPropagation.acknowledge(failed.id)

      assert acknowledged.state == :acknowledged
      assert acknowledged.failure_reason == nil
      assert %DateTime{} = acknowledged.acknowledged_at
      assert acknowledged.attempt_count == 2
    end

    test "acknowledge/2 reports :not_found for an unknown id" do
      assert ParticipationPropagation.acknowledge(Ecto.UUID.generate()) == {:error, :not_found}
    end
  end

  describe "AC-02 normalized failure and retry" do
    test "fail/3 transitions a request to restricted retry-pending state" do
      subject_ref = Ecto.UUID.generate()
      {:ok, [request | _rest]} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert {:ok, retried} = ParticipationPropagation.fail(request.id, :destination_unavailable)

      assert retried.state == :retry_pending
      assert retried.failure_reason == :destination_unavailable
      assert retried.attempt_count == 1
      assert %DateTime{} = retried.last_attempted_at
      assert retried.acknowledged_at == nil
    end

    test "fail/3 refuses to reopen an already-acknowledged request" do
      subject_ref = Ecto.UUID.generate()
      {:ok, [request | _rest]} = ParticipationPropagation.propagate(subject_ref, :anonymize)
      {:ok, acknowledged} = ParticipationPropagation.acknowledge(request.id)

      assert ParticipationPropagation.fail(acknowledged.id, :timeout) ==
               {:error, :already_acknowledged}
    end

    test "fail/3 reports :not_found for an unknown id" do
      assert ParticipationPropagation.fail(Ecto.UUID.generate(), :timeout) ==
               {:error, :not_found}
    end
  end

  describe "AC-02 reconciliation: retry lock, restart, and recovery" do
    test "reconcile/2 claims pending requests and acknowledges them through the given adapter" do
      subject_ref = Ecto.UUID.generate()
      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert {:ok, summary} =
               ParticipationPropagation.reconcile(DateTime.utc_now(),
                 adapter: fn _request -> :ok end
               )

      assert summary.claimed == 4
      assert summary.acknowledged == 4
      assert summary.retry_pending == 0

      requests = ParticipationPropagation.requests_for(subject_ref, :anonymize)
      assert Enum.all?(requests, &(&1.state == :acknowledged))
    end

    test "reconcile/2 without a configured adapter reports every claimed request as retry-pending" do
      subject_ref = Ecto.UUID.generate()
      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :delete)

      assert {:ok, summary} = ParticipationPropagation.reconcile()

      assert summary.claimed == 4
      assert summary.acknowledged == 0
      assert summary.retry_pending == 4

      requests = ParticipationPropagation.requests_for(subject_ref, :delete)
      assert Enum.all?(requests, &(&1.state == :retry_pending))
      assert Enum.all?(requests, &(&1.failure_reason == :destination_unavailable))
    end

    test "restart safety: a retry-pending request left over from an interrupted earlier pass is found and retried" do
      subject_ref = Ecto.UUID.generate()
      {:ok, [request | _rest]} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      # Simulate an earlier pass that attempted once and failed, then the
      # process was interrupted before a later pass could retry it.
      {:ok, left_over} = ParticipationPropagation.fail(request.id, :transient_error)
      assert left_over.state == :retry_pending

      assert {:ok, summary} =
               ParticipationPropagation.reconcile(DateTime.utc_now(),
                 adapter: fn _request -> :ok end
               )

      assert summary.claimed == 4
      assert summary.acknowledged == 4

      recovered = Repo.get!(ParticipationCleanupRequest, left_over.id)
      assert recovered.state == :acknowledged
      assert recovered.attempt_count == 2
    end

    test "a concurrent reconciler returns :locked and dispatches nothing" do
      subject_ref = Ecto.UUID.generate()
      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      holder = start_lock_holder()

      try do
        assert ParticipationPropagation.reconcile(DateTime.utc_now(), adapter: fn _r -> :ok end) ==
                 :locked

        requests = ParticipationPropagation.requests_for(subject_ref, :anonymize)
        assert Enum.all?(requests, &(&1.state == :pending))
      after
        release_lock_holder(holder)
      end
    end

    test "reconcile/2 respects :limit and claims oldest-attempted-first" do
      subject_ref = Ecto.UUID.generate()
      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert {:ok, summary} =
               ParticipationPropagation.reconcile(DateTime.utc_now(),
                 adapter: fn _request -> :ok end,
                 limit: 2
               )

      assert summary.claimed == 2
      assert summary.acknowledged == 2

      requests = ParticipationPropagation.requests_for(subject_ref, :anonymize)
      assert Enum.count(requests, &(&1.state == :acknowledged)) == 2
      assert Enum.count(requests, &(&1.state == :pending)) == 2
    end
  end

  describe "forbidden content: cleanup requests never carry participation identity" do
    test "no persisted cleanup request row contains the participant's email, display name, account id, or hosted-identity id, beyond the opaque subject reference" do
      %{project: project, identity: identity, participant: participant, profile: profile} =
        active_participant()

      forbidden_values = [
        identity.account.id,
        identity.hosted_identity.id,
        participant.id,
        project.id
      ]

      forbidden_substrings = [
        identity.external_identity.display_identifier,
        profile.display_name
      ]

      subject_ref = Ecto.UUID.generate()
      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      ParticipationPropagation.reconcile(DateTime.utc_now(),
        adapter: fn _r -> {:error, :rejected} end
      )

      persisted = Repo.all(ParticipationCleanupRequest)
      assert length(persisted) == 4

      for request <- persisted do
        dumped = inspect(Map.from_struct(request))

        # The one field the design explicitly allows is the caller-minted
        # opaque subject_ref, which is a fresh correlation UUID unrelated to
        # any real account, hosted-identity, participant, or project id.
        assert request.subject_ref == subject_ref
        refute request.subject_ref in forbidden_values

        for forbidden <- forbidden_values ++ forbidden_substrings do
          refute String.contains?(dumped, to_string(forbidden)),
                 "cleanup request #{request.id} unexpectedly contained #{inspect(forbidden)}"
        end
      end
    end
  end

  describe "AC-03 authorization compatibility: no restored access independent of cleanup completion" do
    test "a departed participant stays denied while propagation is entirely pending" do
      %{project: project, identity: identity} = departed_participant()
      subject_ref = Ecto.UUID.generate()

      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      assert_access_denied(project, identity)
    end

    test "a departed participant stays denied while propagation is partially acknowledged and partially retry-pending" do
      %{project: project, identity: identity} = departed_participant()
      subject_ref = Ecto.UUID.generate()

      {:ok, [first, second, third, fourth]} =
        ParticipationPropagation.propagate(subject_ref, :anonymize)

      {:ok, _} = ParticipationPropagation.acknowledge(first.id)
      {:ok, _} = ParticipationPropagation.fail(second.id, :timeout)
      # third and fourth remain pending

      assert_access_denied(project, identity)
      refute third.state == :acknowledged
      refute fourth.state == :acknowledged
    end

    test "a departed participant stays denied even once every destination has acknowledged cleanup" do
      %{project: project, identity: identity} = departed_participant()
      subject_ref = Ecto.UUID.generate()

      {:ok, _requests} = ParticipationPropagation.propagate(subject_ref, :anonymize)

      {:ok, summary} =
        ParticipationPropagation.reconcile(DateTime.utc_now(), adapter: fn _request -> :ok end)

      assert summary.acknowledged == 4

      assert_access_denied(project, identity)
    end

    test "propagate/3, acknowledge/2, fail/3, and reconcile/2 never touch the primary participation boundary" do
      %{project: project, identity: identity, participant: participant} = active_participant()

      # An active (not departed) participant establishes the baseline: it is
      # currently authorized before any propagation call, so this test proves
      # propagation itself cannot change that state either way, independent
      # of whether the subject is departed elsewhere.
      assert {:ok, _member} =
               Boundary.current_member(project.id, %{
                 account_id: identity.account.id,
                 hosted_identity_id: identity.hosted_identity.id
               })

      subject_ref = Ecto.UUID.generate()
      {:ok, [request | _]} = ParticipationPropagation.propagate(subject_ref, :anonymize)
      {:ok, _} = ParticipationPropagation.acknowledge(request.id)
      ParticipationPropagation.reconcile(DateTime.utc_now(), adapter: fn _r -> :ok end)

      # Still active and authorized: propagation over an unrelated opaque
      # subject reference never grants, revokes, or otherwise changes this
      # participant's own current-state authorization.
      assert {:ok, _member} =
               Boundary.current_member(project.id, %{
                 account_id: identity.account.id,
                 hosted_identity_id: identity.hosted_identity.id
               })

      assert participant.state == "active"
    end
  end

  defp assert_access_denied(project, identity) do
    account_id = identity.account.id
    hosted_identity_id = identity.hosted_identity.id

    assert Participation.member_role(project, account_id, hosted_identity_id) ==
             {:error, :unauthorized}

    assert Boundary.current_member(project.id, %{
             account_id: account_id,
             hosted_identity_id: hosted_identity_id
           }) == {:error, :not_a_member}
  end

  defp project_fixture do
    result = ParticipationFixtures.hosted_project_fixture()

    ParticipationFixtures.member_profile_fixture(result.project, result.account, %{
      role: "owner",
      display_name: ParticipationFixtures.unique_display_name("Owner")
    })

    %{project: result.project}
  end

  defp active_participant do
    %{project: project} = project_fixture()
    identity = ParticipationFixtures.invited_identity_fixture()
    participant = ParticipationFixtures.participant_fixture(project, identity.hosted_identity)

    profile =
      ParticipationFixtures.member_profile_fixture(project, identity.account, %{
        role: "participant",
        display_name: ParticipationFixtures.unique_display_name("Participant")
      })

    %{project: project, identity: identity, participant: participant, profile: profile}
  end

  defp departed_participant do
    %{project: project, identity: identity} = active_participant()

    {:ok, _departure} =
      Revocations.leave(project, identity.account.id, identity.hosted_identity.id)

    %{project: project, identity: identity}
  end

  # A genuinely separate database session holds the sweep lock, so the
  # contended path is proven against real PostgreSQL rather than a stubbed
  # lock, mirroring
  # `SddOrchestrator.AIRuntime.PersonalConnectionRevocationsTest`. The sandbox
  # connection cannot serve here: an advisory lock is re-entrant within one
  # session, so a shared connection would grant the lock twice.
  defp start_lock_holder do
    {:ok, holder} = Postgrex.start_link(postgrex_options())
    Process.unlink(holder)
    on_exit(fn -> if Process.alive?(holder), do: GenServer.stop(holder) end)

    assert %Postgrex.Result{rows: [[:void]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_lock($1)", [
               ParticipationPropagation.advisory_lock_key()
             ])

    holder
  end

  defp release_lock_holder(holder) do
    assert %Postgrex.Result{rows: [[true]]} =
             Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [
               ParticipationPropagation.advisory_lock_key()
             ])
  end

  defp postgrex_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :database, :username, :password])
    |> Keyword.put(:backoff_type, :stop)
  end
end
