defmodule SddOrchestrator.ClaudeCodeCliFixture do
  @moduledoc """
  Writes a deterministic, executable stand-in for the `claude` CLI: a shell
  script that answers `--version` with a scripted string and, for any other
  invocation, prints scripted `stream-json` lines to stdout and exits with a
  scripted status.

  This is the "recorded-output double" `tasks.md` asks for at the level this
  task actually composes at: a real subprocess and a real `Port`, not a
  swapped Elixir module, since `SddOrchestrator.Delivery.AgentAdapter.ClaudeCode`
  itself owns exactly that subprocess boundary.
  """

  @doc "Writes a script that prints `lines` (plain maps, JSON-encoded here) and exits with `exit_status`."
  @spec streaming_script([map()], keyword()) :: String.t()
  def streaming_script(lines, opts \\ []) do
    exit_status = Keyword.get(opts, :exit_status, 0)
    version_output = Keyword.get(opts, :version_output, "9.9.9 (Claude Code)")

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
  its own environment as a single assistant progress line, then a successful
  result — proving the adapter's environment translation reaches the real
  subprocess rather than the worker's own environment.
  """
  @spec environment_probe_script(String.t(), String.t()) :: String.t()
  def environment_probe_script(leak_var, keep_var) do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    leak="absent"
    if [ -n "$#{leak_var}" ]; then leak="present"; fi
    keep="absent"
    if [ -n "$#{keep_var}" ]; then keep="present"; fi
    echo "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"thr_env_probe\\"}"
    echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"leak=$leak keep=$keep\\"}]}}"
    echo "{\\"type\\":\\"result\\",\\"is_error\\":false,\\"result\\":\\"done\\"}"
    exit 0
    """)
  end

  @doc "Writes a script that reports its own working directory as a progress line."
  @spec cwd_probe_script() :: String.t()
  def cwd_probe_script do
    write!("""
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "9.9.9 (Claude Code)"
      exit 0
    fi
    dir="$(pwd)"
    echo "{\\"type\\":\\"system\\",\\"subtype\\":\\"init\\",\\"session_id\\":\\"thr_cwd_probe\\"}"
    echo "{\\"type\\":\\"assistant\\",\\"message\\":{\\"content\\":[{\\"type\\":\\"text\\",\\"text\\":\\"cwd=$dir\\"}]}}"
    echo "{\\"type\\":\\"result\\",\\"is_error\\":false,\\"result\\":\\"done\\"}"
    exit 0
    """)
  end

  defp write!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "claude-code-fixture-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end
end
