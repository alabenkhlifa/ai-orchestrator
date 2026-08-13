defmodule SddOrchestrator.RepositoryKits do
  @moduledoc """
  Global, immutable catalog of vendored SDD kit packages, and the
  project-scoped, worker-local change-planning built on top of it.

  A package is inspectable, versioned, and content-addressed. Publication is
  in-memory ingestion only: `publish_package/2` performs no disk or network
  I/O and never executes package content — reading files off disk is the
  `mix repository_kits.publish` task's job. The catalog is global rather than
  project-scoped, so every catalog function here takes no project or account
  authority; any authenticated participant may read it, and the LiveView
  route enforces the authentication boundary.

  `plan_change/4` and `current_plan/3`, by contrast, are project-scoped and
  read/write one project's `RepositoryKitChangePlan` — see that schema's
  moduledoc for the exact comparison, persistence, and dual-authority
  boundaries. `apply_plan/4` is likewise project-scoped: it applies one
  owner-confirmed, conflict-free plan on a new isolated branch and persists
  the resulting `RepositoryKitInstallation` — see that schema's moduledoc —
  and is idempotent: retrying the exact same confirmed plan returns the
  already-persisted installation unchanged rather than mutating the
  repository a second time. `plan_update/4` and `current_installation/3`
  extend the same pattern for an already-installed project: a newer catalog
  package is never selected or applied automatically, and building an update
  plan compares the new package against both the live repository and this
  project's currently-installed file ownership, so only files still proven
  to be kit-owned and unchanged are ever silently overwritten. `plan_removal/3`
  extends the same pattern once more (AC-11): it builds a plan to remove an
  installed kit's own files on a new isolated branch, and carries the exact
  same guarantee in the other direction — only files still proven
  kit-owned-and-unchanged are ever silently deleted; anything that drifted
  since it was recorded blocks the entire removal plan instead.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.Features
  alias SddOrchestrator.Devices
  alias SddOrchestrator.ManagedRuntimeProfile
  alias SddOrchestrator.Participation
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryAssessments

  alias SddOrchestrator.RepositoryKits.{
    ChangePlanStore,
    InstallationStore,
    RepositoryKitChangePlan,
    RepositoryKitInstallation,
    RepositoryKitPackage,
    WorkerKitApply,
    WorkerKitComparison,
    WorkerKitRemovalComparison,
    WorkerKitUpdateComparison
  }

  @max_files 500
  @max_file_bytes 512_000
  @max_package_bytes 5_000_000

  @eligible_lifecycle_columns ~w(ready_for_review done)
  @plan_ttl_seconds 15 * 60

  @package_attrs [
    :source,
    :publisher,
    :version,
    :license,
    :provenance,
    :supported_adapters,
    :required_permissions,
    :scripts
  ]

  @field_error_priority [
    {:source, :invalid_source},
    {:publisher, :invalid_publisher},
    {:version, :invalid_version},
    {:license, :invalid_license},
    {:digest, :invalid_digest},
    {:provenance, :invalid_provenance},
    {:supported_adapters, :invalid_adapters},
    {:required_permissions, :invalid_permissions},
    {:scripts, :invalid_scripts}
  ]

  @type file_input :: %{path: binary(), content: binary(), executable: boolean()}

  @doc """
  Publishes one immutable kit package from already-read attrs and files.

  `attrs` carries only in-memory scalar and structural fields; `files` carries
  already-read file bytes. Neither this function nor anything it calls
  touches disk or the network, and package content is never executed — it is
  only measured, hashed, and base64-encoded.
  """
  @spec publish_package(map(), [file_input()]) ::
          {:ok, RepositoryKitPackage.t()} | {:error, atom()}
  def publish_package(attrs, files) when is_map(attrs) and is_list(files) do
    with :ok <- validate_files(files) do
      file_manifest = build_file_manifest(files)
      digest = RepositoryKitPackage.digest_of(file_manifest)

      package_attrs =
        attrs
        |> Map.take(@package_attrs)
        |> normalize_provenance()
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:digest, digest)
        |> Map.put(:file_manifest, file_manifest)

      %RepositoryKitPackage{}
      |> RepositoryKitPackage.publish_changeset(package_attrs)
      |> Repo.insert()
      |> case do
        {:ok, package} -> {:ok, package}
        {:error, changeset} -> {:error, error_atom(changeset)}
      end
    end
  end

  def publish_package(_attrs, _files), do: {:error, :invalid_request}

  @doc "Reads one package by id."
  @spec get_package(Ecto.UUID.t()) :: {:ok, RepositoryKitPackage.t()} | {:error, :not_found}
  def get_package(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> found_or_not_found(Repo.get(RepositoryKitPackage, uuid))
      :error -> {:error, :not_found}
    end
  end

  def get_package(_id), do: {:error, :not_found}

  @doc "Reads one package by its exact content digest."
  @spec get_by_digest(String.t()) :: {:ok, RepositoryKitPackage.t()} | {:error, :not_found}
  def get_by_digest(digest) when is_binary(digest) do
    found_or_not_found(Repo.get_by(RepositoryKitPackage, digest: digest))
  end

  def get_by_digest(_digest), do: {:error, :not_found}

  @doc "Lists every package ordered by source, publisher, then real semver."
  @spec list_packages() :: [RepositoryKitPackage.t()]
  def list_packages do
    RepositoryKitPackage
    |> Repo.all()
    |> Enum.sort(&package_lte?/2)
  end

  @doc """
  Returns the newest other package sharing this package's `source` and
  `publisher` whose version compares strictly greater, or `nil`.

  Supersession is always derived at read time from the immutable catalog; no
  row is ever mutated or linked to record it.
  """
  @spec superseded_by(RepositoryKitPackage.t(), [RepositoryKitPackage.t()]) ::
          RepositoryKitPackage.t() | nil
  def superseded_by(%RepositoryKitPackage{} = package, all_packages \\ list_packages()) do
    all_packages
    |> Enum.filter(fn candidate ->
      candidate.id != package.id and candidate.source == package.source and
        candidate.publisher == package.publisher and
        Version.compare(candidate.version, package.version) == :gt
    end)
    |> Enum.reduce(nil, &newest/2)
  end

  @doc """
  Reports whether the optional permanent-kit offer may appear for one pilot
  specification.

  Resolves the linked feature through
  `capability:guided-delivery-feature-specification-link`
  (`Delivery.Features.fetch_by_specification/2`) and reads its
  `lifecycle_column`. No linked feature, or a column short of `Ready for
  review`/`Done`, is not-yet-eligible rather than an error — the offer
  simply does not appear yet.
  """
  @spec eligible_for_kit_offer?(String.t(), String.t()) :: boolean()
  def eligible_for_kit_offer?(project_id, specification_id) do
    case Features.fetch_by_specification(project_id, specification_id) do
      {:ok, feature} -> feature.lifecycle_column in @eligible_lifecycle_columns
      {:error, :not_linked} -> false
    end
  end

  @doc """
  Builds and persists one worker-local `RepositoryKitChangePlan`.

  Refuses with `{:error, :not_yet_eligible}` when the pilot has not reached
  `Ready for review` or `Done` — a data-layer defense in depth so the
  eligibility business rule is enforced here, not only by a later task's
  UI, since the eligibility read is this module's own owned surface.
  Otherwise propagates `ManagedRuntimeProfile.build/3`'s own refusals
  (`:no_approved_profile`, `:no_pilot_selected`, `:stale_profile`,
  `:stale_pilot_revision`, `:unsupported_authority`) unchanged, and fails
  closed with `:stale_commit` when the live repository's exact commit no
  longer matches the approved profile's base commit.

  `opts[:repository_path]` is required: the worker-local git checkout to
  compare against. It is never derived from stored project data, and it
  never appears in the persisted plan. `opts[:now]` overrides the clock for
  `expires_at`; every other option is forwarded to
  `ManagedRuntimeProfile.build/3` and `RepositoryAssessments.profile_review/3`.

  Persistence is hosted-only for now — see `RepositoryKitChangePlan`'s
  moduledoc. A `{:device, _}` authority reaches every read-only step (the
  comparison itself is authority-agnostic) and is refused only at the final
  persistence step, with `{:error, :unsupported_authority}`.
  """
  @spec plan_change(ManagedRuntimeProfile.authority(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, atom()}
  def plan_change(authority, project_id, package_id, opts \\ []) do
    with {:ok, repository_path} <- fetch_repository_path(opts),
         {:ok, profile_value} <- ManagedRuntimeProfile.build(authority, project_id, opts),
         :ok <- eligible?(project_id, profile_value.pilot_specification_id),
         {:ok, execution_profile} <-
           matching_execution_profile(authority, project_id, profile_value, opts),
         {:ok, package} <- get_package(package_id),
         protected_paths <- protected_paths(execution_profile),
         {:ok, operations} <-
           WorkerKitComparison.compare(
             repository_path,
             profile_value.base_revision,
             profile_value.root,
             package.file_manifest["files"],
             protected_paths
           ) do
      persist_plan(authority, project_id, profile_value, package, operations, opts)
    end
  end

  @doc """
  Reads the project's current change plan: the most recent row that has not
  yet expired. There is no separate mutable "current plan" pointer — this is
  always a read-time derivation.

  A `{:hosted, account_id}` or `{:participant, account_id, hosted_identity_id}`
  viewer may read a hosted project's plan, and a `{:device, %DeviceWorkspace{}}`
  viewer that owns the project may read a device project's plan; anything
  else returns `{:error, :not_found}` rather than disclosing why. Dispatch
  and every authorization rule live in `ChangePlanStore` — see its
  moduledoc.
  """
  @spec current_plan(ChangePlanStore.viewer(), String.t(), keyword()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, :not_found}
  def current_plan(viewer, project_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ChangePlanStore.current(viewer, project_id, now)
  end

  @doc """
  Reads the project's current kit installation, if any — the one row a
  project may have, now that `project_id` is uniquely indexed.

  Mirrors `current_plan/3`'s exact authorization shape: a `{:hosted,
  account_id}` owner, a `{:participant, account_id, hosted_identity_id}`
  visible viewer, or a `{:device, %DeviceWorkspace{}}` authority that owns
  the project may read it; anything else returns `{:error, :not_found}`
  rather than disclosing why. Dispatch and every authorization rule live in
  `InstallationStore` — see its moduledoc.
  """
  @spec current_installation(InstallationStore.viewer(), String.t(), keyword()) ::
          {:ok, RepositoryKitInstallation.t()} | {:error, :not_found}
  def current_installation(viewer, project_id, opts \\ [])

  def current_installation(viewer, project_id, _opts) do
    InstallationStore.current(viewer, project_id)
  end

  @doc """
  Applies one owner-confirmed, unexpired, conflict-free `RepositoryKitChangePlan`
  on a new isolated branch and persists the resulting `RepositoryKitInstallation`.

  Only the project owner may confirm application — business rule "Only the
  project owner may approve installation". A `{:hosted, account_id}`
  authority that owns the project or a `{:device, %DeviceWorkspace{}}`
  authority that owns the project is the only accepted shape; a
  `{:participant, ...}` viewer (read-only for plans), an unowned device
  authority, or anything else is refused with `{:error, :unauthorized}`
  through a catch-all clause, mirroring `current_plan/3`'s own catch-all. A
  device project has no separate owner/participant distinction, so "owns the
  device project" is the full check there, exactly as `ChangePlanStore.Device`
  already requires for building a plan.

  Idempotent (AC-09): once this exact `plan_id` already has a persisted
  installation, a retry returns that same installation unchanged without
  touching the repository again or re-running the expiry or conflict gates
  — the repository was already mutated once for this plan, and only a
  changed input (a different plan, from a fresh comparison) should ever
  cause a further mutation. Otherwise refuses with `{:error, :plan_expired}`
  once `plan.expires_at` has passed (compared against `opts[:now]`,
  defaulting to `DateTime.utc_now/0`), and with
  `{:error, :safety_conflict_present}` or
  `{:error, :ordinary_conflicts_present}` for a plan that still has either
  kind of conflict (AC-06) — a conflicting plan is simply refused, never
  overridden.

  Plan-type aware: an `"install"` plan inserts a new `RepositoryKitInstallation`
  row; an `"update"` plan (AC-10, from `plan_update/4`) updates the project's
  existing row in place via `RepositoryKitInstallation.update_changeset/2`,
  recording a snapshot of the pre-update state in `history`.

  `opts[:repository_path]` is required for the exact same reason
  `plan_change/4`'s is: it is the worker-local git checkout to apply
  against, never derived from stored project data. Every
  `WorkerKitApply.apply/5` error atom propagates unchanged.
  """
  @spec apply_plan(ManagedRuntimeProfile.authority(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, RepositoryKitInstallation.t()} | {:error, atom()}
  def apply_plan(authority, project_id, plan_id, opts \\ [])

  def apply_plan({:hosted, account_id} = authority, project_id, plan_id, opts) do
    with {:ok, repository_path} <- fetch_repository_path(opts),
         {:ok, _project} <- Participation.owned_project(account_id, project_id) do
      do_apply_plan(authority, project_id, plan_id, repository_path, opts)
    end
  end

  def apply_plan({:device, %DeviceWorkspace{}} = authority, project_id, plan_id, opts) do
    with {:ok, repository_path} <- fetch_repository_path(opts),
         {:ok, _project} <- authorize_device_project(authority, project_id) do
      do_apply_plan(authority, project_id, plan_id, repository_path, opts)
    end
  end

  def apply_plan(_authority, _project_id, _plan_id, _opts), do: {:error, :unauthorized}

  # Shared by both `apply_plan/4` clauses once their own authorization has
  # passed — the exact-plan fetch, idempotency check, and confirmed-plan
  # apply are authority-agnostic worker/git logic.
  defp do_apply_plan(authority, project_id, plan_id, repository_path, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, plan} <- ChangePlanStore.get(authority, project_id, plan_id) do
      case fetch_installation_by_plan(authority, project_id, plan.id) do
        {:ok, installation} ->
          {:ok, installation}

        {:error, :not_found} ->
          apply_confirmed_plan(authority, project_id, plan, repository_path, now)
      end
    end
  end

  defp apply_confirmed_plan(authority, project_id, plan, repository_path, now) do
    with :ok <- not_expired(plan, now),
         :ok <- no_conflicts(plan),
         {:ok, result} <-
           WorkerKitApply.apply(
             repository_path,
             plan.base_commit,
             plan.root,
             plan.target_branch,
             plan.operations
           ) do
      persist_installation(authority, project_id, plan, result, now)
    end
  end

  @doc """
  Builds and persists one worker-local `"update"` `RepositoryKitChangePlan`
  for a project that already has a current `RepositoryKitInstallation`.

  Sibling to `plan_change/4`, reusing everything that applies and skipping
  the pilot-eligibility gate: `eligible_for_kit_offer?/2` governs only the
  *initial* offer, and an update is available once something is installed,
  independent of the pilot's lifecycle column. Refuses with
  `{:error, :not_installed}` when the project has no current installation —
  business rule "a newer available version is information only until the
  owner starts an explicit update" (AC-10): there is nothing to update yet.
  Otherwise propagates `ManagedRuntimeProfile.build/3`'s own refusals
  unchanged, exactly as `plan_change/4` does.

  The comparison is `WorkerKitUpdateComparison.compare/6`, not
  `WorkerKitComparison.compare/5`: it additionally compares against the
  current installation's own recorded `installed_files`, so a file this
  project's kit already owns and that changed live since installation
  produces a `"drifted"` conflict rather than being silently overwritten.

  `opts[:repository_path]` is required, for the same reason `plan_change/4`'s
  is.
  """
  @spec plan_update(ManagedRuntimeProfile.authority(), String.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, atom()}
  def plan_update(authority, project_id, new_package_id, opts \\ []) do
    with {:ok, repository_path} <- fetch_repository_path(opts),
         {:ok, installation} <- fetch_current_installation(authority, project_id),
         {:ok, profile_value} <- ManagedRuntimeProfile.build(authority, project_id, opts),
         {:ok, execution_profile} <-
           matching_execution_profile(authority, project_id, profile_value, opts),
         {:ok, package} <- get_package(new_package_id),
         protected_paths <- protected_paths(execution_profile),
         {:ok, operations} <-
           WorkerKitUpdateComparison.compare(
             repository_path,
             profile_value.base_revision,
             profile_value.root,
             package.file_manifest["files"],
             protected_paths,
             installation.installed_files
           ) do
      persist_plan(authority, project_id, profile_value, package, operations, opts, "update")
    end
  end

  @doc """
  Builds and persists one worker-local `"removal"` `RepositoryKitChangePlan`
  for a project that already has a current `RepositoryKitInstallation`
  (AC-11).

  Removal always targets the currently-installed package — there is no
  "choose a different package to remove" concept, so unlike `plan_change/4`
  and `plan_update/4` this takes no package id argument.

  Sibling to `plan_update/4`: skips `eligible_for_kit_offer?/2` for the exact
  same already-documented reason (removal must be available once something
  is installed, independent of the pilot's lifecycle column), and skips
  `matching_execution_profile/4`/`protected_paths/1` entirely — neither is
  needed, because a protected or safety path is never a `"create"` operation
  at install or update time, so it can never appear in a current
  installation's `installed_files` to begin with. Refuses with
  `{:error, :not_installed}` when the project has no *active* installation —
  `fetch_current_installation/1` now excludes an already-`"removed"` row, so
  removing twice is refused the same way updating an already-removed
  installation is.

  The comparison is `WorkerKitRemovalComparison.compare/5`, not
  `WorkerKitComparison.compare/5` or `WorkerKitUpdateComparison.compare/6`:
  it iterates the current installation's own recorded `installed_files`
  (never the package's proposed files) and classifies each as safely
  removable (`"delete"`), already absent (`"omit"`), or drifted since it was
  recorded (`"conflict"`/`"drifted"`) — a file that drifted blocks the
  entire removal plan at `apply_plan/4`, exactly as a drifted file blocks an
  entire update plan.

  `opts[:repository_path]` is required, for the same reason `plan_change/4`'s
  and `plan_update/4`'s are.
  """
  @spec plan_removal(ManagedRuntimeProfile.authority(), String.t(), keyword()) ::
          {:ok, RepositoryKitChangePlan.t()} | {:error, atom()}
  def plan_removal(authority, project_id, opts \\ []) do
    with {:ok, repository_path} <- fetch_repository_path(opts),
         {:ok, installation} <- fetch_current_installation(authority, project_id),
         {:ok, profile_value} <- ManagedRuntimeProfile.build(authority, project_id, opts),
         {:ok, package} <- get_package(installation.package_id),
         {:ok, operations} <-
           WorkerKitRemovalComparison.compare(
             repository_path,
             profile_value.base_revision,
             profile_value.root,
             package.file_manifest["files"],
             installation.installed_files
           ) do
      persist_plan(authority, project_id, profile_value, package, operations, opts, "removal")
    end
  end

  ## Change-plan building (private)

  defp fetch_repository_path(opts) do
    case Keyword.get(opts, :repository_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _missing -> {:error, :repository_path_required}
    end
  end

  defp eligible?(project_id, specification_id) do
    if eligible_for_kit_offer?(project_id, specification_id),
      do: :ok,
      else: {:error, :not_yet_eligible}
  end

  defp matching_execution_profile(authority, project_id, profile_value, opts) do
    review_opts = Keyword.take(opts, [:assessment_store, :profile_store])

    case RepositoryAssessments.profile_review(authority, project_id, review_opts) do
      {:ok, %{profiles: profiles}} ->
        case Enum.find(profiles, &(&1.version == profile_value.profile_version)) do
          nil -> {:error, :stale_profile}
          profile -> {:ok, profile}
        end

      {:error, _reason} ->
        {:error, :stale_profile}
    end
  end

  defp protected_paths(execution_profile) do
    execution_profile.instruction_precedence
    |> Enum.map(& &1["path"])
    |> MapSet.new()
  end

  defp persist_plan(
         authority,
         project_id,
         profile_value,
         package,
         operations,
         opts,
         plan_type \\ "install"
       ) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      package_id: package.id,
      package_digest: package.digest,
      profile_version: profile_value.profile_version,
      base_commit: profile_value.base_revision,
      root: profile_value.root,
      repository_provider: profile_value.repository_provider,
      repository_id: profile_value.repository_id,
      target_branch: target_branch(package, plan_type),
      operations: operations,
      expires_at: DateTime.add(now, @plan_ttl_seconds, :second),
      plan_type: plan_type
    }

    ChangePlanStore.create(authority, attrs)
  end

  # A short, deterministic, git-branch-safe name tied to this exact package's
  # identity: the publisher and version for legibility, plus an 8-character
  # digest prefix so it stays unique even across two packages that happen to
  # share a publisher and version string but not a source (the catalog's own
  # uniqueness is on the full `{source, publisher, version}` triple, one
  # level wider than publisher + version alone).
  #
  # `plan_type` selects a distinct prefix for a `"removal"` plan (point of
  # this branching): without it, a removal plan for an already-installed
  # package's own `installation.package_id` would generate the exact same
  # branch name as the install (or last update) branch that already exists
  # in the repository, and `WorkerKitApply.apply/5`'s own
  # `refuse_existing_branch/2` gate would then reject every removal apply
  # with `:branch_conflict`. An `"install"` or `"update"` plan keeps the
  # original, unprefixed-beyond-`sdd-kit/` shape unchanged.
  defp target_branch(package, plan_type) do
    slug =
      package.publisher
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")

    digest_suffix = String.slice(package.digest, 0, 8)

    target_branch_prefix(plan_type) <> "#{slug}-#{package.version}-#{digest_suffix}"
  end

  defp target_branch_prefix("removal"), do: "sdd-kit/remove-"
  defp target_branch_prefix(_install_or_update), do: "sdd-kit/"

  ## Installation reads (private)

  # Only a genuinely active installation (`"applied"` or `"updated"`) counts
  # here — a `"removed"` row still exists (Task 6 never deletes the record,
  # only its files), but it is not something a further update or removal can
  # target. `current_installation/3` (the public, viewer-facing read) is a
  # separate concern and deliberately does not apply this filter: the
  # LiveView still needs to see a `"removed"` row to render the removed
  # confirmation and its branch/commit. Unauthenticated at this layer, same
  # as before Task 8: both callers (`plan_update/4`, `plan_removal/3`)
  # already authorize `authority` against `project_id` themselves through
  # `ManagedRuntimeProfile.build/3`, later in the same `with` chain.
  defp fetch_current_installation(authority, project_id) do
    case InstallationStore.raw(authority, project_id) do
      {:ok, %RepositoryKitInstallation{state: state} = installation}
      when state in ["applied", "updated"] ->
        {:ok, installation}

      _not_active ->
        {:error, :not_installed}
    end
  end

  ## Apply (private)

  defp authorize_device_project(
         {:device, %DeviceWorkspace{id: authority_id} = workspace},
         project_id
       ) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device", status: "connected"} = project} <-
           Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(workspace, project) do
      {:ok, project}
    else
      _missing -> {:error, :unauthorized}
    end
  end

  # The plan's own FK, not its state, is what matters for this idempotency
  # check — unauthenticated at this layer for the same reason
  # `fetch_current_installation/2` is: `apply_plan/4`'s own authorization
  # already ran before this is ever called.
  defp fetch_installation_by_plan(authority, project_id, plan_id) do
    case InstallationStore.raw(authority, project_id) do
      {:ok, %RepositoryKitInstallation{plan_id: ^plan_id} = installation} -> {:ok, installation}
      _no_match -> {:error, :not_found}
    end
  end

  defp not_expired(plan, now) do
    if DateTime.compare(plan.expires_at, now) == :gt,
      do: :ok,
      else: {:error, :plan_expired}
  end

  defp no_conflicts(plan) do
    cond do
      plan.safety_blocked -> {:error, :safety_conflict_present}
      plan.has_ordinary_conflicts -> {:error, :ordinary_conflicts_present}
      true -> :ok
    end
  end

  defp persist_installation(authority, project_id, plan, result, now) do
    case plan.plan_type do
      "update" ->
        persist_transition_installation(authority, project_id, plan, result, now, "updated")

      "removal" ->
        persist_transition_installation(authority, project_id, plan, result, now, "removed")

      _install ->
        persist_install_installation(authority, project_id, plan, result, now)
    end
  end

  defp persist_install_installation(authority, project_id, plan, result, now) do
    attrs = %{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      package_id: plan.package_id,
      plan_id: plan.id,
      package_digest: plan.package_digest,
      profile_version: plan.profile_version,
      base_commit: plan.base_commit,
      root: plan.root,
      repository_provider: plan.repository_provider,
      repository_id: plan.repository_id,
      branch: plan.target_branch,
      result_commit: result.commit,
      installed_files: result.installed_files,
      evidence: result.evidence,
      confirmed_by_actor_ref: actor_ref(authority),
      confirmed_at: now
    }

    InstallationStore.create(authority, attrs)
  end

  # Should be unreachable in practice: `plan_update/4` and `plan_removal/3`
  # already refuse to build a plan when there is no active installation, so
  # by the time an update or removal plan reaches `apply_plan/4` a current
  # installation should always exist. Checked defensively anyway rather than
  # assumed. Shared by both transitions (Task 5's update and Task 6's
  # removal) since they overwrite the exact same "current state" fields and
  # differ only in the target `state` string — `installed_files` needs no
  # transition-specific handling here: `result.installed_files` is already
  # `[]` for a removal plan, since a removal plan never contains a
  # `"create"` operation (`WorkerKitApply.apply/5` only ever returns a
  # `file_entry` for a `"create"`). The current installation is read here
  # (any state, unauthenticated at this layer — see
  # `fetch_current_installation/2`'s own comment) purely to build the
  # `history` snapshot; `InstallationStore.transition/3` does its own
  # authorized fetch of the row it actually overwrites.
  defp persist_transition_installation(authority, project_id, plan, result, now, state) do
    case InstallationStore.raw(authority, project_id) do
      {:error, :not_found} ->
        {:error, :not_installed}

      {:ok, current} ->
        attrs = %{
          package_id: plan.package_id,
          package_digest: plan.package_digest,
          plan_id: plan.id,
          profile_version: plan.profile_version,
          base_commit: plan.base_commit,
          root: plan.root,
          repository_provider: plan.repository_provider,
          repository_id: plan.repository_id,
          branch: plan.target_branch,
          result_commit: result.commit,
          installed_files: result.installed_files,
          state: state,
          evidence: result.evidence,
          confirmed_by_actor_ref: actor_ref(authority),
          confirmed_at: now,
          history: [installation_snapshot(current, state) | current.history]
        }

        InstallationStore.transition(authority, project_id, attrs)
    end
  end

  defp actor_ref({:hosted, account_id}), do: account_id
  defp actor_ref({:device, %DeviceWorkspace{id: id}}), do: id

  # A small, JSON-safe snapshot of the pre-transition installation state — no
  # absolute paths, no secrets, same evidence-hygiene rule as the `evidence`
  # field's own. `event` names the transition that produced this snapshot
  # (`"updated"` or `"removed"`) so the audit history accurately reflects
  # what happened, rather than always reading `"updated"` even for a
  # removal.
  defp installation_snapshot(%RepositoryKitInstallation{} = installation, event) do
    %{
      "event" => event,
      "package_id" => installation.package_id,
      "package_digest" => installation.package_digest,
      "plan_id" => installation.plan_id,
      "branch" => installation.branch,
      "result_commit" => installation.result_commit,
      "state" => installation.state,
      "confirmed_at" => DateTime.to_iso8601(installation.confirmed_at)
    }
  end

  ## Attrs normalization (pure, no I/O)

  # Provenance is always stored (and read back from jsonb) with string keys.
  # Callers such as the mix task naturally build it with atom keys, so this
  # normalizes either shape to one canonical stored representation.
  defp normalize_provenance(attrs) do
    case Map.fetch(attrs, :provenance) do
      {:ok, %{} = provenance} ->
        Map.put(attrs, :provenance, Map.new(provenance, fn {k, v} -> {to_string(k), v} end))

      _other ->
        attrs
    end
  end

  ## File validation (pure, no I/O)

  defp validate_files([]), do: {:error, :no_files}

  defp validate_files(files) when length(files) > @max_files, do: {:error, :too_many_files}

  defp validate_files(files) do
    Enum.reduce_while(files, {:ok, MapSet.new(), 0}, fn file, {:ok, seen_paths, total_size} ->
      with {:ok, path} <- validate_path(Map.get(file, :path)),
           :ok <- ensure_unique_path(path, seen_paths),
           {:ok, content} <- validate_content(Map.get(file, :content)) do
        {:cont, {:ok, MapSet.put(seen_paths, path), total_size + byte_size(content)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _paths, total_size} when total_size > @max_package_bytes ->
        {:error, :package_too_large}

      {:ok, _paths, _total_size} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_path(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :invalid_path}
      byte_size(path) > 255 -> {:error, :invalid_path}
      String.starts_with?(path, "/") -> {:error, :invalid_path}
      String.contains?(path, <<0>>) -> {:error, :invalid_path}
      ".." in Path.split(path) -> {:error, :path_escape}
      true -> {:ok, path}
    end
  end

  defp validate_path(_path), do: {:error, :invalid_path}

  defp ensure_unique_path(path, seen_paths) do
    if MapSet.member?(seen_paths, path), do: {:error, :duplicate_path}, else: :ok
  end

  defp validate_content(content) when is_binary(content) do
    if byte_size(content) > @max_file_bytes,
      do: {:error, :file_too_large},
      else: {:ok, content}
  end

  defp validate_content(_content), do: {:error, :invalid_path}

  defp build_file_manifest(files) do
    built =
      Enum.map(files, fn %{path: path, content: content, executable: executable} ->
        %{
          "path" => path,
          "content" => Base.encode64(content),
          "sha256" => content |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower),
          "size" => byte_size(content),
          "executable" => !!executable
        }
      end)

    %{"files" => built}
  end

  ## Ordering and supersession

  defp package_lte?(a, b) do
    cond do
      a.source != b.source -> a.source < b.source
      a.publisher != b.publisher -> a.publisher < b.publisher
      true -> Version.compare(a.version, b.version) != :gt
    end
  end

  defp newest(candidate, nil), do: candidate

  defp newest(candidate, current) do
    if Version.compare(candidate.version, current.version) == :gt, do: candidate, else: current
  end

  ## Error mapping

  defp found_or_not_found(nil), do: {:error, :not_found}
  defp found_or_not_found(package), do: {:ok, package}

  defp error_atom(%Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end) do
      :already_exists
    else
      error_atom_for_field(errors)
    end
  end

  defp error_atom_for_field(errors) do
    Enum.find_value(@field_error_priority, :invalid_package, fn {field, atom} ->
      if Keyword.has_key?(errors, field), do: atom
    end)
  end
end
