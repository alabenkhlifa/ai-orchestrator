defmodule SddOrchestrator.CodexCliFixture do
  @moduledoc """
  Writes a deterministic, executable stand-in for the `codex` CLI: a shell
  script that answers `--version` with a scripted string and, for any other
  invocation, prints scripted `--json` lines to stdout and exits with a
  scripted status.

  This is the "recorded-output double" `tasks.md` asks for at the level this
  task actually composes at, mirroring
  `SddOrchestrator.ClaudeCodeCliFixture` — a real subprocess and a real
  `Port`, not a swapped Elixir module.
  """

  @doc "Writes a script that prints `lines` (plain maps, JSON-encoded here) and exits with `exit_status`."
  @spec streaming_script([map()], keyword()) :: String.t()
  def streaming_script(lines, opts \\ []) do
    exit_status = Keyword.get(opts, :exit_status, 0)
    version_output = Keyword.get(opts, :version_output, "codex-cli 9.9.9")

    body =
      if lines == [] do
        ""
      else
        encoded = Enum.map_join(lines, "\n", &Jason.encode!/1)

        """
        cat <<'SDD_FIXTURE_EOF'
        #{encoded}
        SDD_FIXTURE_EOF
        """
      end

    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "#{version_output}"
      exit 0
    fi
    #{body}exit #{exit_status}
    """)
  end

  @doc "Writes a script whose only job is to answer `--version` with `output` and exit `exit_status`."
  @spec version_only_script(String.t(), keyword()) :: String.t()
  def version_only_script(output, opts \\ []) do
    exit_status = Keyword.get(opts, :exit_status, 0)

    write!("""
    #!/bin/sh
    echo "#{output}"
    exit #{exit_status}
    """)
  end

  @doc """
  Writes a script that reports whether `leak_var` and `keep_var` are set in
  its own environment as a single `agent_message` item, then a successful
  turn — proving the adapter's environment translation reaches the real
  subprocess rather than the worker's own environment.
  """
  @spec environment_probe_script(String.t(), String.t()) :: String.t()
  def environment_probe_script(leak_var, keep_var) do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "codex-cli 9.9.9"
      exit 0
    fi
    leak="absent"
    if [ -n "$#{leak_var}" ]; then leak="present"; fi
    keep="absent"
    if [ -n "$#{keep_var}" ]; then keep="present"; fi
    echo "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"thr_env_probe\\"}"
    echo "{\\"type\\":\\"item.completed\\",\\"item\\":{\\"id\\":\\"item_0\\",\\"type\\":\\"agent_message\\",\\"text\\":\\"leak=$leak keep=$keep\\"}}"
    echo "{\\"type\\":\\"turn.completed\\",\\"usage\\":{}}"
    exit 0
    """)
  end

  @doc "Writes a script that reports its own working directory as an agent_message item."
  @spec cwd_probe_script() :: String.t()
  def cwd_probe_script do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "codex-cli 9.9.9"
      exit 0
    fi
    dir="$(pwd)"
    echo "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"thr_cwd_probe\\"}"
    echo "{\\"type\\":\\"item.completed\\",\\"item\\":{\\"id\\":\\"item_0\\",\\"type\\":\\"agent_message\\",\\"text\\":\\"cwd=$dir\\"}}"
    echo "{\\"type\\":\\"turn.completed\\",\\"usage\\":{}}"
    exit 0
    """)
  end

  @doc """
  Writes a script that hangs reading stdin unless it is actually closed —
  the same failure mode the real `codex exec` has when a caller does not
  redirect its stdin, used to prove `Codex.Session` avoids it.
  """
  @spec stdin_sensitive_script() :: String.t()
  def stdin_sensitive_script do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "codex-cli 9.9.9"
      exit 0
    fi
    read _line
    echo "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"thr_stdin_sensitive\\"}"
    echo "{\\"type\\":\\"turn.completed\\",\\"usage\\":{}}"
    exit 0
    """)
  end

  @doc """
  Writes a script that starts a real thread (emitting `thread.started`
  immediately, so `start/4` returns without waiting out the launch timeout),
  records its own OS pid to `pid_file` via `exec sleep`, then sits there —
  never emitting a completed turn, never exiting on its own. `exec` replaces
  the script's own process image rather than forking, so the pid written to
  `pid_file` is the same one that keeps running for as long as the sleep
  lasts, letting a test observe it as alive and stop the session before it
  would ever produce output on its own.
  """
  @spec long_running_script(String.t()) :: String.t()
  def long_running_script(pid_file) do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "codex-cli 9.9.9"
      exit 0
    fi
    echo "$$" > "#{pid_file}"
    echo "{\\"type\\":\\"thread.started\\",\\"thread_id\\":\\"thr_long_running\\"}"
    exec sleep 20
    """)
  end

  defp write!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "codex-fixture-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end
end
