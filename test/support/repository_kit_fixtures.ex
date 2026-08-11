defmodule SddOrchestrator.RepositoryKitFixtures do
  @moduledoc """
  Test fixtures for immutable, globally catalogued SDD kit packages.
  """

  alias SddOrchestrator.RepositoryKits

  @doc "Builds one valid `RepositoryKits.publish_package/2` attrs map."
  def valid_publish_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        source: "https://github.com/example/sdd-kit",
        publisher: "example-org",
        version: "1.0.0",
        license: "MIT",
        provenance: %{
          ref_type: "commit",
          ref: String.duplicate("a", 40),
          repository: "example/sdd-kit"
        },
        supported_adapters: ["claude_code"],
        required_permissions: ["repository:read"],
        scripts: ["scripts/check.sh"]
      },
      overrides
    )
  end

  @doc "Builds one small in-memory file list, including an executable script."
  def valid_files(overrides \\ [])

  def valid_files([]) do
    [
      %{path: "SKILL.md", content: "# skill\n", executable: false},
      %{path: "scripts/check.sh", content: "#!/bin/sh\necho ok\n", executable: true},
      %{path: "templates/empty.md", content: "", executable: false}
    ]
  end

  def valid_files(files), do: files

  @doc "Publishes one immutable package through the public boundary; raises on error."
  def publish_package_fixture(attrs_overrides \\ %{}, file_overrides \\ []) do
    attrs = valid_publish_attrs(attrs_overrides)
    files = valid_files(file_overrides)

    case RepositoryKits.publish_package(attrs, files) do
      {:ok, package} -> package
      {:error, reason} -> raise "failed to publish fixture package: #{inspect(reason)}"
    end
  end
end
