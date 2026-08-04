defmodule SddOrchestrator.Privacy.Rights do
  @moduledoc """
  Verified data-subject-rights handling for the operator workflow.

  This slice serves rights requests through an authenticated operator workflow
  rather than a self-service screen. Two operations are implemented end to end:

    * `export_account/1` — access and portability: gathers the account's
      identities, workspace, projects, repository connections, passwordless
      attempts, session metadata, the short-lived model catalog and quota
      snapshots still held for it, and the pinned runtime configurations and
      ceiling ledgers still retained for project accountability, into a
      structured, credential-free map.
    * `erase_account/2` — erasure: atomically deletes the hosted workspace root
      and account, cascading to identities, credentials, sessions, the personal
      profile, projects, repository connections, hosted storage, onboarding
      attempts, and personal AI connection references together with the model
      catalog and quota snapshots that hang off both the account and those
      connections, while explicitly deleting passwordless attempts keyed to the
      account's verified email. Before that transaction it asks every paired
      worker to remove the credential it holds locally, and reports the outcome
      as counts and typed reasons.
    * `terminate_personal_ai_service/1` — service termination: revokes every
      personal AI connection, requests worker-local credential removal, deletes
      the catalog and quota evidence in the same scope, hands the acknowledged
      references to retention, and reports as aggregate counts the pinned
      configurations and ceiling ledgers termination retains, because ending the
      service is a revocation rather than an erasure request.
    * `assess_runtime_session_request/3` — the disposition for a rights request
      over one pinned runtime configuration. Correction is refused because the
      pin is the record of what actually ran; restriction and objection carry
      the same verified operator assessment a restored project does.
    * `retire_runtime_consumers/2` — the deletion handoff for a retired consumer.
      A session names its consumer as a kind and an opaque reference, so the
      owning project or conversation deletion path is the only authority that
      can say a consumer is gone; this boundary applies that decision.
    * Portability project operations — authorized access and portability export,
      project-name and specification correction through their normal write
      boundaries, project erasure, and explicit restriction or objection
      assessment with processor and encrypted-backup lifecycle handoff.
    * `export_passwordless_attempts/1` and `erase_passwordless_attempts/1` —
      access and erasure for a verified requester whose email has attempts but no
      account yet.
    * Participation attribution operations — the necessity assessment for a
      departed participant's project label, verified anonymization of that label
      and its account link, and the project-deletion sweep. Anonymization keeps
      the contribution history that attributes through the profile and restores
      no project access.

  Retained copies outside the primary store (encrypted backups) are expired by the
  deployment's backup lifecycle, recorded in the deployment privacy profile.
  Transient GitHub authorization attempts carry no account id and are removed by
  time-based retention. Exports never include access or refresh tokens, raw
  magic-link tokens, token salts or digests, PKCE verifiers, or session digests.
  """
  import Ecto.Query

  alias Ecto.Multi

  alias SddOrchestrator.Accounts.{
    Account,
    ApplicationSession,
    DeviceWorkspace,
    ExternalIdentity,
    GitHubIdentity,
    HostedIdentity,
    HostedSession,
    MagicLinkAttempt,
    PersonalWorkspace,
    Workspace
  }

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    ModelCatalogSnapshot,
    PersonalAIConnection,
    PersonalConnectionRevocations,
    QuotaSnapshot,
    RuntimeCostLedger
  }

  alias SddOrchestrator.Devices
  alias SddOrchestrator.IdentityLinking.WorkspaceMergeRecord
  alias SddOrchestrator.Participation

  alias SddOrchestrator.Portability.{
    HostedLocalRepositoryBinding,
    ImportAttempt,
    PackageProvenance,
    PackageProvenances
  }

  alias SddOrchestrator.Privacy.DeploymentPrivacyProfile
  alias SddOrchestrator.Projects
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  alias SddOrchestrator.Specifications.{
    ProjectSpecification,
    SpecificationLifecycle,
    SpecificationRevision
  }

  alias SddOrchestrator.SpecificationStore

  @typedoc "One runtime consumer whose owning deletion path has retired it."
  @type runtime_consumer :: {:support_assistant | :working_agent | String.t(), String.t()}

  @doc """
  Assembles a credential-free export of everything the deployment holds for an
  account. Returns `{:error, :not_found}` for an unknown account.
  """
  @spec export_account(String.t()) :: {:ok, map()} | {:error, :not_found}
  def export_account(account_id) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        {:ok,
         %{
           account: %{id: account.id, state: account.state},
           github_identity: export_identity(account_id),
           hosted_identity: export_hosted_identity(account_id),
           magic_link_attempts: export_account_magic_link_attempts(account_id),
           import_attempts: export_import_attempts(account_id),
           personal_ai_connections: export_personal_ai_connections(account_id),
           model_catalog_snapshots: export_model_catalog_snapshots(account_id),
           quota_snapshots: export_quota_snapshots(account_id),
           ai_runtime_sessions: export_ai_runtime_sessions(account_id),
           runtime_cost_ledgers: export_runtime_cost_ledgers(account_id),
           projects: export_projects(account_id),
           sessions: export_sessions(account_id),
           hosted_sessions: export_hosted_sessions(account_id)
         }}
    end
  end

  @doc """
  Erases an account, its hosted workspace root, and every record that cascades
  from them. Returns
  `{:error, :not_found}` for an unknown account.

  Worker-local AI credentials are asked for first, because once the account row
  is gone nothing remains that could name which worker profile still holds one.
  An unreachable worker does not block or delay the erasure; the returned
  `:personal_ai_connections` summary reports how many removals are still
  outstanding and why, as counts and typed reasons only.
  """
  @spec erase_account(String.t(), keyword()) ::
          {:ok, %{account_id: String.t(), propagation: map()}} | {:error, :not_found}
  def erase_account(account_id, opts \\ []) when is_binary(account_id) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{} = account ->
        workspace = Repo.get_by(PersonalWorkspace, account_id: account.id)
        email_keys = email_subject_keys(account.id)

        credential_removal =
          PersonalConnectionRevocations.request_account_credential_removal(account.id, opts)

        Multi.new()
        |> delete_magic_link_attempts(email_keys)
        |> delete_merge_records(workspace)
        |> maybe_delete_workspace(workspace)
        |> Multi.delete(:account, account)
        |> Repo.transaction()
        |> case do
          {:ok, _changes} ->
            {:ok,
             %{
               account_id: account.id,
               personal_ai_connections: credential_removal,
               propagation: deletion_propagation(:hosted)
             }}

          {:error, _step, _reason, _changes} ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Ends the personal AI connection service and hands off its stored references.

  Termination is the same two guarantees revocation always makes, applied at
  once: no connection can fund new work from this point, and every worker is
  asked to remove the credential it holds. The catalog and quota evidence in the
  same scope is deleted rather than left for the next retention pass, because no
  connection it describes can still be presented or selected, and the returned
  counts are aggregate. Scope it to one account with
  `account: account_or_id`. Returns `{:error, :busy}` when another
  reconciliation sweep already holds the lock; the operation is idempotent, so
  running it again is the correct response.
  """
  @spec terminate_personal_ai_service(keyword()) :: {:ok, map()} | {:error, :busy}
  def terminate_personal_ai_service(opts \\ []) do
    case PersonalConnectionRevocations.terminate_service(opts) do
      {:ok, summary} ->
        {:ok,
         %{
           action: :service_termination,
           personal_ai_connections: summary,
           personal_ai_snapshots: purge_personal_ai_snapshots(opts),
           personal_ai_runtime: retained_runtime_records(opts),
           propagation: deletion_propagation(:hosted)
         }}

      :locked ->
        {:error, :busy}
    end
  end

  # Termination leaves no connection in scope able to fund work, so the catalog
  # and quota evidence in that scope describes nothing that may still be
  # presented or selected. Retention would delete it on its next pass; the
  # purpose that justified holding it ends here, so termination deletes it now.
  # The counts are aggregate and name no connection.
  defp purge_personal_ai_snapshots(opts) do
    scope = account_scope(opts)

    %{
      model_catalogs: delete_scoped_snapshots(ModelCatalogSnapshot, scope),
      quotas: delete_scoped_snapshots(QuotaSnapshot, scope)
    }
  end

  # Termination is a revocation of every connection at once, not an erasure
  # request. The pinned configurations and ceiling ledgers in scope are the
  # project's account of what already ran; each keeps its own accountability
  # window and loses only the opaque reference, which is deleted with the
  # connection that named it. The counts are aggregate and identify no session,
  # so the operator can see what termination retained without reading it.
  defp retained_runtime_records(opts) do
    scope = account_scope(opts)

    %{
      sessions: count_scoped(AIRuntimeSession, scope),
      cost_ledgers: count_scoped(RuntimeCostLedger, scope),
      disposition: :retained_for_project_accountability
    }
  end

  defp count_scoped(schema, :all), do: Repo.aggregate(schema, :count)

  defp count_scoped(schema, account_id),
    do: Repo.aggregate(from(row in schema, where: row.account_id == ^account_id), :count)

  defp account_scope(opts) do
    case Keyword.fetch(opts, :account) do
      {:ok, %Account{id: account_id}} -> account_id
      {:ok, account_id} when is_binary(account_id) -> account_id
      :error -> :all
    end
  end

  defp delete_scoped_snapshots(schema, :all) do
    {count, _} = Repo.delete_all(schema)
    count
  end

  defp delete_scoped_snapshots(schema, account_id) do
    {count, _} =
      Repo.delete_all(from snapshot in schema, where: snapshot.account_id == ^account_id)

    count
  end

  @doc "Exports one restored project through its current authoritative boundary."
  @spec export_portability_project(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def export_portability_project(%PersonalWorkspace{} = authority, project_id) do
    with {:ok, %PackageProvenance{}} <- PackageProvenances.get(authority, project_id),
         %Project{} = project <- Projects.get_project(authority, project_id) do
      project =
        Repo.preload(project, [
          :repository_connection,
          :hosted_local_repository_binding
        ])

      {:ok,
       project
       |> export_project()
       |> Map.put(:propagation, access_propagation(:hosted))}
    else
      _not_authorized_or_restored -> {:error, :not_found}
    end
  end

  def export_portability_project(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %PackageProvenance{} = provenance} <-
           PackageProvenances.get(authority, project_id),
         {:ok, %{workspace_id: ^authority_id, storage_mode: "device"} = project} <-
           Devices.get_project(project_id),
         {:ok, snapshot} <- SpecificationStore.current_snapshot(authority, project_id) do
      {:ok,
       %{
         id: project.id,
         name: project.name,
         storage_mode: project.storage_mode,
         repository_identity: %{
           provider: project.repository_provider,
           repository_id: project.repository_id
         },
         repository: nil,
         hosted_local_repository_binding: nil,
         provenance: export_provenance(provenance),
         specifications: Enum.map(snapshot.specifications, &export_current_specification/1),
         propagation: access_propagation(:device)
       }}
    else
      _not_authorized_or_restored -> {:error, :not_found}
    end
  end

  def export_portability_project(_authority, _project_id), do: {:error, :not_found}

  @doc "Corrects a restored project name through its authoritative project boundary."
  @spec correct_portability_project_name(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, :not_found | Ecto.Changeset.t()}
  def correct_portability_project_name(%PersonalWorkspace{} = authority, project_id, name) do
    with {:ok, %PackageProvenance{}} <- PackageProvenances.get(authority, project_id),
         %Project{} = project <- Projects.get_project(authority, project_id) do
      Projects.rename_project(project, name)
    else
      _not_authorized_or_restored -> {:error, :not_found}
    end
  end

  def correct_portability_project_name(
        %DeviceWorkspace{id: authority_id} = authority,
        project_id,
        name
      ) do
    with {:ok, %PackageProvenance{}} <- PackageProvenances.get(authority, project_id),
         {:ok, %{workspace_id: ^authority_id, storage_mode: "device"}} <-
           Devices.get_project(project_id) do
      Devices.rename_project(project_id, name)
    else
      _not_authorized_or_restored -> {:error, :not_found}
    end
  end

  def correct_portability_project_name(_authority, _project_id, _name),
    do: {:error, :not_found}

  @doc "Appends a correction to one restored specification through the shared store."
  def correct_portability_specification(
        authority,
        project_id,
        specification_id,
        expected_revision_id,
        attrs
      ) do
    case PackageProvenances.get(authority, project_id) do
      {:ok, %PackageProvenance{}} ->
        SpecificationStore.append_revision(
          authority,
          project_id,
          specification_id,
          expected_revision_id,
          attrs
        )

      _not_authorized_or_restored ->
        {:error, :not_found}
    end
  end

  @doc "Erases one restored project and returns the required processor and backup handoff."
  @spec erase_portability_project(PersonalWorkspace.t() | DeviceWorkspace.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def erase_portability_project(authority, project_id) do
    with {:ok, %PackageProvenance{}} <- PackageProvenances.get(authority, project_id),
         {:ok, result} <- SpecificationLifecycle.delete_project(authority, project_id) do
      boundary = if match?(%PersonalWorkspace{}, authority), do: :hosted, else: :device

      {:ok,
       result
       |> Map.put(:action, :erasure)
       |> Map.put(:runtime_records, retire_project_runtime_consumers(authority, project_id))
       |> Map.put(:propagation, deletion_propagation(boundary))}
    else
      _not_authorized_or_restored -> {:error, :not_found}
    end
  end

  @doc """
  Retires the pinned runtime records of consumers that no longer exist.

  A session names its consumer as a kind and an opaque reference, so the owning
  deletion path — the project or the conversation — is the only authority that
  can say the consumer is gone. This boundary applies that decision inside one
  account: it deletes each named consumer's pinned configuration and ceiling
  ledger in one transaction, ignores a reference it does not hold, and converges
  when the same decision is applied twice.
  """
  @spec retire_runtime_consumers(Account.t() | String.t(), [runtime_consumer()]) :: {:ok, map()}
  def retire_runtime_consumers(account_or_id, consumers) when is_list(consumers) do
    with {:ok, account_id} <- runtime_account_id(account_or_id),
         [_named | _] = grouped <- group_runtime_consumers(consumers) do
      {:ok, delete_runtime_consumers(account_id, grouped)}
    else
      _nothing_named -> {:ok, no_runtime_records()}
    end
  end

  def retire_runtime_consumers(_account_or_id, _consumers), do: {:ok, no_runtime_records()}

  @doc """
  Returns the verified disposition for a rights request over one pinned session.

  A pinned configuration is immutable accountability evidence: it records what a
  support conversation or working-agent run actually executed under. Correction
  is refused rather than applied, because rewriting it would destroy the very
  record the person is entitled to see; access, portability, erasure,
  restriction, and objection remain available and are named in the refusal. The
  database refuses the rewrite as well, so no correction path can reach the pin
  silently. Restriction and objection require the same case-specific operator
  decision a restored project does.
  """
  @spec assess_runtime_session_request(
          Account.t() | String.t(),
          String.t(),
          :correction | :restriction | :objection
        ) :: {:ok, map()} | {:error, :not_found}
  def assess_runtime_session_request(account_or_id, session_id, action)
      when action in [:correction, :restriction, :objection] do
    case scoped_runtime_session(account_or_id, session_id) do
      nil -> {:error, :not_found}
      %AIRuntimeSession{} = session -> {:ok, runtime_session_disposition(session, action)}
    end
  end

  def assess_runtime_session_request(_account_or_id, _session_id, _action),
    do: {:error, :not_found}

  @doc """
  Returns the verified operator disposition for restriction or objection.

  These requests require a case-specific operator decision; the function does
  not claim automatic legal resolution. It identifies every portability store,
  processor, derived record, and encrypted-backup handoff that the decision must
  propagate to.
  """
  @spec assess_portability_request(
          PersonalWorkspace.t() | DeviceWorkspace.t(),
          String.t(),
          :restriction | :objection
        ) :: {:ok, map()} | {:error, :not_found}
  def assess_portability_request(authority, project_id, action)
      when action in [:restriction, :objection] do
    case PackageProvenances.get(authority, project_id) do
      {:ok, %PackageProvenance{}} ->
        boundary = if match?(%PersonalWorkspace{}, authority), do: :hosted, else: :device

        {:ok,
         %{
           action: action,
           project_id: project_id,
           disposition: :verified_operator_assessment_required,
           propagation: review_propagation(boundary)
         }}

      _not_authorized_or_restored ->
        {:error, :not_found}
    end
  end

  def assess_portability_request(_authority, _project_id, _action),
    do: {:error, :not_found}

  @doc """
  Reports whether a departed participant's project label may still identify them.

  The decision is not a timer. A departed label serves project accountability
  until the durable revocation handoff is acknowledged; after that it names a
  person for no remaining purpose and anonymization becomes available. Returns
  `{:error, :not_found}` when no attribution links that account to the project,
  which is also the answer once anonymization has removed the link.
  """
  @spec assess_participation_attribution(String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, :not_found}
  def assess_participation_attribution(project_id, account_id) do
    case Participation.attribution_necessity(project_id, account_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {necessity, reason} ->
        {:ok,
         %{
           action: :anonymization,
           project_id: project_id,
           necessity: necessity,
           reason: reason,
           disposition: attribution_disposition(necessity),
           propagation: anonymization_propagation()
         }}
    end
  end

  @doc """
  Anonymizes one departed participant's historical project attribution.

  Two paths reach here, matching the two ways the retention of an identifying
  label ends. Without a verified request the necessity assessment must already
  say the label serves no remaining accountability purpose. A verified rights
  request overrides that judgement, because a person who has exercised erasure
  or objection does not wait for the project's own accountability interest to
  lapse. The caller owns the verification workflow that establishes the request;
  this boundary records only that a verified one was the basis.

  A current participant is refused on either path. Their label is their present
  name rather than historical attribution, and ending their participation is the
  step that makes it historical.
  """
  @spec anonymize_participation_attribution(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()}
          | {:error, :not_found | :attribution_necessary | :active_participation}
  def anonymize_participation_attribution(project_id, account_id, opts \\ []) do
    verified_request? = Keyword.get(opts, :verified_request, false)

    with :ok <- authorize_anonymization(project_id, account_id, verified_request?),
         {:ok, result} <- Participation.anonymize_member_attribution(project_id, account_id) do
      {:ok,
       %{
         action: :anonymization,
         project_id: project_id,
         basis: anonymization_basis(verified_request?),
         profile_id: result.profile.id,
         anonymous_label: Participation.anonymous_member_label(),
         derived_revocations: result.derived_revocations,
         propagation: anonymization_propagation()
       }}
    end
  end

  @doc """
  Anonymizes every remaining departed label in a project being deleted.

  An approved project-deletion event ends the accountability purpose of the
  whole project's history at once, so no departed label survives it still naming
  a person. Deleting the project row itself removes these records outright
  through their own cascade; this serves a deletion workflow that retires the
  project while its history is still being wound down.
  """
  @spec anonymize_project_participation_attribution(String.t()) :: {:ok, map()}
  def anonymize_project_participation_attribution(project_id) do
    {:ok, result} = Participation.anonymize_project_attribution(project_id)

    {:ok,
     %{
       action: :anonymization,
       project_id: project_id,
       basis: :project_deletion,
       anonymous_label: Participation.anonymous_member_label(),
       profiles: result.profiles,
       derived_revocations: result.derived_revocations,
       propagation: anonymization_propagation()
     }}
  end

  @doc """
  Exports credential-free passwordless attempt lifecycle data for a normalized
  verified email. The caller is responsible for the operator verification
  workflow before invoking this boundary.
  """
  @spec export_passwordless_attempts(String.t()) ::
          {:ok, [map()]} | {:error, :invalid_email}
  def export_passwordless_attempts(email) when is_binary(email) do
    with {:ok, %{subject_key: email_key}} <- ExternalIdentity.normalize_email(email) do
      {:ok, export_magic_link_attempts([email_key])}
    end
  end

  def export_passwordless_attempts(_email), do: {:error, :invalid_email}

  @doc """
  Deletes passwordless attempts for a normalized verified email, including
  attempts that never produced an account.
  """
  @spec erase_passwordless_attempts(String.t()) ::
          {:ok, non_neg_integer()} | {:error, :invalid_email}
  def erase_passwordless_attempts(email) when is_binary(email) do
    with {:ok, %{subject_key: email_key}} <- ExternalIdentity.normalize_email(email) do
      {count, _} =
        Repo.delete_all(
          from attempt in MagicLinkAttempt,
            where: attempt.email_key == ^email_key
        )

      {:ok, count}
    end
  end

  def erase_passwordless_attempts(_email), do: {:error, :invalid_email}

  defp maybe_delete_workspace(multi, nil), do: multi

  defp maybe_delete_workspace(multi, %PersonalWorkspace{id: workspace_id}) do
    Multi.delete_all(multi, :workspace, from(w in Workspace, where: w.id == ^workspace_id))
  end

  # A surviving account's erasure also removes its minimal merge evidence, which
  # carries no foreign key back to the account or workspace.
  defp delete_merge_records(multi, nil), do: multi

  defp delete_merge_records(multi, %PersonalWorkspace{id: workspace_id}) do
    Multi.delete_all(
      multi,
      :merge_records,
      from(r in WorkspaceMergeRecord,
        where: r.surviving_workspace_id == ^workspace_id or r.source_workspace_id == ^workspace_id
      )
    )
  end

  defp delete_magic_link_attempts(multi, email_keys) do
    Multi.delete_all(
      multi,
      :magic_link_attempts,
      from(attempt in MagicLinkAttempt, where: attempt.email_key in ^email_keys)
    )
  end

  defp export_identity(account_id) do
    case Repo.one(from i in GitHubIdentity, where: i.account_id == ^account_id) do
      nil ->
        nil

      identity ->
        %{
          github_user_id: identity.github_user_id,
          login: identity.login,
          avatar_url: identity.avatar_url
        }
    end
  end

  defp export_hosted_identity(account_id) do
    case hosted_identity(account_id) do
      nil ->
        nil

      identity ->
        %{
          id: identity.id,
          external_identities:
            identity.id
            |> external_identities()
            |> Enum.map(fn external_identity ->
              %{
                provider: external_identity.provider,
                subject_key: external_identity.subject_key,
                display_identifier: external_identity.display_identifier,
                verified_at: external_identity.verified_at
              }
            end)
        }
    end
  end

  defp export_account_magic_link_attempts(account_id) do
    account_id
    |> email_subject_keys()
    |> export_magic_link_attempts()
  end

  defp export_import_attempts(account_id) do
    from(attempt in ImportAttempt,
      join: workspace in PersonalWorkspace,
      on: workspace.id == attempt.workspace_id,
      where: workspace.account_id == ^account_id,
      order_by: [asc: attempt.inserted_at],
      select: %{
        id: attempt.id,
        destination: attempt.destination,
        status: attempt.status,
        expires_at: attempt.expires_at,
        inserted_at: attempt.inserted_at,
        updated_at: attempt.updated_at
      }
    )
    |> Repo.all()
  end

  # The opaque worker-profile reference is deliberately absent. It names the
  # worker-local profile that holds the credential and serves no purpose in an
  # access copy; the account already knows which of its own devices is paired.
  defp export_personal_ai_connections(account_id) do
    from(connection in PersonalAIConnection,
      where: connection.account_id == ^account_id,
      order_by: [asc: connection.inserted_at, asc: connection.id],
      select: %{
        id: connection.id,
        worker_id: connection.worker_id,
        label: connection.label,
        provider: connection.provider,
        authentication_mode: connection.authentication_mode,
        availability: connection.availability,
        adapter_compatibility_version: connection.adapter_compatibility_version,
        revocation_state: connection.revocation_state,
        revocation_requested_at: connection.revocation_requested_at,
        revocation_acknowledged_at: connection.revocation_acknowledged_at,
        credential_removal_result: connection.credential_removal_result,
        credential_removal_failure_reason: connection.credential_removal_failure_reason,
        deletion_scheduled_at: connection.deletion_scheduled_at,
        inserted_at: connection.inserted_at
      }
    )
    |> Repo.all()
  end

  # Catalog and quota snapshots are personal data for exactly as long as they are
  # held, so the access copy reports them explicitly instead of omitting them as
  # a cache. It reports what is actually stored, which includes a snapshot whose
  # lifetime has passed but which the retention sweep has not deleted yet; the
  # stored expiry is exported alongside it so the copy is not read as current.
  defp export_model_catalog_snapshots(account_id) do
    from(snapshot in ModelCatalogSnapshot,
      where: snapshot.account_id == ^account_id,
      order_by: [asc: snapshot.retrieved_at, asc: snapshot.id],
      select: %{
        id: snapshot.id,
        connection_id: snapshot.connection_id,
        provider: snapshot.provider,
        status: snapshot.status,
        source: snapshot.source,
        source_method: snapshot.source_method,
        source_version: snapshot.source_version,
        retrieved_at: snapshot.retrieved_at,
        expires_at: snapshot.expires_at,
        models: snapshot.models,
        inserted_at: snapshot.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | models: stored_items(&1.models)})
  end

  defp export_quota_snapshots(account_id) do
    from(snapshot in QuotaSnapshot,
      where: snapshot.account_id == ^account_id,
      order_by: [asc: snapshot.retrieved_at, asc: snapshot.id],
      select: %{
        id: snapshot.id,
        connection_id: snapshot.connection_id,
        provider: snapshot.provider,
        authentication_mode: snapshot.authentication_mode,
        status: snapshot.status,
        source: snapshot.source,
        source_methods: snapshot.source_methods,
        source_version: snapshot.source_version,
        retrieved_at: snapshot.retrieved_at,
        expires_at: snapshot.expires_at,
        buckets: snapshot.buckets,
        reset_credits: snapshot.reset_credits,
        token_activity: snapshot.token_activity,
        unknown_fields: snapshot.unknown_fields,
        inserted_at: snapshot.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | buckets: stored_items(&1.buckets)})
  end

  defp stored_items(%{"items" => items}) when is_list(items), do: items
  defp stored_items(_other), do: []

  # The pin is the person's own record of what ran, and it holds no credential,
  # no provider account identity, no worker-profile reference, and no raw
  # provider error, so the access copy reports every stored field. A session
  # whose connection has been removed reports an absent reference rather than
  # being omitted, because the run it accounts for still happened.
  defp export_ai_runtime_sessions(account_id) do
    from(session in AIRuntimeSession,
      where: session.account_id == ^account_id,
      order_by: [asc: session.pinned_at, asc: session.id],
      select: %{
        id: session.id,
        connection_id: session.connection_id,
        consumer_kind: session.consumer_kind,
        consumer_ref: session.consumer_ref,
        provider: session.provider,
        authentication_mode: session.authentication_mode,
        model: session.model,
        reasoning_effort: session.reasoning_effort,
        configuration_version: session.configuration_version,
        catalog_snapshot_ref: session.catalog_snapshot_ref,
        catalog_source: session.catalog_source,
        catalog_source_method: session.catalog_source_method,
        catalog_source_version: session.catalog_source_version,
        catalog_retrieved_at: session.catalog_retrieved_at,
        catalog_expires_at: session.catalog_expires_at,
        opt_ins: session.opt_ins,
        spending_ceiling_amount: session.spending_ceiling_amount,
        spending_ceiling_currency: session.spending_ceiling_currency,
        pinned_at: session.pinned_at,
        inserted_at: session.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | opt_ins: AIRuntimeSession.decode_opt_ins(&1.opt_ins)})
  end

  # The ledger is the minimized usage record of one API-key session: the
  # approved ceiling, the official price version the reservations were
  # calculated from, what is reserved and observed against it, and whether the
  # session is paused. It carries no provider invoice and no payment credential.
  defp export_runtime_cost_ledgers(account_id) do
    from(ledger in RuntimeCostLedger,
      where: ledger.account_id == ^account_id,
      order_by: [asc: ledger.inserted_at, asc: ledger.id],
      select: %{
        id: ledger.id,
        session_id: ledger.session_id,
        currency: ledger.currency,
        ceiling: ledger.ceiling,
        price_version: ledger.price_version,
        price_source: ledger.price_source,
        price_published_at: ledger.price_published_at,
        price_expires_at: ledger.price_expires_at,
        input_unit_price: ledger.input_unit_price,
        output_unit_price: ledger.output_unit_price,
        max_input_tokens: ledger.max_input_tokens,
        max_output_tokens: ledger.max_output_tokens,
        reserved_amount: ledger.reserved_amount,
        observed_amount: ledger.observed_amount,
        outstanding_reservations: ledger.outstanding_reservations,
        paused: ledger.paused,
        pause_reason: ledger.pause_reason,
        paused_at: ledger.paused_at,
        inserted_at: ledger.inserted_at
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | outstanding_reservations: stored_reservations(&1)})
  end

  defp stored_reservations(%{outstanding_reservations: reservations}),
    do: RuntimeCostLedger.decode_reservations(reservations)

  # A deleted project must leave no pinned configuration still naming it. The
  # project is the authority for its own reference in either consumer kind; a run
  # or conversation reference the project does not itself record is retired by
  # that consumer's own deletion path through the same boundary. Device-held
  # projects reach no hosted account scope, so they retire nothing here.
  defp retire_project_runtime_consumers(%PersonalWorkspace{account_id: account_id}, project_id) do
    {:ok, retired} =
      retire_runtime_consumers(account_id, [
        {:working_agent, project_id},
        {:support_assistant, project_id}
      ])

    retired
  end

  defp retire_project_runtime_consumers(_authority, _project_id), do: no_runtime_records()

  defp group_runtime_consumers(consumers) do
    consumers
    |> Enum.flat_map(&normalize_runtime_consumer/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {kind, refs} -> {kind, Enum.uniq(refs)} end)
  end

  defp normalize_runtime_consumer({kind, ref}) when is_atom(kind) and is_binary(ref),
    do: normalize_runtime_consumer({Atom.to_string(kind), ref})

  defp normalize_runtime_consumer({kind, ref}) when is_binary(kind) and is_binary(ref) do
    if kind in AIRuntimeSession.consumer_kinds(), do: [{kind, ref}], else: []
  end

  defp normalize_runtime_consumer(_consumer), do: []

  defp delete_runtime_consumers(account_id, grouped) do
    retired = retired_session_ids(account_id, grouped)

    {:ok, counts} =
      Repo.transaction(fn ->
        {cost_ledgers, _} =
          Repo.delete_all(
            from ledger in RuntimeCostLedger, where: ledger.session_id in subquery(retired)
          )

        {sessions, _} =
          Repo.delete_all(
            from session in AIRuntimeSession, where: session.id in subquery(retired)
          )

        %{sessions: sessions, cost_ledgers: cost_ledgers}
      end)

    Map.merge(counts, %{action: :erasure, propagation: deletion_propagation(:hosted)})
  end

  defp retired_session_ids(account_id, grouped) do
    named =
      Enum.reduce(grouped, dynamic(false), fn {kind, refs}, acc ->
        dynamic(
          [session],
          ^acc or (session.consumer_kind == ^kind and session.consumer_ref in ^refs)
        )
      end)

    from(session in AIRuntimeSession,
      where: session.account_id == ^account_id,
      where: ^named,
      select: session.id
    )
  end

  defp no_runtime_records do
    %{action: :erasure, sessions: 0, cost_ledgers: 0, propagation: deletion_propagation(:hosted)}
  end

  # Nothing is written, so the refusal reports the access boundary it leaves
  # untouched rather than a pending decision.
  defp runtime_session_disposition(session, :correction) do
    %{
      action: :correction,
      session_id: session.id,
      disposition: :refused_immutable_accountability_evidence,
      reason: :pinned_configuration_is_the_record_of_what_ran,
      available_actions: [:access, :portability, :erasure, :restriction, :objection],
      propagation: access_propagation(:hosted)
    }
  end

  defp runtime_session_disposition(session, action) do
    %{
      action: action,
      session_id: session.id,
      disposition: :verified_operator_assessment_required,
      propagation: review_propagation(:hosted)
    }
  end

  defp scoped_runtime_session(account_or_id, session_id) do
    with {:ok, account_id} <- runtime_account_id(account_or_id),
         {:ok, session_id} <- cast_runtime_id(session_id) do
      Repo.one(
        from session in AIRuntimeSession,
          where: session.account_id == ^account_id and session.id == ^session_id
      )
    else
      _unidentified -> nil
    end
  end

  defp runtime_account_id(%Account{id: id}), do: cast_runtime_id(id)
  defp runtime_account_id(id), do: cast_runtime_id(id)

  defp cast_runtime_id(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast_runtime_id(_id), do: :error

  defp export_magic_link_attempts(email_keys) do
    from(attempt in MagicLinkAttempt,
      where: attempt.email_key in ^email_keys,
      order_by: [desc: attempt.inserted_at],
      select: %{
        id: attempt.id,
        delivery_email: attempt.delivery_email,
        delivery_status: attempt.delivery_status,
        expires_at: attempt.expires_at,
        consumed_at: attempt.consumed_at,
        invalidated_at: attempt.invalidated_at,
        failure_code: attempt.failure_code,
        inserted_at: attempt.inserted_at
      }
    )
    |> Repo.all()
  end

  defp export_hosted_sessions(account_id) do
    case hosted_identity(account_id) do
      nil ->
        []

      identity ->
        from(session in HostedSession,
          where: session.hosted_identity_id == ^identity.id,
          order_by: [desc: session.last_seen_at],
          select: %{
            id: session.id,
            user_agent_family: session.user_agent_family,
            os_family: session.os_family,
            first_seen_at: session.first_seen_at,
            last_seen_at: session.last_seen_at,
            expires_at: session.expires_at
          }
        )
        |> Repo.all()
    end
  end

  defp hosted_identity(account_id) do
    Repo.one(from identity in HostedIdentity, where: identity.account_id == ^account_id)
  end

  defp email_subject_keys(account_id) do
    case hosted_identity(account_id) do
      nil ->
        []

      identity ->
        from(external_identity in ExternalIdentity,
          where:
            external_identity.hosted_identity_id == ^identity.id and
              external_identity.provider == "email",
          select: external_identity.subject_key
        )
        |> Repo.all()
    end
  end

  defp external_identities(hosted_identity_id) do
    from(external_identity in ExternalIdentity,
      where: external_identity.hosted_identity_id == ^hosted_identity_id,
      order_by: [asc: external_identity.provider, asc: external_identity.inserted_at]
    )
    |> Repo.all()
  end

  defp export_projects(account_id) do
    workspace = Repo.one(from w in PersonalWorkspace, where: w.account_id == ^account_id)

    case workspace do
      nil ->
        []

      %PersonalWorkspace{id: workspace_id} ->
        from(p in Project,
          where: p.workspace_id == ^workspace_id,
          order_by: [asc: p.name],
          preload: [:repository_connection, :hosted_local_repository_binding]
        )
        |> Repo.all()
        |> Enum.map(&export_project/1)
    end
  end

  defp export_project(project) do
    %{
      id: project.id,
      name: project.name,
      storage_mode: project.storage_mode,
      repository_identity: %{
        provider: project.repository_provider,
        repository_id: project.canonical_repository_id
      },
      repository: export_connection(project.repository_connection),
      hosted_local_repository_binding:
        export_hosted_local_binding(project.hosted_local_repository_binding),
      provenance: export_provenance(Repo.get(PackageProvenance, project.id)),
      specifications: export_specifications(project.id)
    }
  end

  defp export_hosted_local_binding(nil), do: nil

  defp export_hosted_local_binding(%HostedLocalRepositoryBinding{} = binding) do
    %{
      project_id: binding.project_id,
      worker_id: binding.worker_id,
      last_validated_at: binding.last_validated_at
    }
  end

  defp export_provenance(nil), do: nil

  defp export_provenance(%PackageProvenance{} = provenance) do
    %{
      payload_schema_version: provenance.payload_schema_version,
      restored_at: provenance.restored_at
    }
  end

  defp export_current_specification(specification) do
    %{
      id: specification.id,
      title: specification.title,
      current_revision_id: specification.revision_id,
      current_revision: %{
        id: specification.revision_id,
        requirements_document: specification.requirements,
        design_document: specification.design,
        tasks_document: specification.tasks
      }
    }
  end

  defp export_specifications(project_id) do
    from(specification in ProjectSpecification,
      where: specification.project_id == ^project_id,
      order_by: [asc: specification.id]
    )
    |> Repo.all()
    |> Enum.map(fn specification ->
      %{
        id: specification.id,
        title: specification.title,
        current_revision_id: specification.current_revision_id,
        inserted_at: specification.inserted_at,
        updated_at: specification.updated_at,
        revisions: export_revisions(project_id, specification.id)
      }
    end)
  end

  defp export_revisions(project_id, specification_id) do
    from(revision in SpecificationRevision,
      where:
        revision.project_id == ^project_id and
          revision.specification_id == ^specification_id,
      order_by: [asc: revision.sequence],
      select: %{
        id: revision.id,
        sequence: revision.sequence,
        requirements_document: revision.requirements_document,
        design_document: revision.design_document,
        tasks_document: revision.tasks_document,
        content_digest: revision.content_digest,
        actor_ref: revision.actor_ref,
        inserted_at: revision.inserted_at
      }
    )
    |> Repo.all()
  end

  defp export_connection(nil), do: nil

  defp export_connection(connection) do
    %{
      provider: connection.provider,
      provider_repository_id: connection.provider_repository_id,
      full_name: connection.full_name,
      visibility: connection.visibility,
      state: connection.state
    }
  end

  defp export_sessions(account_id) do
    from(s in ApplicationSession,
      where: s.account_id == ^account_id,
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
    |> Enum.map(fn session ->
      %{
        id: session.id,
        last_used_at: session.last_used_at,
        idle_expires_at: session.idle_expires_at,
        absolute_expires_at: session.absolute_expires_at,
        revoked_at: session.revoked_at
      }
    end)
  end

  defp authorize_anonymization(project_id, account_id, verified_request?) do
    case Participation.attribution_necessity(project_id, account_id) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:necessary, :active_participation} ->
        {:error, :active_participation}

      {:necessary, _pending_consumer_handoff} ->
        if verified_request?, do: :ok, else: {:error, :attribution_necessary}

      {:unnecessary, _lapsed} ->
        :ok
    end
  end

  defp anonymization_basis(true), do: :verified_rights_request
  defp anonymization_basis(false), do: :attribution_no_longer_necessary

  defp attribution_disposition(:necessary), do: :identifiable_attribution_necessary
  defp attribution_disposition(:unnecessary), do: :anonymization_available

  # What the anonymization has already reached, and what it hands on. The
  # primary store and this specification's own derived copy of the label are
  # anonymized before this is returned. Configured processors, caches, indexes,
  # and exports are the separate propagation contract, and encrypted recovery
  # copies are bounded by the backup lifecycle rather than rewritten in place:
  # the backup handoff is requested under the erasure action because the
  # requirement on a backup is the same either way, that it must not restore the
  # link that was removed.
  defp anonymization_propagation do
    %{
      primary_boundary: :hosted,
      primary_store: :anonymized,
      processors: [%{processor: :hosting_database, action: :anonymize, state: :applied}],
      derived_records: [
        %{record: :project_member_profile, action: :anonymize, state: :applied},
        %{record: :participation_revocation, action: :anonymize, state: :applied}
      ],
      pending_propagation: [
        %{record: :configured_processors, action: :anonymize},
        %{record: :caches, action: :anonymize},
        %{record: :indexes, action: :anonymize},
        %{record: :exports, action: :anonymize}
      ],
      encrypted_backups: backup_handoff(:erasure)
    }
  end

  defp access_propagation(boundary) do
    %{
      primary_boundary: boundary,
      processors: processors(boundary),
      derived_records: derived_records(boundary),
      encrypted_backups: backup_handoff(:access)
    }
  end

  defp deletion_propagation(boundary) do
    %{
      primary_boundary: boundary,
      primary_store: :deleted,
      processors: Enum.map(processors(boundary), &Map.put(&1, :action, :delete)),
      derived_records: Enum.map(derived_records(boundary), &%{record: &1, action: :delete}),
      encrypted_backups: backup_handoff(:erasure)
    }
  end

  defp review_propagation(boundary) do
    %{
      primary_boundary: boundary,
      primary_store: :pending_verified_operator_decision,
      processors: Enum.map(processors(boundary), &Map.put(&1, :action, :apply_operator_decision)),
      derived_records:
        Enum.map(
          derived_records(boundary),
          &%{
            record: &1,
            action: :apply_operator_decision
          }
        ),
      encrypted_backups: backup_handoff(:apply_operator_decision)
    }
  end

  defp processors(:hosted) do
    [
      %{processor: :hosting_database},
      %{processor: :authorized_device_worker, conditional: :hosted_local_binding}
    ]
  end

  defp processors(:device), do: [%{processor: :device_worker}]

  defp derived_records(:hosted) do
    [
      :current_project,
      :restored_specifications,
      :package_provenance,
      :hosted_local_repository_binding
    ]
  end

  defp derived_records(:device) do
    [:current_project, :restored_specifications, :package_provenance]
  end

  defp backup_handoff(action) do
    DeploymentPrivacyProfile.backup_handoff(action)
  end
end
