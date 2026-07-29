defmodule SddOrchestrator.ReadinessGuidanceDouble do
  @moduledoc """
  A deterministic readiness-guidance adapter for tests.

  It records the projection it was handed and replays a scripted answer, so
  schema validation, classification, timeout, and failure behaviour can be
  proven without a model provider. The script and the recording live in the
  calling process, which keeps concurrent tests from seeing each other's
  requests.

  A `{:findings, list}` script is bound to the revision it was asked about, so
  the common case cannot accidentally pass or fail the revision-binding check.
  `{:response, value}` and `{:raw, term}` bypass that convenience to script the
  malformed answers a real provider can return.
  """
  @behaviour SddOrchestrator.Delivery.ReadinessGuidance

  alias SddOrchestrator.Delivery.ReadinessGuidance

  @script_key {__MODULE__, :script}
  @requested_key {__MODULE__, :requested}

  @doc "Installs this double as the configured adapter for one test."
  def install(script \\ {:findings, []}) do
    original = Application.get_env(:sdd_orchestrator, :readiness_guidance)
    Application.put_env(:sdd_orchestrator, :readiness_guidance, __MODULE__)
    Process.put(@script_key, script)
    Process.put(@requested_key, [])

    fn -> restore(original) end
  end

  @doc "Changes the scripted answer for later requests."
  def script(script), do: Process.put(@script_key, script)

  @doc "The projections handed to the adapter, oldest first."
  def requested, do: Process.get(@requested_key, []) |> Enum.reverse()

  @doc "One schema-valid finding with overridable fields."
  def finding(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "missing-success-measure",
        "category" => "missing",
        "blocking" => true,
        "summary" => "No success measure is described.",
        "explanation" => "Say how you will know this feature worked once it is live."
      },
      attrs
    )
  end

  @doc "One schema-valid response envelope bound to the given revision."
  def response(revision_id, findings) do
    %{
      "response_version" => ReadinessGuidance.response_version(),
      "revision_id" => revision_id,
      "findings" => findings
    }
  end

  @impl true
  def assess(input) do
    Process.put(@requested_key, [input | Process.get(@requested_key, [])])

    case Process.get(@script_key, {:findings, []}) do
      {:findings, findings} -> {:ok, response(input["revision_id"], findings)}
      {:response, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      {:raw, term} -> term
    end
  end

  # An unset key must fall back to the configured default rather than to `nil`,
  # which `Application.get_env/3` would return for an explicitly stored `nil`.
  defp restore(nil), do: Application.delete_env(:sdd_orchestrator, :readiness_guidance)

  defp restore(original),
    do: Application.put_env(:sdd_orchestrator, :readiness_guidance, original)
end
