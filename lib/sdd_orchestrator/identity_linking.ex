defmodule SddOrchestrator.IdentityLinking do
  @moduledoc """
  GitHub-to-passwordless identity linking: automatic candidate detection, the
  transient merge attempt, and the non-mutating merge preflight.

  Automatic matching only ever identifies a transient candidate. It exposes no
  candidate account data and mutates no identity, workspace, project, pairing, or
  repository connection. Initial linking still requires fresh proof of both
  sign-in methods, a clear preflight, and explicit confirmation before commit —
  implemented by later tasks against the same `IdentityMergeAttempt` id.

  Vocabulary: the *absorbed* account is the GitHub-authenticated account that
  started the attempt; the *surviving* account is the matched passwordless
  account whose stable identity and workspace are preserved.
  """
  import Ecto.Query

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    ExternalIdentity,
    GitHubCredential,
    GitHubIdentity,
    HostedIdentity,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.Devices.LocalWorker

  alias SddOrchestrator.IdentityLinking.{
    Audit,
    EmailMatch,
    IdentityMergeAttempt,
    MergeNotificationEmail,
    Preflight,
    WorkspaceMergeRecord
  }

  alias SddOrchestrator.Mailer
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo

  # A candidate is transient: minutes, not hours, so an unproven match never lingers.
  @attempt_ttl_seconds 15 * 60
  # The passwordless proof challenge lives the same short window.
  @proof_ttl_seconds 15 * 60
  # Default bounded retention for the minimal merge record (release-gate final value).
  @merge_record_retention_days 180

  @type candidate_bundle :: %{
          hosted_identity: HostedIdentity.t(),
          account: Account.t(),
          personal_workspace: PersonalWorkspace.t()
        }

  ## Candidate detection

  @doc """
  Finds the single passwordless identity whose verified email matches a GitHub
  verified-primary email under the approved automatic-match rules.

  Returns `{:ok, bundle}` for exactly one eligible match, `:none` for an
  ineligible address or no match, and `:ambiguous` when the normalized form maps
  to more than one hosted identity (fail closed, no disclosure). `exclude_account_id`
  keeps an account from matching itself.
  """
  @spec find_candidate(term(), binary() | nil) :: {:ok, candidate_bundle()} | :none | :ambiguous
  def find_candidate(github_email, exclude_account_id \\ nil) do
    case EmailMatch.comparison_key(github_email) do
      {:ineligible, _reason} ->
        :none

      {:ok, key} ->
        key
        |> matching_hosted_identity_ids(exclude_account_id)
        |> resolve_candidate()
    end
  end

  # Narrow to same-domain email identities in SQL (exact domain, no LIKE
  # wildcards), then confirm the full comparison key in Elixir so provider dot,
  # tag, and case rules are applied. Distinct *hosted identities* decide ambiguity.
  defp matching_hosted_identity_ids(key, exclude_account_id) do
    domain = key |> String.split("@") |> List.last()

    from(e in ExternalIdentity,
      join: h in HostedIdentity,
      on: h.id == e.hosted_identity_id,
      where:
        e.provider == "email" and
          fragment("split_part(?, '@', 2) = ?", e.subject_key, ^domain),
      select: %{
        hosted_identity_id: e.hosted_identity_id,
        account_id: h.account_id,
        display_identifier: e.display_identifier
      }
    )
    |> Repo.all()
    |> Enum.filter(&(EmailMatch.comparison_key(&1.display_identifier) == {:ok, key}))
    |> Enum.reject(&(not is_nil(exclude_account_id) and &1.account_id == exclude_account_id))
    |> Enum.map(& &1.hosted_identity_id)
    |> Enum.uniq()
  end

  defp resolve_candidate([]), do: :none
  defp resolve_candidate([hosted_identity_id]), do: {:ok, load_bundle(hosted_identity_id)}
  defp resolve_candidate(_many), do: :ambiguous

  defp load_bundle(hosted_identity_id) do
    hosted_identity =
      HostedIdentity
      |> Repo.get!(hosted_identity_id)
      |> Repo.preload(:account)

    personal_workspace =
      PersonalWorkspace
      |> Repo.get_by!(account_id: hosted_identity.account_id)
      |> Repo.preload(:workspace)

    %{
      hosted_identity: hosted_identity,
      account: hosted_identity.account,
      personal_workspace: personal_workspace
    }
  end

  ## Transient merge attempt

  @doc """
  Opens (or reuses) a transient merge attempt when a GitHub authentication yields
  exactly one eligible passwordless candidate.

  Returns `{:ok, attempt}` for a single candidate, or `{:ok, :none}` for no
  eligible or an ambiguous match — an account-neutral result that discloses
  nothing about any other account. The attempt records the fresh GitHub proof and
  a short expiry; the passwordless proof and confirmation are bound to it later.
  """
  @spec start_merge_attempt(Account.t(), term()) :: {:ok, IdentityMergeAttempt.t()} | {:ok, :none}
  def start_merge_attempt(%Account{} = absorbed, github_email) do
    case find_candidate(github_email, absorbed.id) do
      {:ok, bundle} ->
        attempt = upsert_attempt(absorbed, bundle)
        Audit.event(:candidate_detected, %{attempt_id: attempt.id})
        {:ok, attempt}

      :none ->
        Audit.event(:candidate_skipped, %{outcome: :none})
        {:ok, :none}

      :ambiguous ->
        Audit.event(:candidate_skipped, %{outcome: :ambiguous})
        {:ok, :none}
    end
  end

  defp upsert_attempt(%Account{} = absorbed, bundle) do
    attrs = %{
      absorbed_account_id: absorbed.id,
      surviving_account_id: bundle.account.id,
      candidate_hosted_identity_id: bundle.hosted_identity.id,
      github_proven_at: now(),
      expires_at: seconds_from_now(@attempt_ttl_seconds)
    }

    case current_attempt_for(absorbed.id) do
      %IdentityMergeAttempt{} = existing ->
        {:ok, attempt} =
          existing |> IdentityMergeAttempt.refresh_changeset(attrs) |> Repo.update()

        attempt

      nil ->
        insert_or_refresh(absorbed.id, attrs)
    end
  end

  # Insert a fresh attempt, or — if a concurrent request won the one-live-attempt
  # index — refresh the attempt that now exists.
  defp insert_or_refresh(absorbed_account_id, attrs) do
    case %IdentityMergeAttempt{}
         |> IdentityMergeAttempt.detect_changeset(attrs)
         |> Repo.insert() do
      {:ok, attempt} ->
        attempt

      {:error, %Ecto.Changeset{}} ->
        {:ok, attempt} =
          absorbed_account_id
          |> current_attempt_for()
          |> IdentityMergeAttempt.refresh_changeset(attrs)
          |> Repo.update()

        attempt
    end
  end

  defp current_attempt_for(absorbed_account_id) do
    Repo.one(
      from a in IdentityMergeAttempt,
        where:
          a.absorbed_account_id == ^absorbed_account_id and is_nil(a.committed_at) and
            a.status != "aborted",
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: 1
    )
  end

  @doc "Fetches a live (unexpired, uncommitted, non-aborted) attempt by id, or nil."
  @spec get_live_attempt(term()) :: IdentityMergeAttempt.t() | nil
  def get_live_attempt(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(
          from a in IdentityMergeAttempt,
            where:
              a.id == ^uuid and is_nil(a.committed_at) and a.status != "aborted" and
                a.expires_at > ^now()
        )

      :error ->
        nil
    end
  end

  def get_live_attempt(_), do: nil

  @doc "Marks an attempt aborted. Non-mutating for identities, workspaces, and projects."
  @spec abort_merge_attempt(IdentityMergeAttempt.t()) :: {:ok, IdentityMergeAttempt.t()}
  def abort_merge_attempt(%IdentityMergeAttempt{} = attempt) do
    {:ok, _} = attempt |> IdentityMergeAttempt.abort_changeset() |> Repo.update()
  end

  ## Fresh two-method proof and explicit confirmation

  @doc """
  Issues a fresh passwordless proof challenge for the candidate email, bound to
  the attempt.

  Returns `{:ok, %{challenge_id, raw_token, delivery_email}}` for the delivery
  boundary to email; only the salted digest is persisted and the attempt expiry is
  refreshed so the flow stays live. The raw token is never stored or returned to
  the initiator's screen.
  """
  @spec request_passwordless_proof(IdentityMergeAttempt.t()) ::
          {:ok, %{challenge_id: binary(), raw_token: String.t(), delivery_email: String.t()}}
          | {:error, :candidate_unavailable}
  def request_passwordless_proof(%IdentityMergeAttempt{} = attempt) do
    case candidate_email(attempt) do
      nil ->
        {:error, :candidate_unavailable}

      email ->
        raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
        salt = :crypto.strong_rand_bytes(32)
        challenge_id = Ecto.UUID.generate()
        proof_expires_at = seconds_from_now(@proof_ttl_seconds)

        {:ok, _updated} =
          attempt
          |> IdentityMergeAttempt.request_proof_changeset(%{
            passwordless_challenge_id: challenge_id,
            passwordless_proof_digest: :crypto.hash(:sha256, salt <> raw_token),
            passwordless_proof_salt: salt,
            passwordless_proof_expires_at: proof_expires_at,
            expires_at: proof_expires_at
          })
          |> Repo.update()

        Audit.event(:proof_requested, %{attempt_id: attempt.id})
        {:ok, %{challenge_id: challenge_id, raw_token: raw_token, delivery_email: email}}
    end
  end

  @doc """
  Verifies a passwordless proof token for a challenge and records the fresh proof.

  Every invalid, expired, mismatched, replayed, or cancelled attempt returns the
  same safe `{:error, :invalid_or_expired}`. The challenge is single-use: a
  successful proof clears the stored digest so it cannot be replayed.
  """
  @spec submit_passwordless_proof(term(), term()) ::
          {:ok, IdentityMergeAttempt.t()} | {:error, :invalid_or_expired}
  def submit_passwordless_proof(challenge_id, raw_token) when is_binary(raw_token) do
    Repo.transaction(fn ->
      with %IdentityMergeAttempt{} = attempt <- lock_by_challenge(challenge_id),
           :ok <- validate_proof(attempt, raw_token),
           {:ok, proven} <- Repo.update(IdentityMergeAttempt.record_proof_changeset(attempt)) do
        proven
      else
        _failure -> Repo.rollback(:invalid_or_expired)
      end
    end)
    |> case do
      {:ok, attempt} ->
        Audit.event(:proof_succeeded, %{attempt_id: attempt.id})
        {:ok, attempt}

      {:error, _reason} ->
        Audit.event(:proof_failed, %{outcome: :invalid_or_expired})
        {:error, :invalid_or_expired}
    end
  rescue
    _error ->
      Audit.event(:proof_failed, %{outcome: :invalid_or_expired})
      {:error, :invalid_or_expired}
  end

  def submit_passwordless_proof(_challenge_id, _raw_token) do
    Audit.event(:proof_failed, %{outcome: :invalid_or_expired})
    {:error, :invalid_or_expired}
  end

  @doc """
  Records explicit user confirmation, the final gate before commit.

  Requires both fresh proofs and a clear re-run preflight. Returns `{:error,
  :not_ready}` when a proof is missing or stale and `{:error, :conflict}` (marking
  the attempt conflicted) when the combined project set collides.
  """
  @spec confirm_merge(IdentityMergeAttempt.t()) ::
          {:ok, IdentityMergeAttempt.t()} | {:error, :not_ready | :conflict}
  def confirm_merge(%IdentityMergeAttempt{} = attempt) do
    cond do
      not proofs_complete?(attempt) ->
        {:error, :not_ready}

      Preflight.conflicted?(preflight(attempt)) ->
        {:ok, _} = attempt |> IdentityMergeAttempt.conflict_changeset() |> Repo.update()
        Audit.event(:merge_conflict, %{attempt_id: attempt.id})
        {:error, :conflict}

      true ->
        {:ok, confirmed} = attempt |> IdentityMergeAttempt.confirm_changeset() |> Repo.update()
        Audit.event(:merge_confirmed, %{attempt_id: confirmed.id})
        {:ok, confirmed}
    end
  end

  @doc """
  True only for an attempt that has both fresh proofs, explicit confirmation, and
  a clear preflight, and is neither expired, aborted, nor already committed. An
  email match alone can never satisfy this.
  """
  @spec commit_eligible?(IdentityMergeAttempt.t()) :: boolean()
  def commit_eligible?(%IdentityMergeAttempt{} = attempt) do
    proven_and_confirmed?(attempt) and Preflight.clear?(preflight(attempt))
  end

  defp proven_and_confirmed?(%IdentityMergeAttempt{} = attempt) do
    proofs_complete?(attempt) and not is_nil(attempt.confirmed_at)
  end

  defp proofs_complete?(%IdentityMergeAttempt{} = attempt) do
    is_nil(attempt.committed_at) and attempt.status != "aborted" and
      not is_nil(attempt.github_proven_at) and not is_nil(attempt.passwordless_proven_at) and
      DateTime.compare(attempt.expires_at, now()) == :gt
  end

  defp candidate_email(%IdentityMergeAttempt{} = attempt) do
    case Repo.get_by(ExternalIdentity,
           hosted_identity_id: attempt.candidate_hosted_identity_id,
           provider: "email"
         ) do
      %ExternalIdentity{display_identifier: email} -> email
      nil -> nil
    end
  end

  defp lock_by_challenge(challenge_id) do
    case Ecto.UUID.cast(challenge_id) do
      {:ok, id} ->
        Repo.one(
          from a in IdentityMergeAttempt,
            where: a.passwordless_challenge_id == ^id,
            lock: "FOR UPDATE"
        )

      :error ->
        nil
    end
  end

  defp validate_proof(%IdentityMergeAttempt{} = attempt, raw_token) do
    valid? =
      is_nil(attempt.committed_at) and attempt.status != "aborted" and
        is_nil(attempt.passwordless_proven_at) and
        not is_nil(attempt.passwordless_proof_digest) and
        not is_nil(attempt.passwordless_proof_salt) and
        not is_nil(attempt.passwordless_proof_expires_at) and
        DateTime.compare(attempt.passwordless_proof_expires_at, now()) == :gt and
        valid_token_shape?(raw_token) and
        :crypto.hash_equals(
          :crypto.hash(:sha256, attempt.passwordless_proof_salt <> raw_token),
          attempt.passwordless_proof_digest
        )

    if valid?, do: :ok, else: :error
  end

  defp valid_token_shape?(raw_token) when is_binary(raw_token) do
    case Base.url_decode64(raw_token, padding: false) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp valid_token_shape?(_raw_token), do: false

  ## Atomic merge commit

  @doc """
  Commits a confirmed, conflict-free merge atomically.

  Under row locks on the attempt and both accounts it re-checks eligibility and
  re-runs the preflight, then in one transaction moves every hosted project and
  repository connection into the surviving workspace (stable project ids), attaches
  the GitHub identity, credential, and sessions to the surviving account, and
  records GitHub as a sign-in method on the surviving hosted identity. Any conflict
  or fault rolls everything back, leaving both original boundaries unchanged.

  On success the absorbed workspace and account are reduced to one minimal
  `WorkspaceMergeRecord` and the transient attempt is removed. Idempotent: a retry
  after commit returns the existing merge record. Returns `{:error, :not_eligible}`
  without both fresh proofs and confirmation, and `{:error, :conflict}` on a
  preflight or constraint collision.
  """
  @spec commit_merge(IdentityMergeAttempt.t()) ::
          {:ok, WorkspaceMergeRecord.t()} | {:error, :not_found | :not_eligible | :conflict}
  def commit_merge(%IdentityMergeAttempt{id: id}) do
    Repo.transaction(fn -> do_commit(id) end)
    |> case do
      {:ok, {:committed, record}} ->
        Audit.event(:merge_committed, %{
          merge_event_id: record.merge_event_id,
          source_workspace_id: record.source_workspace_id,
          surviving_workspace_id: record.surviving_workspace_id
        })

        notify_merge(record)
        {:ok, record}

      {:ok, {:idempotent, record}} ->
        {:ok, record}

      {:error, reason} ->
        Audit.event(:merge_failed, %{reason: reason})
        {:error, reason}
    end
  rescue
    # A concurrent conflicting insert trips a workspace uniqueness constraint; the
    # transaction is already rolled back, so no partial state remains.
    Ecto.ConstraintError ->
      Audit.event(:merge_failed, %{reason: :conflict})
      {:error, :conflict}
  end

  defp do_commit(id) do
    case lock_attempt(id) do
      nil ->
        # The transient attempt is gone: either it never existed, or the merge
        # already committed and left only its minimal record (idempotent retry).
        case Repo.get(WorkspaceMergeRecord, id) do
          %WorkspaceMergeRecord{} = record -> {:idempotent, record}
          nil -> Repo.rollback(:not_found)
        end

      %IdentityMergeAttempt{} = attempt ->
        lock_accounts([attempt.absorbed_account_id, attempt.surviving_account_id])

        cond do
          not proven_and_confirmed?(attempt) -> Repo.rollback(:not_eligible)
          Preflight.conflicted?(preflight(attempt)) -> Repo.rollback(:conflict)
          true -> {:committed, consolidate(attempt)}
        end
    end
  end

  # Notify the surviving identity of the linking, after commit. A delivery failure
  # never affects the already-committed merge.
  defp notify_merge(%WorkspaceMergeRecord{} = record) do
    case surviving_email(record.surviving_workspace_id) do
      nil -> :ok
      email -> email |> MergeNotificationEmail.build() |> Mailer.deliver()
    end
  rescue
    _error -> :ok
  end

  defp surviving_email(surviving_workspace_id) do
    with %PersonalWorkspace{account_id: account_id} <-
           Repo.get(PersonalWorkspace, surviving_workspace_id),
         %HostedIdentity{id: hosted_identity_id} <-
           Repo.get_by(HostedIdentity, account_id: account_id),
         %ExternalIdentity{display_identifier: email} <-
           Repo.get_by(ExternalIdentity,
             hosted_identity_id: hosted_identity_id,
             provider: "email"
           ) do
      email
    else
      _ -> nil
    end
  end

  defp consolidate(%IdentityMergeAttempt{} = attempt) do
    now = now()
    absorbed_ws = workspace_id_for_account(attempt.absorbed_account_id)
    surviving_ws = workspace_id_for_account(attempt.surviving_account_id)

    move_projects(absorbed_ws, surviving_ws, now)
    revoke_absorbed_workers(absorbed_ws, now)
    repoint_github_account(attempt.absorbed_account_id, attempt.surviving_account_id, now)
    attach_github_sign_in(attempt, now)
    record = write_merge_record(attempt, absorbed_ws, surviving_ws, now)
    reduce_absorbed(attempt.absorbed_account_id, absorbed_ws)

    record
  end

  # Retain only the six approved fields as the merge evidence.
  defp write_merge_record(attempt, absorbed_ws, surviving_ws, now) do
    %WorkspaceMergeRecord{}
    |> WorkspaceMergeRecord.changeset(%{
      merge_event_id: attempt.id,
      source_workspace_id: absorbed_ws,
      surviving_workspace_id: surviving_ws,
      status: "completed",
      completed_at: now,
      delete_after: DateTime.add(now, @merge_record_retention_days * 24 * 60 * 60, :second)
    })
    |> Repo.insert!()
  end

  # Delete the emptied absorbed workspace (cascades its personal profile and
  # onboarding attempts) and account (cascades the transient merge attempt), so no
  # additional absorbed-workspace state or account-linking map remains — only the
  # minimal merge record, which carries no foreign key to either.
  defp reduce_absorbed(absorbed_account_id, absorbed_ws) do
    Repo.delete_all(from w in Workspace, where: w.id == ^absorbed_ws)
    Repo.delete_all(from a in Account, where: a.id == ^absorbed_account_id)
  end

  # Move every project and repository connection to the surviving workspace,
  # preserving stable project ids and their (project-scoped) hosted storage.
  defp move_projects(absorbed_ws, surviving_ws, now) do
    Repo.update_all(
      from(p in Project, where: p.workspace_id == ^absorbed_ws),
      set: [workspace_id: surviving_ws, updated_at: now]
    )

    Repo.update_all(
      from(c in RepositoryConnection, where: c.workspace_id == ^absorbed_ws),
      set: [workspace_id: surviving_ws, updated_at: now]
    )
  end

  # Revoke every active worker paired to the absorbed workspace inside the same
  # commit: machine trust is scoped to one workspace and is never transferred. The
  # worker rows and local files are untouched, so explicit re-pairing to the
  # surviving workspace issues fresh credentials. A rollback leaves them active.
  defp revoke_absorbed_workers(absorbed_ws, now) do
    Repo.update_all(
      from(w in LocalWorker,
        where: w.device_workspace_id == ^absorbed_ws and w.state == "active"
      ),
      set: [state: "revoked", revoked_at: now, updated_at: now]
    )
  end

  # Re-point the GitHub identity, credential, and sessions so a later GitHub
  # sign-in resolves to the surviving account and workspace.
  defp repoint_github_account(absorbed_account_id, surviving_account_id, now) do
    Repo.update_all(
      from(g in GitHubIdentity, where: g.account_id == ^absorbed_account_id),
      set: [account_id: surviving_account_id, updated_at: now]
    )

    Repo.update_all(
      from(c in GitHubCredential, where: c.account_id == ^absorbed_account_id),
      set: [account_id: surviving_account_id, updated_at: now]
    )

    Repo.update_all(
      from(s in ApplicationSession, where: s.account_id == ^absorbed_account_id),
      set: [account_id: surviving_account_id, updated_at: now]
    )
  end

  # Record GitHub as a sign-in method on the surviving hosted identity so it can
  # authenticate the surviving identity after the merge.
  defp attach_github_sign_in(%IdentityMergeAttempt{} = attempt, now) do
    case Repo.get_by(GitHubIdentity, account_id: attempt.surviving_account_id) do
      %GitHubIdentity{} = github ->
        %ExternalIdentity{}
        |> ExternalIdentity.changeset(%{
          provider: "github",
          subject_key: Integer.to_string(github.github_user_id),
          display_identifier: github.login,
          verified_at: now,
          hosted_identity_id: attempt.candidate_hosted_identity_id
        })
        |> Repo.insert!()

      nil ->
        :ok
    end
  end

  defp lock_attempt(id) do
    Repo.one(from a in IdentityMergeAttempt, where: a.id == ^id, lock: "FOR UPDATE")
  end

  # Lock in a deterministic order to avoid deadlock between concurrent merges.
  defp lock_accounts(account_ids) do
    ordered = account_ids |> Enum.uniq() |> Enum.sort()

    Repo.all(from a in Account, where: a.id in ^ordered, order_by: a.id, lock: "FOR UPDATE")
  end

  ## Merge record (minimal post-commit evidence)

  @doc """
  Fetches the minimal merge record by merge-event id, for the approved
  idempotency, security-audit, verified-support, and rights workflows only.
  """
  @spec get_merge_record(term()) :: WorkspaceMergeRecord.t() | nil
  def get_merge_record(merge_event_id) when is_binary(merge_event_id) do
    case Ecto.UUID.cast(merge_event_id) do
      {:ok, id} -> Repo.get(WorkspaceMergeRecord, id)
      :error -> nil
    end
  end

  def get_merge_record(_), do: nil

  @doc """
  Deletes merge records naming a workspace as source or survivor. Used by rights
  erasure of the surviving account so its merge evidence is removed with it.
  """
  @spec delete_merge_records_for_workspace(binary()) :: {non_neg_integer(), nil}
  def delete_merge_records_for_workspace(workspace_id) when is_binary(workspace_id) do
    Repo.delete_all(
      from r in WorkspaceMergeRecord,
        where: r.surviving_workspace_id == ^workspace_id or r.source_workspace_id == ^workspace_id
    )
  end

  @doc "Deletes merge records past their retention deadline. Idempotent; used by the pruner."
  @spec prune_merge_records(DateTime.t()) :: non_neg_integer()
  def prune_merge_records(now) do
    {count, _} = Repo.delete_all(from r in WorkspaceMergeRecord, where: r.delete_after < ^now)
    count
  end

  ## Preflight

  @doc """
  Evaluates the combined project set of a merge without mutating anything.

  Reports every case-insensitive project-name collision and every canonical
  repository collision across the surviving and absorbed workspaces. Projects
  existing on both sides are normal history, not conflicts. `Preflight.clear?/1`
  is true only when there are no conflicts.
  """
  @spec preflight(IdentityMergeAttempt.t()) :: Preflight.t()
  def preflight(%IdentityMergeAttempt{} = attempt) do
    build_preflight(
      workspace_id_for_account(attempt.surviving_account_id),
      workspace_id_for_account(attempt.absorbed_account_id)
    )
  end

  defp build_preflight(surviving_ws_id, absorbed_ws_id) do
    surviving_projects = projects_in(surviving_ws_id)
    absorbed_projects = projects_in(absorbed_ws_id)

    surviving_by_name = Map.new(surviving_projects, &{&1.name_key, &1})

    name_conflicts =
      for a <- absorbed_projects, s = surviving_by_name[a.name_key], not is_nil(s) do
        %{
          name_key: a.name_key,
          surviving_project_id: s.id,
          absorbed_project_id: a.id,
          surviving_name: s.name,
          absorbed_name: a.name
        }
      end

    surviving_by_repo = Map.new(connections_in(surviving_ws_id), &{repo_key(&1), &1})

    repository_conflicts =
      for a <- connections_in(absorbed_ws_id),
          s = surviving_by_repo[repo_key(a)],
          not is_nil(s) do
        %{
          provider: a.provider,
          provider_repository_id: a.provider_repository_id,
          surviving_project_id: s.project_id,
          absorbed_project_id: a.project_id
        }
      end

    %Preflight{name_conflicts: name_conflicts, repository_conflicts: repository_conflicts}
  end

  defp projects_in(nil), do: []

  defp projects_in(workspace_id) do
    Repo.all(
      from p in Project,
        where: p.workspace_id == ^workspace_id,
        select: %{id: p.id, name: p.name, name_key: p.name_key}
    )
  end

  defp connections_in(nil), do: []

  defp connections_in(workspace_id) do
    Repo.all(
      from c in RepositoryConnection,
        where: c.workspace_id == ^workspace_id,
        select: %{
          project_id: c.project_id,
          provider: c.provider,
          provider_repository_id: c.provider_repository_id
        }
    )
  end

  defp repo_key(%{provider: provider, provider_repository_id: id}), do: {provider, id}

  defp workspace_id_for_account(account_id) do
    case Repo.get_by(PersonalWorkspace, account_id: account_id) do
      %PersonalWorkspace{id: id} -> id
      nil -> nil
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp seconds_from_now(seconds), do: DateTime.add(now(), seconds, :second)
end
