defmodule SddOrchestrator.Delivery.ArtifactStore.Artifact do
  @moduledoc """
  One stored artifact as an authorized reader receives it.

  There is deliberately no URL, host, link, or expiry field here, and there is
  no room to add one by accident: a screenshot is private project data that
  reaches a reader only through an authorized fetch against the project's own
  storage authority. Nothing about an artifact is addressable from outside it.

  `stat/3` returns this same struct with `content` left `nil`, so presentation
  can show what an artifact is — its type, its size, whether it was redacted —
  without loading its bytes.
  """

  @enforce_keys [:ref, :digest, :content_type, :byte_size, :redacted]
  defstruct [:ref, :digest, :content_type, :byte_size, :redacted, :content]

  @type t :: %__MODULE__{
          ref: String.t(),
          digest: String.t(),
          content_type: String.t(),
          byte_size: non_neg_integer(),
          redacted: boolean(),
          content: binary() | nil
        }
end
