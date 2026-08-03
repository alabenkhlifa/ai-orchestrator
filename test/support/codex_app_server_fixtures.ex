defmodule SddOrchestrator.CodexAppServerFixtures do
  @moduledoc false

  alias SddOrchestrator.AIRuntime.CodexAppServer
  alias SddOrchestrator.CodexAppServerProcessDouble

  @codex_version "codex-cli 0.test.8"
  @schema_digest String.duplicate("8", 64)

  def codex_version, do: @codex_version
  def schema_digest, do: @schema_digest
  def compatibility_registry, do: %{@codex_version => [@schema_digest]}

  def start_adapter(test_pid, opts \\ []) do
    defaults = [
      codex_version: @codex_version,
      schema_digest: @schema_digest,
      compatibility_registry: compatibility_registry(),
      process_module: CodexAppServerProcessDouble,
      process_options: [test_pid: test_pid],
      notification_target: test_pid,
      initialization_timeout_ms: 500,
      timeout_ms: 500,
      restart_delay_ms: 0
    ]

    CodexAppServer.start_link(Keyword.merge(defaults, opts))
  end

  def receive_handshake do
    process =
      receive do
        {CodexAppServerProcessDouble, :started, process} -> process
      after
        500 -> raise "Codex process double did not start"
      end

    initialize = receive_write(process, "initialize")
    initialized = receive_write(process, "initialized")

    %{process: process, initialize: initialize, initialized: initialized}
  end

  def receive_write(process, method \\ nil) do
    receive do
      {CodexAppServerProcessDouble, :write, ^process, %{"method" => actual} = frame}
      when is_nil(method) or actual == method ->
        frame
    after
      500 -> raise "Codex process double did not receive #{inspect(method)}"
    end
  end
end
