defmodule SddOrchestrator.RepositoryInitialization.Eligibility do
  @moduledoc """
  Classifies a user-selected local path for empty-repository initialization
  (AC-01), layered on top of `SddOrchestrator.Devices.RepositoryValidation`
  rather than reimplementing repository classification.

  `RepositoryValidation.root_commit_ids/1` already distinguishes a mature
  repository (has root commits) from an unborn one (a `.git` directory with
  zero commits), but collapses both "no `.git` at all" cases — a genuinely
  empty directory and a directory holding stray non-Git files — into the same
  `:not_a_git_repository` value. That value alone is not enough to decide
  eligibility here, so this module adds one more check, `File.ls/1`, only for
  that case.
  """

  alias SddOrchestrator.Devices.RepositoryValidation

  @type ok :: :empty_directory | :unborn_repository
  @type error :: :mature_repository | :non_empty_directory | :inaccessible

  @doc """
  Classifies `path` as eligible (`{:ok, :empty_directory | :unborn_repository}`)
  or not (`{:error, reason}`).

  A repository with any root commit routes to mature-repository handling
  (`:mature_repository`) — out of scope for this slice, so the caller simply
  stops with a clear message. A non-empty, non-Git directory
  (`:non_empty_directory`) is explicitly out of scope: initializing over
  existing files would mean importing existing source, which this slice does
  not do.
  """
  @spec classify(Path.t()) :: {:ok, ok()} | {:error, error()}
  def classify(path) do
    case RepositoryValidation.root_commit_ids(path) do
      {:ok, _roots} -> {:error, :mature_repository}
      {:error, :empty_repository} -> {:ok, :unborn_repository}
      {:error, :not_a_git_repository} -> classify_non_git(path)
      {:error, :inaccessible} -> {:error, :inaccessible}
    end
  end

  defp classify_non_git(path) do
    case File.ls(path) do
      {:ok, []} -> {:ok, :empty_directory}
      {:ok, [_ | _]} -> {:error, :non_empty_directory}
      {:error, _posix} -> {:error, :inaccessible}
    end
  end
end
