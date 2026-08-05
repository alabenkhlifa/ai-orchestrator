defmodule SddOrchestrator.RepositoryPilots.SelectableSpecification do
  @moduledoc """
  One current authoritative specification a pilot may reference.

  It carries the identity and revision the selection commits to, plus the title
  the owner needs to recognize it on screen. It deliberately carries no
  `requirements`, `design`, or `tasks` document: the specification store stays
  the only authority for specification content, and nothing here is persisted.
  """

  @enforce_keys [:id, :title, :revision_id]
  defstruct [:id, :title, :revision_id]

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          title: String.t(),
          revision_id: Ecto.UUID.t()
        }
end
