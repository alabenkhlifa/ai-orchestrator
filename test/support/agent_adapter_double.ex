defmodule SddOrchestrator.AgentAdapterDouble do
  @moduledoc """
  A deterministic coding agent for tests.

  It launches nothing. It replays a script — a reported protocol version, one
  start outcome, and a fixed event stream — and records every request the
  boundary handed it, so version refusal, thread resume, new-thread fallback,
  environment stripping, secret non-propagation, and event normalization are
  provable without a real agent, a subprocess, or a network.

  The script and the recording live in the calling process, which keeps
  concurrent tests from seeing each other's launches.
  """
  @behaviour SddOrchestrator.Delivery.AgentAdapter

  @script_key {__MODULE__, :script}
  @requests_key {__MODULE__, :requests}

  @thread_ref "thr_01HZX0000000000000000010"
  @occurred_at "2026-07-29T09:15:30Z"

  @default_script %{
    version: {:ok, "1.4.0"},
    start: :succeed,
    thread_ref: @thread_ref,
    observe: :succeed,
    events: []
  }

  @doc """
  Installs this double as the configured adapter for one test.

  Returns the function that puts the previous configuration back.
  """
  def install(overrides \\ %{}) do
    original = Application.fetch_env(:sdd_orchestrator, :agent_adapter)
    Application.put_env(:sdd_orchestrator, :agent_adapter, __MODULE__)
    Process.put(@requests_key, [])
    script(overrides)

    fn ->
      case original do
        {:ok, value} -> Application.put_env(:sdd_orchestrator, :agent_adapter, value)
        :error -> Application.delete_env(:sdd_orchestrator, :agent_adapter)
      end
    end
  end

  @doc """
  Rewrites the script.

  `:start` accepts `:succeed`, `:refuse_resume`, `:fail`, `:unavailable`,
  `:claim_resume` for an adapter asserting a resume nobody offered, and
  `:malformed_handle` for one returning a handle the boundary cannot read.
  `:observe` accepts `:succeed`, `:exit`, and `:unavailable`.
  """
  def script(overrides) do
    Process.put(@script_key, Map.merge(@default_script, Map.new(overrides)))
  end

  @doc "The start requests this double received, oldest first."
  def requests, do: @requests_key |> Process.get([]) |> Enum.reverse()

  @doc "The provider thread this double hands back when it starts a new one."
  def thread_ref, do: @thread_ref

  def occurred_at, do: @occurred_at

  @doc "One well-formed agent progress event."
  def progress_event(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "progress",
        "occurred_at" => @occurred_at,
        "payload" => %{"summary" => "Edited lib/sdd_orchestrator/delivery/feature.ex"}
      },
      Map.new(overrides)
    )
  end

  @doc "An event carrying raw credential material the boundary must not forward."
  def secret_event do
    progress_event(%{
      "payload" => %{
        "summary" => "Authenticated with the provider",
        "api_key" => "ghp_thisisnotarealtokenatall"
      }
    })
  end

  @doc "An event with no recognizable type at all."
  def malformed_event, do: %{"kind" => "progress", "text" => "something happened"}

  @doc "An event whose timestamp is not a protocol timestamp."
  def untimed_event, do: progress_event(%{"occurred_at" => "yesterday"})

  @doc "An event type only the worker or the check runner may emit."
  def usurping_event(event_type), do: progress_event(%{"type" => event_type})

  @impl true
  def installed_version, do: state().version

  @impl true
  def start(input) do
    Process.put(@requests_key, [input | Process.get(@requests_key, [])])

    started(state().start, input)
  end

  @impl true
  def observe(_handle) do
    case state().observe do
      :succeed -> {:ok, state().events}
      :exit -> {:error, :agent_exited}
      :unavailable -> {:error, :agent_unavailable}
    end
  end

  defp state, do: Process.get(@script_key, @default_script)

  defp started(:succeed, input), do: {:ok, handle(input)}
  defp started(:refuse_resume, %{thread_ref: nil} = input), do: {:ok, handle(input)}
  defp started(:refuse_resume, _input), do: {:error, :thread_expired}
  defp started(:fail, _input), do: {:error, :agent_launch_failed}
  defp started(:unavailable, _input), do: {:error, :agent_unavailable}
  defp started(:malformed_handle, _input), do: {:ok, %{pid: self()}}

  defp started(:claim_resume, _input) do
    {:ok, %{reference: make_ref(), thread_ref: state().thread_ref, resumed?: true}}
  end

  defp handle(%{thread_ref: thread_ref}) do
    %{
      reference: make_ref(),
      thread_ref: thread_ref || state().thread_ref,
      resumed?: not is_nil(thread_ref)
    }
  end
end
