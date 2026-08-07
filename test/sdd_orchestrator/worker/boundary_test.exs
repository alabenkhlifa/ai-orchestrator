defmodule SddOrchestrator.Worker.BoundaryTest do
  @moduledoc """
  Task 2 proof: a cheap, deliberate architectural-boundary check. The
  worker's ongoing runtime (everything under `lib/sdd_orchestrator/worker/`
  and the `mix worker.start` task) must never reference the database repo or
  a Repo-backed control-plane context — even indirectly through new code —
  so a genuinely remote worker never needs them. `mix worker.pair` is
  exempt: it is the one-shot, explicitly local, database-backed pairing
  step.

  `SddOrchestrator.Delivery` also houses the pure, Repo-free worker-side
  primitives `design.md` names as consumed unchanged by this worker
  (`Delivery.Worker.*`, `ExecutionManifest`, `ProtocolCodec`,
  `WorkerProtocol`, `SecretBoundary`, `CanonicalJson`, `ProtocolLimits`), so
  a flat ban on the `Delivery` prefix would also ban composing them. Instead
  every `SddOrchestrator.Delivery.X` reference is checked against an
  explicit allowlist of `X`s; anything not on it — including a new
  Repo-backed context added later — fails closed.

  `SddOrchestrator.Accounts` gets the same treatment for exactly one shape:
  a bare, field-less `%SddOrchestrator.Accounts.PersonalWorkspace{}` struct
  literal. `RequiredCheckRunner` builds one to select
  `ArtifactUpload.upload/4`'s hosted-project clause, which dispatches purely
  on the struct's shape and never reads a field off it — no `Repo` call, no
  query, no `Accounts` context function invoked, so it violates none of this
  check's real intent. Every other `SddOrchestrator.Accounts.X` reference
  still fails closed, exactly like the `Delivery` allowlist above.
  """

  use ExUnit.Case, async: true

  @forbidden [
    "SddOrchestrator.Repo",
    "Ecto.Repo",
    "SddOrchestrator.Devices",
    "SddOrchestrator.Projects",
    "SddOrchestrator.Portability"
  ]

  # The pure, Repo-free `Delivery.*` primitives `design.md`'s "Components
  # Affected" list names as consumed unchanged by the worker. Verified by
  # inspection to reference neither `Repo.` nor `Ecto.Schema`.
  @allowed_delivery_modules ~w(
    AgentAdapter
    Worker
    ExecutionManifest
    ProtocolCodec
    WorkerProtocol
    SecretBoundary
    CanonicalJson
    ProtocolLimits
  )

  # The one `Accounts` struct this worker may reference: a bare, field-less
  # literal used only to select an `ArtifactUpload.upload/4` dispatch clause
  # (see the moduledoc). Never a database lookup.
  @allowed_accounts_modules ~w(PersonalWorkspace)

  @delivery_reference ~r/SddOrchestrator\.Delivery\.([A-Za-z0-9_]+)/
  @accounts_reference ~r/SddOrchestrator\.Accounts\.([A-Za-z0-9_]+)/

  @runtime_paths Path.wildcard("lib/sdd_orchestrator/worker/**/*.ex") ++
                   ["lib/mix/tasks/worker.start.ex"]

  test "the worker runtime path never references a database repo or control-plane context" do
    refute Enum.empty?(@runtime_paths)

    for path <- @runtime_paths do
      source = File.read!(path)

      for needle <- @forbidden do
        refute source =~ needle, "#{path} unexpectedly references #{needle}"
      end

      for [_full, submodule] <- Regex.scan(@delivery_reference, source) do
        assert submodule in @allowed_delivery_modules,
               "#{path} unexpectedly references SddOrchestrator.Delivery.#{submodule}, " <>
                 "which is not on the allowlisted set of pure worker-side primitives"
      end

      for [_full, submodule] <- Regex.scan(@accounts_reference, source) do
        assert submodule in @allowed_accounts_modules,
               "#{path} unexpectedly references SddOrchestrator.Accounts.#{submodule}, " <>
                 "which is not the allowlisted bare PersonalWorkspace struct literal"
      end
    end
  end

  test "mix worker.pair is exempt and is not part of the scanned runtime path" do
    refute "lib/mix/tasks/worker.pair.ex" in @runtime_paths
    assert File.exists?("lib/mix/tasks/worker.pair.ex")
  end
end
