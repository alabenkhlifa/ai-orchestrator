defmodule SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter.Worker do
  @moduledoc """
  The real `RepositoryMetadataAdapter`: a repository-metadata question asked of
  a Mac's worker, through `SddOrchestrator.RepositoryMetadata`.

  `prepare/1` and `revalidate/1` are the same call. Both ask a worker to read
  a repository's identity, normalized root, and current commit, and both need
  exactly one worker answer before `RepositoryAssessments` can move forward;
  nothing here has to tell the two apart. The request shape is already handled
  one layer down: a `RepositoryMetadataAdapter.request()` map is field-for-field
  the same as a `RepositoryMetadata.request()` map, so it is passed straight
  through with no translation. Whether a second read of the same repository
  needs its own panel, or the worker can just answer again, is a worker-side
  decision handled by `Worker.RepositoryMetadata` on the Mac, not by this
  module.

  This adapter's only job is narrowing `RepositoryMetadata.inspect/2`'s error
  union down to the two atoms `RepositoryAssessments.invoke/3` actually acts
  on: `:repository_mismatch`, which is kept because it is the one refusal a
  caller must be told about by name, and `:worker_unavailable`, which is what
  every other outcome (no worker, a lost attachment, a timeout, cancellation,
  or a malformed request) becomes. `RepositoryMetadata.inspect/2` already
  validates its own input, so an `:invalid_request` here would mean this
  adapter built a bad request, which is a defect in the caller, not something
  worth a distinct error atom.
  """
  @behaviour SddOrchestrator.RepositoryAssessments.RepositoryMetadataAdapter

  alias SddOrchestrator.RepositoryMetadata

  @impl true
  def prepare(request), do: inspect_repository(request)

  @impl true
  def revalidate(request), do: inspect_repository(request)

  defp inspect_repository(request) do
    case RepositoryMetadata.inspect(request) do
      {:ok, result} -> {:ok, result}
      {:error, :repository_mismatch} -> {:error, :repository_mismatch}
      {:error, _reason} -> {:error, :worker_unavailable}
    end
  end
end
