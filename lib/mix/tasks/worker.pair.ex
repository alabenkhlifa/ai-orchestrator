defmodule Mix.Tasks.Worker.Pair do
  @moduledoc """
  Completes a dashboard-issued pairing code and stores the worker's local
  configuration and credential.

      mix worker.pair --code <code> --control-plane <address> \\
        --agent claude_code --agent-executable <path> --workspace-root <path> \\
        [--home <dir>]

  Options:

    * `--code` (required) — the pairing code issued by the dashboard.
    * `--control-plane` (required) — the control-plane address, stored as-is.
    * `--agent` (required) — `claude_code` or `codex`.
    * `--agent-executable` (required) — the agent's executable path or command.
    * `--workspace-root` (required) — the local path the agent runs against.
    * `--home` (optional) — overrides the worker-local storage root.

  Starts the full application (including the database) because pairing
  completion is an authoritative control-plane operation
  (`SddOrchestrator.Devices.Pairing.complete_pairing/2`): for this
  developer-run local form factor, this same repository checkout is both the
  control plane's database and the pairing worker. The issued credential is
  never printed — it is written only to the owner-only worker configuration
  file.
  """

  use Mix.Task

  alias SddOrchestrator.Devices.{Pairing, WorkerDiscovery}
  alias SddOrchestrator.Worker.Configuration

  @shortdoc "Completes worker pairing and stores the local worker configuration"

  @switches [
    code: :string,
    control_plane: :string,
    agent: :string,
    agent_executable: :string,
    workspace_root: :string,
    home: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    code = required!(opts, :code)
    control_plane = required!(opts, :control_plane)
    agent = required!(opts, :agent)
    agent_executable = required!(opts, :agent_executable)
    workspace_root = required!(opts, :workspace_root)
    home = Keyword.get(opts, :home)

    unless agent in Configuration.agent_adapters() do
      Mix.raise(
        "invalid --agent #{inspect(agent)}: must be one of " <>
          Enum.join(Configuration.agent_adapters(), ", ")
      )
    end

    Mix.Task.run("app.start")

    case Pairing.complete_pairing(code, worker_attrs()) do
      {:ok, pairing_result} ->
        config =
          Configuration.from_pairing(pairing_result, %{
            control_plane_address: control_plane,
            agent_adapter: agent,
            agent_executable: agent_executable,
            workspace_root: workspace_root
          })

        :ok = Configuration.store(config, home)

        Mix.shell().info(confirmation(pairing_result))

      {:error, reason} ->
        Mix.raise("pairing failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec confirmation(map()) :: String.t()
  def confirmation(%{worker: worker}) do
    "Paired worker #{worker.id} for device workspace #{worker.device_workspace_id}. " <>
      "Configuration stored locally."
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("missing required --#{dasherize(key)} option")
      value -> value
    end
  end

  defp dasherize(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  defp worker_attrs do
    policy = WorkerDiscovery.compatibility_policy()

    %{
      os_family: policy.os_family,
      os_major: List.last(policy.os_majors),
      protocol_version: List.first(policy.protocol_versions),
      app_version: to_string(Mix.Project.config()[:version])
    }
  end
end
