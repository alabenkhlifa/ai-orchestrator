defmodule SddOrchestrator.IdentityLinking.Preflight do
  @moduledoc """
  The non-mutating result of evaluating the combined project set of a merge
  before any commit.

  The existence of projects on both identities is normal history, not a conflict.
  Only two things block an atomic merge in this slice:

    * a case-insensitive project-name collision across the two workspaces, and
    * a canonical repository collision (same provider and provider repository id).

  `clear?` is true only when both conflict lists are empty. Any conflict aborts
  the entire merge without mutation; interactive recovery is deferred to a later
  slice.
  """

  @type name_conflict :: %{
          name_key: String.t(),
          surviving_project_id: binary(),
          absorbed_project_id: binary(),
          surviving_name: String.t(),
          absorbed_name: String.t()
        }

  @type repository_conflict :: %{
          provider: String.t(),
          provider_repository_id: integer(),
          surviving_project_id: binary(),
          absorbed_project_id: binary()
        }

  @type t :: %__MODULE__{
          name_conflicts: [name_conflict()],
          repository_conflicts: [repository_conflict()]
        }

  defstruct name_conflicts: [], repository_conflicts: []

  @doc "True when the combined set has no name or repository conflict."
  @spec clear?(t()) :: boolean()
  def clear?(%__MODULE__{name_conflicts: [], repository_conflicts: []}), do: true
  def clear?(%__MODULE__{}), do: false

  @doc "True when any conflict blocks the merge."
  @spec conflicted?(t()) :: boolean()
  def conflicted?(%__MODULE__{} = preflight), do: not clear?(preflight)
end
