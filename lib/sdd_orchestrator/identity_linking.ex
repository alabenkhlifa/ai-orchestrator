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

  alias SddOrchestrator.Accounts.{Account, ExternalIdentity, HostedIdentity, PersonalWorkspace}
  alias SddOrchestrator.IdentityLinking.{EmailMatch, IdentityMergeAttempt, Preflight}
  alias SddOrchestrator.Projects.{Project, RepositoryConnection}
  alias SddOrchestrator.Repo

  # A candidate is transient: minutes, not hours, so an unproven match never lingers.
  @attempt_ttl_seconds 15 * 60

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
      {:ok, bundle} -> {:ok, upsert_attempt(absorbed, bundle)}
      :none -> {:ok, :none}
      :ambiguous -> {:ok, :none}
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
