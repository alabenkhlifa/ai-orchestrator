defmodule SddOrchestrator.Privacy.ParticipationGovernance do
  @moduledoc """
  The final participation-completion capability-provider registry and staged
  readiness record (specs/29 Task 1, AC-01, AC-02, AC-03).

  ## Scope: a literal registry, not a live filesystem or git check

  `capability_index.py` (`.agents/scripts/capability_index.py`) already
  mechanically parses every specification's `## Cross-Specification
  Dependencies` section from `tasks.md` at tooling time. Re-implementing that
  parser in Elixir, or having production code read `.md` files at runtime,
  would be unusual, fragile coupling from application code to specification
  documents. This module does neither.

  Instead it declares, as a literal Elixir data structure, the same seven
  `{capability, specification, task}` triples specs/29's own `tasks.md`
  `## Cross-Specification Dependencies` → `Requires:` list already names —
  copied by hand, not derived — and exposes pure functions that validate
  *that structure's own internal integrity*: no duplicate capability name, no
  duplicate `{specification, task}` provider reference, and an exact match
  against the seven capability names this specification requires. A spec
  drift (a capability renamed, added, or removed in `tasks.md`) is caught
  only when this module's literal data and its test are updated together —
  the same "reconcile, don't repeat" boundary design.md draws around focused
  provider proof.

  This module does not, and cannot, verify from inside the application
  whether a named provider task's checkbox is actually checked, whether its
  focused proof receipt was pasted into `progress.md`, or whether its
  readiness write-back was recorded — those are exactly the specification
  write-back facts `capability_index.py` and `validate_spec.py` are the
  authority for, confirmed by the orchestrating agent outside application
  code. What this module's `readiness/1` records is the local, deterministic
  half of the picture: whether the registry itself is well-formed and
  complete, and — as literal, non-fabricated data — that release readiness
  always remains a separate, unresolved gate (AC-03). Whether every provider
  is actually complete, compatible, and proven is established by two other
  things this task also delivers: the orchestrating agent's confirmation of
  each provider's proof receipt and write-back, and this same test file's
  real cross-provider integration suite exercising the seven providers
  together.

  ## No application data entity

  Nothing here is backed by an `Ecto.Schema`, and no function in this module
  reads or writes any provider-owned table. `readiness/1` and `published?/1`
  are pure functions of their input; calling them any number of times
  changes no persisted state and returns the same result every time, which
  is how "published exactly once" is provable without a persisted
  "governance published" row — the same "no application data entity" ruling
  design.md's Data and Access Boundaries makes explicit.
  """

  @capability_names ~w(
    project-participation-boundary
    project-owner-display-profile
    project-participation-recipient-routing
    participation-identity-lifecycle
    participation-processing-controls
    participation-operational-retention
    participation-deletion-recovery
  )

  # Copied by hand from specs/29-participation-completion/tasks.md's own
  # `## Cross-Specification Dependencies` → `Requires:` list. Keep this list
  # and that list identical; a mismatch here is a specification drift this
  # module cannot detect from inside the application, only a human update and
  # this file's own test can.
  @required_providers [
    %{
      capability: "project-participation-boundary",
      specification: "specs/08-project-participation",
      task: "Task 4"
    },
    %{
      capability: "project-owner-display-profile",
      specification: "specs/08-project-participation",
      task: "Task 34"
    },
    %{
      capability: "project-participation-recipient-routing",
      specification: "specs/08-project-participation",
      task: "Task 36"
    },
    %{
      capability: "participation-identity-lifecycle",
      specification: "specs/25-participation-identity-lifecycle",
      task: "Task 4"
    },
    %{
      capability: "participation-processing-controls",
      specification: "specs/26-participation-data-protection-controls",
      task: "Task 5"
    },
    %{
      capability: "participation-operational-retention",
      specification: "specs/27-participation-operational-retention",
      task: "Task 3"
    },
    %{
      capability: "participation-deletion-recovery",
      specification: "specs/28-participation-deletion-and-recovery",
      task: "Task 2"
    }
  ]

  @published_capability "project-participation-governance"

  @capability_pattern ~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @specification_pattern ~r/^specs\/[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/
  @task_pattern ~r/^Task \d+$/

  @type provider :: %{capability: String.t(), specification: String.t(), task: String.t()}

  @type validation_reason ::
          {:malformed_entry, term()}
          | {:duplicate_capability, String.t()}
          | {:duplicate_provider_reference, {String.t(), String.t()}}
          | {:capability_set_mismatch, %{missing: [String.t()], unexpected: [String.t()]}}

  @type readiness :: %{
          capability: String.t(),
          providers: [provider()],
          registry_valid?: boolean(),
          implementation_readiness: :established | :blocked,
          local_verification_readiness: :established | :blocked,
          release_readiness: :deferred_to_release_gate,
          earliest_blocked_stage: :implementation | nil,
          blocking_reasons: [validation_reason()]
        }

  @doc "The seven capability names this specification requires, in `tasks.md` order."
  @spec capability_names() :: [String.t()]
  def capability_names, do: @capability_names

  @doc """
  The literal capability-provider registry: one `{capability, specification,
  task}` triple per capability specs/29 requires, copied from `tasks.md`.
  """
  @spec required_providers() :: [provider()]
  def required_providers, do: @required_providers

  @doc "The one capability this specification is the sole provider of."
  @spec published_capability() :: String.t()
  def published_capability, do: @published_capability

  @doc """
  Validates one provider registry's internal integrity.

  Rejects a malformed entry (missing or non-binary `capability`,
  `specification`, or `task`, or a value outside the closed slug/reference
  shape), a duplicate capability name (including a *stale* provider: an
  older and a newer entry left in place for the same capability, naming two
  different provider tasks), a duplicate `{specification, task}` provider
  reference (two different capabilities claiming the same provider task),
  and a capability-name set that does not exactly match `capability_names/0`
  — catching both a missing capability and an unexpected/unknown one.

  Returns `:ok` for a structurally sound registry, or `{:error, reasons}`
  naming every defect found rather than only the first.
  """
  @spec validate_providers([provider()]) :: :ok | {:error, [validation_reason()]}
  def validate_providers(providers) when is_list(providers) do
    reasons =
      malformed_entry_reasons(providers) ++
        duplicate_capability_reasons(providers) ++
        duplicate_provider_reference_reasons(providers) ++
        capability_set_mismatch_reasons(providers)

    if reasons == [], do: :ok, else: {:error, reasons}
  end

  @doc """
  The staged readiness record for one provider registry, `required_providers/0`
  by default.

  When the registry is structurally sound, implementation and
  local-verification readiness are recorded `:established` and no blocked
  stage is reported (AC-02). When it is missing, duplicate, stale, or
  malformed, both are recorded `:blocked`, the earliest blocked readiness
  stage is `:implementation` (product and technical-design readiness are
  already approved ahead of this task; see specs/29's `requirements.md`), and
  `capability:project-participation-governance` is not published (AC-01).

  Release readiness is always reported `:deferred_to_release_gate` — never
  computed from, weakened, or strengthened by the registry's own validity —
  because no local, deterministic check can establish deployment-specific
  processor, transfer, retention-enforcement, notice, incident, or
  accountable-review evidence (AC-03).
  """
  @spec readiness([provider()]) :: readiness()
  def readiness(providers \\ required_providers()) do
    case validate_providers(providers) do
      :ok ->
        %{
          capability: @published_capability,
          providers: providers,
          registry_valid?: true,
          implementation_readiness: :established,
          local_verification_readiness: :established,
          release_readiness: :deferred_to_release_gate,
          earliest_blocked_stage: nil,
          blocking_reasons: []
        }

      {:error, reasons} ->
        %{
          capability: @published_capability,
          providers: providers,
          registry_valid?: false,
          implementation_readiness: :blocked,
          local_verification_readiness: :blocked,
          release_readiness: :deferred_to_release_gate,
          earliest_blocked_stage: :implementation,
          blocking_reasons: reasons
        }
    end
  end

  @doc """
  Whether `capability:project-participation-governance` is published for one
  provider registry.

  A pure, repeatable read of `readiness/1`: publication follows only from
  every required provider resolving to one well-formed, non-duplicate,
  non-stale registry entry — never from a side effect, a persisted flag, or
  how many times this function has already been called.
  """
  @spec published?([provider()]) :: boolean()
  def published?(providers \\ required_providers()) do
    case readiness(providers) do
      %{implementation_readiness: :established, local_verification_readiness: :established} ->
        true

      _blocked ->
        false
    end
  end

  defp malformed_entry_reasons(providers) do
    for entry <- providers, not well_formed?(entry), do: {:malformed_entry, entry}
  end

  defp well_formed?(%{capability: capability, specification: specification, task: task})
       when is_binary(capability) and is_binary(specification) and is_binary(task) do
    Regex.match?(@capability_pattern, capability) and
      Regex.match?(@specification_pattern, specification) and
      Regex.match?(@task_pattern, task)
  end

  defp well_formed?(_malformed), do: false

  defp duplicate_capability_reasons(providers) do
    providers
    |> Enum.filter(&well_formed?/1)
    |> Enum.frequencies_by(& &1.capability)
    |> Enum.filter(fn {_capability, count} -> count > 1 end)
    |> Enum.map(fn {capability, _count} -> {:duplicate_capability, capability} end)
  end

  defp duplicate_provider_reference_reasons(providers) do
    providers
    |> Enum.filter(&well_formed?/1)
    |> Enum.frequencies_by(&{&1.specification, &1.task})
    |> Enum.filter(fn {_reference, count} -> count > 1 end)
    |> Enum.map(fn {reference, _count} -> {:duplicate_provider_reference, reference} end)
  end

  defp capability_set_mismatch_reasons(providers) do
    declared =
      providers
      |> Enum.map(&declared_capability/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    required = MapSet.new(@capability_names)
    missing = required |> MapSet.difference(declared) |> Enum.sort()
    unexpected = declared |> MapSet.difference(required) |> Enum.sort()

    if missing == [] and unexpected == [] do
      []
    else
      [{:capability_set_mismatch, %{missing: missing, unexpected: unexpected}}]
    end
  end

  defp declared_capability(%{capability: capability}) when is_binary(capability), do: capability
  defp declared_capability(_malformed), do: nil
end
