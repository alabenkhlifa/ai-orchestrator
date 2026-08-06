defmodule SddOrchestrator.Worker.State do
  @moduledoc """
  Holds the worker's loaded `SddOrchestrator.Worker.Configuration` in memory
  for the rest of the worker runtime to read.

  Deliberately minimal for this task: a single in-memory read of the
  configuration that was already validated and loaded before
  `SddOrchestrator.Worker.Supervisor` started this child. Later tasks add the
  gateway client and command router as sibling children under that same
  supervisor.

  Started unnamed (no fixed process name) so more than one worker
  supervision tree can run in the same VM without colliding — which matters
  for this task's own test suite and keeps the module free of any singleton
  assumption a real worker process would not need either. Callers reach it
  through the owning `SddOrchestrator.Worker.Supervisor` pid, e.g. via
  `SddOrchestrator.Worker.Supervisor.configuration/1`.
  """

  use Agent

  alias SddOrchestrator.Worker.Configuration

  @spec start_link(Configuration.t()) :: Agent.on_start()
  def start_link(%Configuration{} = config) do
    Agent.start_link(fn -> config end)
  end

  @doc "Returns the configuration held by a running `SddOrchestrator.Worker.State` process."
  @spec current(pid()) :: Configuration.t()
  def current(state_pid) when is_pid(state_pid) do
    Agent.get(state_pid, & &1)
  end
end
