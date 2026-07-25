defmodule SddOrchestrator.Privacy.DataProcessingRecord do
  @moduledoc """
  One approved processing activity in the Slice 01 processing inventory.

  Each record captures the specification-level purpose, lawful basis, personal-data
  fields, access boundary, retention, data-subject-rights behaviour, processors,
  transfers, and review status for an activity. These are the approved development
  data contract from `design.md` made machine-checkable; they are configuration and
  governance evidence, not personal data.
  """
  @enforce_keys [
    :activity,
    :purpose,
    :lawful_basis,
    :personal_data,
    :access,
    :retention,
    :rights,
    :processors,
    :transfers,
    :review
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          activity: atom(),
          purpose: String.t(),
          lawful_basis: :contract | :legitimate_interests,
          personal_data: [String.t()],
          access: String.t(),
          retention: String.t(),
          rights: String.t(),
          processors: [String.t()],
          transfers: String.t(),
          review: String.t()
        }

  @lawful_bases [:contract, :legitimate_interests]

  @doc "The lawful bases approved for this slice; no other basis is used."
  def lawful_bases, do: @lawful_bases
end
