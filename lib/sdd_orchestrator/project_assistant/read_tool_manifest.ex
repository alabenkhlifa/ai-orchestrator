defmodule SddOrchestrator.ProjectAssistant.ReadToolManifest do
  @moduledoc """
  Task 6's closed read-tool allowlist (AC-14, AC-15): the exact nine
  operation names design.md's "Read-tool broker interface" names, and
  nothing else.

  Mirrors `SddOrchestrator.Delivery.InitializationManifest`'s shape — an
  `@enforce_keys` immutable struct with a fixed version constant and a
  stable digest — for the same reason: an inspectable, hashable identity a
  caller can compare rather than trust by convention. It deliberately does
  not reuse that module directly: `InitializationManifest` is
  `Delivery`-owned, pre-project, and carries a `capability_grant` enum
  (`plan_discovery`/`staging_write`) with no equivalent here — a
  project-assistant turn never negotiates a write capability at all.

  `current/0` is the *only* constructor a caller ever needs, and it takes no
  argument. There is therefore no code path anywhere that builds a manifest
  from external input, model output, or a tool result — the structural
  property AC-14 depends on. Every call returns a value equal to every other
  call (`ReadToolManifest.current() == ReadToolManifest.current()` always
  holds), proven directly in the test suite rather than merely documented.

  `operation_bindings/0` names the exact Task 3/4/5 function each allowed
  name dispatches to, so the closed list is not just nine strings but nine
  proven live bindings (`Kernel.function_exported?/3` checked in tests) —
  never an aspirational name with nothing behind it. This module reimplements
  none of those functions' own project, participant, or source-authority
  scoping; it only gates *which* name may be dispatched at all, never *how*
  the bound function itself authorizes or shapes its result.
  """

  alias SddOrchestrator.ProjectAssistant.{
    ProjectContextAssembler,
    RepositoryDiscoverer,
    RepositoryObserver
  }

  @manifest_version 1

  @operation_names ~w(
    project-summary
    specification-current
    board-current
    recent-run
    evidence-current
    repository-state
    repository-tree
    repository-search
    repository-lines
  )

  # Every name's bound arity is the function's FULL arity (its trailing
  # `opts` argument included), never the reduced arity a default parameter
  # also exports, so this table names one unambiguous binding per operation.
  @operation_bindings %{
    "project-summary" => {ProjectContextAssembler, :assemble, 3},
    "specification-current" => {ProjectContextAssembler, :assemble, 3},
    "board-current" => {ProjectContextAssembler, :assemble, 3},
    "recent-run" => {ProjectContextAssembler, :assemble, 3},
    "evidence-current" => {ProjectContextAssembler, :assemble, 3},
    "repository-state" => {RepositoryObserver, :observe, 4},
    "repository-tree" => {RepositoryDiscoverer, :tree, 4},
    "repository-search" => {RepositoryDiscoverer, :search, 5},
    "repository-lines" => {RepositoryDiscoverer, :lines, 6}
  }

  @enforce_keys [:manifest_version, :operations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{manifest_version: pos_integer(), operations: [String.t()]}

  @doc "The current, and only ever, closed read-tool manifest."
  @spec current() :: t()
  def current, do: %__MODULE__{manifest_version: @manifest_version, operations: @operation_names}

  @spec manifest_version() :: pos_integer()
  def manifest_version, do: @manifest_version

  @doc "The closed set of allowed read-tool operation names."
  @spec operation_names() :: [String.t()]
  def operation_names, do: @operation_names

  @doc """
  The exact `{module, function, arity}` each allowed operation name
  dispatches to.

  Informational and audit-only. Task 6 gates which name may run; the bound
  function's own project/participant/source-authority scoping and its own
  byte and result-count limits are unchanged and unreimplemented here.
  """
  @spec operation_bindings() :: %{String.t() => {module(), atom(), non_neg_integer()}}
  def operation_bindings, do: @operation_bindings

  @doc """
  Whether `operation_name` may run under `manifest` right now.

  Any name outside the closed set — including a name a runtime-injection
  attempt invents, requests, or extends, and any network-shaped operation
  name — refuses explicitly (`{:error, :tool_not_allowed}`) rather than
  being silently ignored or partially honored.
  """
  @spec authorize_operation(t(), term()) :: :ok | {:error, :tool_not_allowed}
  def authorize_operation(%__MODULE__{operations: operations}, operation_name)
      when is_binary(operation_name) do
    if operation_name in operations, do: :ok, else: {:error, :tool_not_allowed}
  end

  def authorize_operation(%__MODULE__{}, _operation_name), do: {:error, :tool_not_allowed}

  @doc "The stable digest of one manifest's disclosed shape."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = manifest) do
    terms = [Integer.to_string(manifest.manifest_version) | Enum.sort(manifest.operations)]

    terms
    |> Enum.map_join(fn term -> "#{byte_size(term)}:#{term}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
