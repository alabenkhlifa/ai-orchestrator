defmodule SddOrchestrator.ProjectAssistant.RepositoryExclusions do
  @moduledoc """
  Configured path and file exclusions Task 5 owns.

  This is the narrower, adapter-level half of AC-19: "denied files and
  unauthorized content are excluded" before discovery or read ever runs.
  Content-level credential and secret *redaction* of what already crossed
  the boundary is Task 9's `AssistantProcessingRecord` lifecycle, not this
  module's job — this module keeps a configured set of generated and
  sensitive paths from ever being listed, matched, or read in the first
  place.

  The default list covers the two fixture classes AC-13 and this task's
  proof line name directly: generated or vendored trees that would otherwise
  dominate a bounded discovery budget (`node_modules/`, build output), and
  paths that conventionally hold credentials (`.env`, private keys, an SSH
  directory) that must never reach the model or a citation at all.
  """

  @default_exclusions [
    ".git/",
    "node_modules/",
    "_build/",
    "deps/",
    "dist/",
    "build/",
    ".terraform/",
    "vendor/",
    "coverage/",
    ".env",
    ".env.*",
    "*.pem",
    "*.key",
    "id_rsa*",
    "id_ed25519*",
    ".ssh/",
    "secrets/",
    "credentials.yml",
    "credentials.json"
  ]

  @doc "The configured exclusion patterns, falling back to the built-in default set."
  @spec configured() :: [String.t()]
  def configured do
    Application.get_env(:sdd_orchestrator, :repository_discovery_exclusions, @default_exclusions)
  end

  @doc """
  Whether `path` matches any exclusion pattern.

  A pattern ending in `/` matches a directory anywhere in the path. A
  pattern containing `*` matches the path's basename as a glob. Any other
  pattern matches the exact basename or the exact full path.
  """
  @spec denied?(String.t(), [String.t()]) :: boolean()
  def denied?(path, exclusions \\ configured()) do
    Enum.any?(exclusions, &pattern_match?(&1, path))
  end

  @doc "Filters `paths` down to the ones not denied by `exclusions`."
  @spec reject_denied([String.t()], [String.t()]) :: [String.t()]
  def reject_denied(paths, exclusions \\ configured()) do
    Enum.reject(paths, &denied?(&1, exclusions))
  end

  defp pattern_match?(pattern, path) do
    cond do
      String.ends_with?(pattern, "/") -> directory_match?(pattern, path)
      String.contains?(pattern, "*") -> glob_match?(pattern, Path.basename(path))
      true -> path == pattern or Path.basename(path) == pattern
    end
  end

  defp directory_match?(pattern, path) do
    segment = String.trim_trailing(pattern, "/")
    parts = Path.split(path)
    segment in parts
  end

  defp glob_match?(pattern, basename) do
    regex_source =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")

    Regex.match?(~r/^#{regex_source}$/, basename)
  end
end
