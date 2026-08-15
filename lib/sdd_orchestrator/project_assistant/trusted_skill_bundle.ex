defmodule SddOrchestrator.ProjectAssistant.TrustedSkillBundle do
  @moduledoc """
  Task 6's pinned, integrity-checked SDD Orchestrator skill-bundle identity
  (AC-14, AC-15), and the compatibility negotiation every turn runs before
  the runtime session may use it.

  design.md's "Trusted-skill interface" asks for "a signed or equivalently
  integrity-pinned SDD Orchestrator skill version compatible with the
  read-tool manifest" that "reject[s] unknown, repository-provided,
  downloaded, changed, or permission-expanding instructions." No such skill
  bundle content has been authored anywhere in this codebase yet — the
  canonical skills under this repository's own `.agents/skills/` directory
  (`add-spec`, `implement-spec`, `review-spec`, `update-spec`) are Codex and
  Claude Code's own development-workflow tooling for building SDD
  Orchestrator itself, not a skill injected into an end participant's
  project-assistant runtime session. Authoring the actual injected skill
  bundle's instructions is a later concern; this module builds only the
  generic versioning and integrity-check CONTRACT a runtime session must
  match, exactly like `SddOrchestrator.Delivery.InitializationManifest`
  fixes a manifest shape and version without itself containing the agent's
  actual working instructions.

  `current/0` is the sole source of the pinned identity, built entirely from
  compile-time constants — never from a tool result, project content, or
  caller-supplied override. `digest/2` is a stable self-consistency hash
  over exactly that pinned `{name, version}` pair (mirroring
  `SddOrchestrator.ProjectAssistant.ProcessingSummary.digest/1`'s own
  length-prefixed canonical form rather than reaching into
  `Delivery.CanonicalJson`, which is a worker-protocol concern this
  project-independent digest has no reason to depend on). It proves internal
  consistency and that `negotiate/2` never widens, upgrades, or
  best-effort-matches a requested identity — not cryptographic
  unforgeability against a determined adversary who already knows this
  public formula. A deployment's actual signing or distribution-channel
  integrity mechanism is release-gate territory (design.md: "a signed or
  equivalently integrity-pinned" version), not this task's job: nothing in
  this codebase's real call paths ever constructs a negotiation request from
  repository, board, run, or evidence content in the first place, so the
  practical property this module guarantees — repository-provided content
  can never become the active skill identity — holds structurally regardless
  of the digest's cryptographic strength.
  """

  @bundle_name "sdd_orchestrator_project_assistant"
  @bundle_version 1
  @compatible_manifest_versions [1]

  @enforce_keys [:name, :version, :digest, :compatible_manifest_versions]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          digest: String.t(),
          compatible_manifest_versions: [pos_integer()]
        }

  @type request :: %{required(String.t()) => term()}

  @doc "The current, and only ever, pinned trusted skill-bundle identity."
  @spec current() :: t()
  def current do
    %__MODULE__{
      name: @bundle_name,
      version: @bundle_version,
      digest: digest(@bundle_name, @bundle_version),
      compatible_manifest_versions: @compatible_manifest_versions
    }
  end

  @spec bundle_name() :: String.t()
  def bundle_name, do: @bundle_name

  @spec bundle_version() :: pos_integer()
  def bundle_version, do: @bundle_version

  @doc """
  Negotiates compatibility between a requested skill-bundle identity and the
  read-tool manifest version it would run against.

  Mirrors `SddOrchestrator.Delivery.InitializationManifest.from_map/1`'s
  exact-version-match-or-typed-error pattern: nothing here widens, upgrades,
  or best-effort-matches a requested identity. Only the exact currently
  pinned `{name, version, digest}` is ever accepted
  (`{:ok, pinned_bundle}`), and only when it also declares the given
  manifest version compatible. Every other input — an unknown name, a wrong
  version, a mismatched digest, an unsupported manifest version, or a
  malformed request shape — refuses with a distinct typed reason and returns
  no bundle.
  """
  @spec negotiate(request(), pos_integer()) :: {:ok, t()} | {:error, atom()}
  def negotiate(%{"name" => name, "version" => version, "digest" => digest}, manifest_version)
      when is_integer(manifest_version) do
    pinned = current()

    cond do
      name != pinned.name ->
        {:error, :unknown_skill_bundle}

      version != pinned.version ->
        {:error, :unsupported_skill_version}

      digest != pinned.digest ->
        {:error, :bundle_integrity_mismatch}

      manifest_version not in pinned.compatible_manifest_versions ->
        {:error, :unsupported_manifest_version}

      true ->
        {:ok, pinned}
    end
  end

  def negotiate(_requested, _manifest_version), do: {:error, :invalid_skill_request}

  defp digest(name, version) do
    terms = [name, Integer.to_string(version)]

    terms
    |> Enum.map_join(fn term -> "#{byte_size(term)}:#{term}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
