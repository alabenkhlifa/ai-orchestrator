defmodule SddOrchestrator.RepositoryInitialization do
  @moduledoc """
  Pre-project plan lifecycle for empty-repository initialization (specs/16 Task 2).

  A plan tracks the read-only, sequential product-first and
  technical-foundation question gate (AC-03) behind one eligible empty
  target (AC-01): `purpose -> users -> first_outcome -> constraints ->
  technical_foundation -> ready`. Only the plan's own `current_field` may be
  answered; accepting an answer both advances the cursor and creates a new
  plan version in the same update, so the version history is exactly the
  sequence of accepted answers. Nothing here ever touches the filesystem —
  the plan is a governed record only, matching AC-02's no-mutation rule.

  Once a plan reaches `"ready"`, Task 3's review and confirmation functions
  apply (AC-04, AC-05, AC-06, AC-07): `default_kit/0`, `set_kit_choice/2`,
  `disclose_processing_boundary/1`, `confirmation_snapshot/1`, and
  `confirm_plan/3`. Every one of them that takes a plan refuses with a typed
  error — never raising, never silently no-op-ing — unless that plan's
  `current_field` is `"ready"`: Task 2's question gate must be fully
  complete before any review or confirmation action applies.

  `get_plan/2` and `confirm_plan/3` are scoped to the caller's own device
  workspace (specs/16 Task 7, AC-15's access rule) — a plan belonging to a
  different workspace is refused `{:error, :not_found}` exactly as an
  unknown id is, never disclosed to exist. `confirm_plan/3`, and every
  public entry point through Task 4/5/6's staging, publish, and handoff
  pipeline, is audited through `SecurityLog.audit/2`: only a failure is
  logged, and only as a fixed, redacted outcome class, never the plan's own
  content.
  """

  import Ecto.Query

  alias SddOrchestrator.Delivery.CanonicalJson
  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization.{Plan, SecurityLog, Skeleton}
  alias SddOrchestrator.RepositoryKits
  alias SddOrchestrator.RepositoryKits.RepositoryKitPackage

  @disclosure_version 1

  @type create_attrs :: %{
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:target_reference) => String.t(),
          required(:eligibility) => String.t(),
          optional(:account_id) => Ecto.UUID.t() | nil
        }

  @doc "Creates one new plan at version 1, with the cursor on `purpose`."
  @spec create_plan(create_attrs()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(attrs) do
    %Plan{}
    |> Plan.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Fetches one plan by id, scoped to the caller's own device workspace.

  Refuses `{:error, :not_found}` for a plan that exists but belongs to a
  different device workspace, exactly as for an unknown id — a caller never
  learns whether the id exists elsewhere.
  """
  @spec get_plan(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, :not_found}
  def get_plan(device_workspace_id, id) do
    with {:ok, workspace_uuid} <- Ecto.UUID.cast(device_workspace_id),
         {:ok, uuid} <- Ecto.UUID.cast(id) do
      query =
        from p in Plan,
          where: p.device_workspace_id == ^workspace_uuid and p.id == ^uuid

      case Repo.one(query) do
        %Plan{} = plan -> {:ok, plan}
        nil -> {:error, :not_found}
      end
    else
      _invalid -> {:error, :not_found}
    end
  end

  @doc """
  Accepts one answer for the plan's current field.

  This is the decision gate (AC-03): `field` is only accepted when it equals
  `plan.current_field`, so a caller cannot skip ahead (for example, straight
  to `technical_foundation` before `purpose`, `users`, `first_outcome`, and
  `constraints` are all answered). A rejected field writes nothing. Acceptance
  writes the value, advances the cursor, and bumps `version` by exactly one,
  all in a single update — the versioning mechanism this plan relies on.
  """
  @spec answer_field(Plan.t(), String.t(), term()) ::
          {:ok, Plan.t()} | {:error, :out_of_order | :invalid_answer | Ecto.Changeset.t()}
  def answer_field(%Plan{} = plan, field, value) when is_binary(field) do
    with :ok <- validate_current_field(plan, field),
         {:ok, field_atom, cast_value} <- cast_answer(field, value) do
      plan
      |> Plan.answer_changeset(%{
        field_atom => cast_value,
        current_field: Plan.next_field(field),
        version: plan.version + 1
      })
      |> Repo.update()
    end
  end

  def answer_field(_plan, _field, _value), do: {:error, :invalid_answer}

  defp validate_current_field(%Plan{current_field: current_field}, field) do
    if field == current_field, do: :ok, else: {:error, :out_of_order}
  end

  defp cast_answer(field, value)
       when field in ["purpose", "users", "first_outcome", "constraints", "technical_foundation"] do
    normalize_value(Plan.field_atom(field), value)
  end

  defp cast_answer(_field, _value), do: {:error, :invalid_answer}

  defp normalize_value(:technical_foundation, %{} = value) when not is_struct(value) do
    if map_size(value) > 0,
      do: {:ok, :technical_foundation, value},
      else: {:error, :invalid_answer}
  end

  defp normalize_value(:technical_foundation, value) when is_binary(value) do
    with {:ok, trimmed} <- non_blank(value) do
      {:ok, :technical_foundation, %{"summary" => trimmed}}
    end
  end

  defp normalize_value(field, value) when is_binary(value) do
    with {:ok, trimmed} <- non_blank(value) do
      {:ok, field, trimmed}
    end
  end

  defp normalize_value(_field, _value), do: {:error, :invalid_answer}

  defp non_blank(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_answer}
      trimmed -> {:ok, trimmed}
    end
  end

  # ---- Task 3: review, kit choice, disclosure, and confirmation ----

  @doc "The current processing-boundary disclosure version (AC-05)."
  @spec disclosure_version() :: pos_integer()
  def disclosure_version, do: @disclosure_version

  @doc """
  Returns the newest published kit package in the catalog, or
  `{:error, :no_kit_available}` when the catalog is empty.

  "Newest" is the entry with the greatest `version` by `Version.compare/2` —
  the same idiom `RepositoryKits.superseded_by/2` already uses. There is at
  most one real published kit in this system today; nothing more elaborate
  than "newest version wins" is warranted yet.
  """
  @spec default_kit() :: {:ok, RepositoryKitPackage.t()} | {:error, :no_kit_available}
  def default_kit do
    case RepositoryKits.list_packages() do
      [] -> {:error, :no_kit_available}
      packages -> {:ok, Enum.reduce(packages, &newest_package/2)}
    end
  end

  @doc """
  Records the reviewed plan's kit choice (default-included permanent SDD
  kit, AC-06's decline path).

  Refuses unless `plan.current_field == "ready"`. Including with no kit in
  the catalog refuses `{:error, :no_kit_available}` — the LiveView should
  already prevent offering "include" in that case, but this function does
  not trust the caller. Always clears `confirmed_at`/`confirmation_digest`
  as a safety default: a changed kit choice invalidates any prior
  confirmation (AC-07).
  """
  @spec set_kit_choice(Plan.t(), String.t()) ::
          {:ok, Plan.t()}
          | {:error,
             :plan_not_ready | :no_kit_available | :invalid_kit_choice | Ecto.Changeset.t()}
  def set_kit_choice(%Plan{} = plan, "included") do
    with :ok <- ensure_ready(plan),
         {:ok, package} <- default_kit() do
      plan
      |> Plan.kit_choice_changeset(%{
        kit_choice: "included",
        kit_package_id: package.id,
        kit_package_digest: package.digest,
        confirmed_at: nil,
        confirmation_digest: nil
      })
      |> Repo.update()
    end
  end

  def set_kit_choice(%Plan{} = plan, "declined") do
    with :ok <- ensure_ready(plan) do
      plan
      |> Plan.kit_choice_changeset(%{
        kit_choice: "declined",
        kit_package_id: nil,
        kit_package_digest: nil,
        confirmed_at: nil,
        confirmation_digest: nil
      })
      |> Repo.update()
    end
  end

  def set_kit_choice(_plan, _choice), do: {:error, :invalid_kit_choice}

  @doc """
  Marks the processing-boundary disclosure (AC-05) as shown, gating
  `confirm_plan/3`.

  Idempotent: setting it again while already set at the current version is a
  no-op that still succeeds. Refuses unless `plan.current_field == "ready"`.
  """
  @spec disclose_processing_boundary(Plan.t()) ::
          {:ok, Plan.t()} | {:error, :plan_not_ready | Ecto.Changeset.t()}
  def disclose_processing_boundary(%Plan{} = plan) do
    with :ok <- ensure_ready(plan) do
      if plan.disclosure_version == @disclosure_version do
        {:ok, plan}
      else
        plan
        |> Plan.disclosure_changeset(%{disclosure_version: @disclosure_version})
        |> Repo.update()
      end
    end
  end

  @doc """
  Returns the exact map of fields the business rules bind one confirmation
  to: plan version, target reference, technical foundation, kit choice, kit
  package digest, the fixed skeleton's commands and checks, and the
  disclosure version.

  This is what the client "saw" — the LiveView renders it, and `confirm_plan/3`
  re-derives and compares against it, so both share one definition of what's
  bound. Refuses unless `plan.current_field == "ready"`.
  """
  @spec confirmation_snapshot(Plan.t()) :: {:ok, map()} | {:error, :plan_not_ready}
  def confirmation_snapshot(%Plan{} = plan) do
    with :ok <- ensure_ready(plan) do
      {:ok, build_snapshot(plan)}
    end
  end

  @doc """
  Confirms the exact plan (AC-06's exact-plan confirmation), binding
  `confirmation_digest` to the sha256 hex of the canonical JSON encoding of
  `confirmation_snapshot/1`'s bound-field map.

  `device_workspace_id` is the caller's own authenticated device workspace —
  never read from the passed-in `plan` struct — and scopes the re-fetch
  through `get_plan/2` (specs/16 Task 7's access rule), so a plan belonging
  to a different workspace is refused `{:error, :not_found}` exactly as an
  unknown id is. `client_snapshot` is what the caller (the LiveView, from
  what it rendered) believes the bound fields are. This always re-fetches the
  plan by id and re-derives its live snapshot rather than trusting either the
  caller's passed-in `plan` struct or its `client_snapshot` claim — the
  changed-input invalidation check (AC-07) — and refuses `{:error,
  :plan_changed}` unless the live snapshot matches exactly. Refuses
  `{:error, :disclosure_required}` when the processing-boundary disclosure
  has not been shown yet.
  """
  @spec confirm_plan(Plan.t(), Ecto.UUID.t(), map()) ::
          {:ok, Plan.t()}
          | {:error,
             :plan_not_ready
             | :disclosure_required
             | :plan_changed
             | :not_found
             | :invalid_snapshot
             | Ecto.Changeset.t()}
  def confirm_plan(%Plan{id: id}, device_workspace_id, client_snapshot)
      when is_binary(device_workspace_id) and is_map(client_snapshot) do
    with {:ok, live_plan} <- get_plan(device_workspace_id, id),
         :ok <- ensure_ready(live_plan),
         :ok <- ensure_disclosed(live_plan),
         {:ok, live_snapshot} <- confirmation_snapshot(live_plan),
         :ok <- ensure_unchanged(live_snapshot, client_snapshot) do
      persist_confirmation(live_plan, live_snapshot)
    end
    |> SecurityLog.audit(:confirm_plan)
  end

  def confirm_plan(_plan, _device_workspace_id, _client_snapshot),
    do: SecurityLog.audit({:error, :invalid_snapshot}, :confirm_plan)

  defp newest_package(candidate, current) do
    if Version.compare(candidate.version, current.version) == :gt, do: candidate, else: current
  end

  defp ensure_ready(%Plan{current_field: "ready"}), do: :ok
  defp ensure_ready(%Plan{}), do: {:error, :plan_not_ready}

  defp ensure_disclosed(%Plan{disclosure_version: nil}), do: {:error, :disclosure_required}
  defp ensure_disclosed(%Plan{}), do: :ok

  defp ensure_unchanged(live_snapshot, client_snapshot) do
    if live_snapshot == client_snapshot, do: :ok, else: {:error, :plan_changed}
  end

  defp build_snapshot(plan) do
    skeleton = Skeleton.content()

    %{
      "version" => plan.version,
      "target_reference" => plan.target_reference,
      "technical_foundation" => plan.technical_foundation,
      "kit_choice" => plan.kit_choice,
      "kit_package_digest" => plan.kit_package_digest,
      "commands" => Map.fetch!(skeleton, "commands"),
      "checks" => Map.fetch!(skeleton, "checks"),
      "disclosure_version" => plan.disclosure_version
    }
  end

  defp persist_confirmation(plan, snapshot) do
    {:ok, encoded} = CanonicalJson.encode(snapshot)
    digest = encoded |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    plan
    |> Plan.confirm_changeset(%{
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      confirmation_digest: digest
    })
    |> Repo.update()
  end
end
