defmodule Mix.Tasks.Worker.Start do
  @moduledoc """
  Starts the local worker's own supervision tree.

      mix worker.start [--home <dir>]

  Run this after `mix worker.pair` has already completed once. The pairing
  code itself comes from the project's device setup screen in the
  dashboard — a project owner generates a single-use code there for the
  device workspace that holds the repository. On the machine that holds the
  repository, the operator runs `mix worker.pair` once to complete that code
  and store the worker's credential and configuration (see `mix help
  worker.pair` for its flags), then runs `mix worker.start` every time
  afterward to bring the worker online. Once this task joins the control
  plane, the project shows the worker as reachable and a participant can
  start development on a ready feature.

  This starts only `SddOrchestrator.Worker.Supervisor` and its own
  dependencies — never the control-plane application. A genuinely remote
  worker has no database repo, no `SddOrchestratorWeb.Endpoint`, and no
  other control-plane process, so this task must not start them either.

  Refuses to start with a clear, actionable message when no worker
  configuration has been paired yet, or when the stored configuration is
  invalid — run `mix worker.pair` first (or again) in that case.
  """

  use Mix.Task

  alias SddOrchestrator.Worker.Supervisor, as: WorkerSupervisor

  @shortdoc "Starts the local worker runtime"

  @switches [home: :string]

  @impl Mix.Task
  def run(argv) do
    {:ok, _pid} = start(argv)
    Mix.shell().info("Worker started.")
    Process.sleep(:infinity)
  end

  @doc false
  @spec start([String.t()]) :: {:ok, pid()}
  def start(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)
    home = Keyword.get(opts, :home)

    {:ok, _} = Application.ensure_all_started(:jason)

    case WorkerSupervisor.start_link(home: home) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_paired} ->
        Mix.raise("no worker configuration found — run `mix worker.pair` first")

      {:error, {:invalid_configuration, reason}} ->
        Mix.raise(
          "worker configuration is invalid (#{inspect(reason)}) — run `mix worker.pair` again"
        )

      {:error, reason} ->
        Mix.raise("worker failed to start: #{inspect(reason)}")
    end
  end
end
