defmodule Mix.Tasks.RepositoryKits.Publish do
  @moduledoc """
  Reads a local directory of workflow files into memory and publishes it as
  one immutable SDD kit package in the global catalog.

      mix repository_kits.publish <source_dir> --source <origin> --publisher <name> \\
        --version <semver> --license <spdx> --repository <descriptor> --ref <commit-sha> \\
        --adapter <name> [--adapter <name> ...] [--permission <name> ...] [--script <path> ...]

  Options:

    * `--source` (required) — origin descriptor, e.g. a repository URL.
    * `--publisher` (required) — the publishing party's name.
    * `--version` (required) — a semantic version string.
    * `--license` (required) — an SPDX id or short license name.
    * `--repository` (required) — the provenance repository descriptor.
    * `--ref` (required) — the exact commit SHA the package was built from.
      A branch or tag name is rejected as a mutable reference.
    * `--adapter` (required, repeatable) — a supported agent adapter, one of
      `claude_code` or `codex`.
    * `--permission` (optional, repeatable) — a required tool permission.
    * `--script` (optional, repeatable) — a path (relative to `<source_dir>`)
      of a vendored executable script.

  Every regular file under `<source_dir>` is read into memory with its path
  relative to `<source_dir>` and its own POSIX execute bit. A symlink is
  never followed: the task prints an error and halts instead, because deep
  symlink-escape defense belongs to a later task, not to silent
  dereferencing here. No file content is ever executed.

  Starts the full application (including the database) because publication
  is an authoritative catalog write
  (`SddOrchestrator.RepositoryKits.publish_package/2`).
  """

  use Mix.Task

  import Bitwise, only: [band: 2]

  alias SddOrchestrator.RepositoryKits

  @shortdoc "Publishes one immutable SDD kit package from a local directory"

  @switches [
    source: :string,
    publisher: :string,
    version: :string,
    license: :string,
    repository: :string,
    ref: :string,
    adapter: :keep,
    permission: :keep,
    script: :keep
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, rest} = OptionParser.parse!(argv, strict: @switches)

    source_dir =
      case rest do
        [dir] -> dir
        _ -> Mix.raise("expected exactly one <source_dir> argument")
      end

    source = required!(opts, :source)
    publisher = required!(opts, :publisher)
    version = required!(opts, :version)
    license = required!(opts, :license)
    repository = required!(opts, :repository)
    ref = required!(opts, :ref)
    adapters = Keyword.get_values(opts, :adapter)
    permissions = Keyword.get_values(opts, :permission)
    scripts = Keyword.get_values(opts, :script)

    if adapters == [], do: Mix.raise("at least one --adapter is required")

    files = read_files!(source_dir)

    Mix.Task.run("app.start")

    attrs = %{
      source: source,
      publisher: publisher,
      version: version,
      license: license,
      provenance: %{ref_type: "commit", ref: ref, repository: repository},
      supported_adapters: adapters,
      required_permissions: permissions,
      scripts: scripts
    }

    case RepositoryKits.publish_package(attrs, files) do
      {:ok, package} ->
        Mix.shell().info("Published package #{package.id} (digest #{package.digest})")

      {:error, reason} ->
        Mix.shell().error("failed to publish package: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("missing required --#{dasherize(key)} option")
      value -> value
    end
  end

  defp dasherize(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp read_files!(source_dir) do
    unless File.dir?(source_dir) do
      Mix.raise("#{source_dir} is not a directory")
    end

    source_dir
    |> Path.expand()
    |> walk!("")
  end

  defp walk!(abs_dir, rel_prefix) do
    abs_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn entry ->
      abs_path = Path.join(abs_dir, entry)
      rel_path = if rel_prefix == "", do: entry, else: Path.join(rel_prefix, entry)

      case File.lstat!(abs_path) do
        %File.Stat{type: :symlink} ->
          Mix.raise("refusing to publish symlink #{rel_path}; remove it before publishing")

        %File.Stat{type: :directory} ->
          walk!(abs_path, rel_path)

        %File.Stat{type: :regular, mode: mode} ->
          [
            %{
              path: rel_path,
              content: File.read!(abs_path),
              executable: band(mode, 0o111) != 0
            }
          ]

        %File.Stat{type: other} ->
          Mix.raise("refusing to publish non-regular file #{rel_path} (#{other})")
      end
    end)
  end
end
