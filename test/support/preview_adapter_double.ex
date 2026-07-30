defmodule SddOrchestrator.PreviewAdapterDouble do
  @moduledoc """
  A deterministic preview-provider adapter for tests.

  It records every request, status query, and cleanup command it was handed and
  replays a scripted answer, so authorization, idempotency, timeout, expiry,
  supersession, and cleanup can be proven without a preview provider. The script
  and the recording live in the calling process, which keeps concurrent tests
  from seeing each other's requests.

  Two things it deliberately does *not* do. It never invents a request the
  caller did not make, so `requested/0` returning `[]` is real proof that an
  unauthorized project reached no provider. And it never resolves a credential
  from the request, so a test can assert that the credential reference it was
  configured with never appears in anything that was stored.
  """
  @behaviour SddOrchestrator.Delivery.PreviewAdapter

  @script_key {__MODULE__, :script}
  @status_key {__MODULE__, :status_script}
  @cleanup_key {__MODULE__, :cleanup_script}
  @requested_key {__MODULE__, :requested}
  @queried_key {__MODULE__, :queried}
  @cleaned_key {__MODULE__, :cleaned}

  @doc """
  Installs this double as the configured preview adapter for one test.

  `projects` is the preconfigured per-project authorization: a project absent
  from it has no preview path at all, which is the case a test needs in order to
  prove that no request is made.
  """
  def install(opts \\ []) do
    original = Application.get_env(:sdd_orchestrator, :preview)

    Application.put_env(
      :sdd_orchestrator,
      :preview,
      adapter: __MODULE__,
      provider: Keyword.get(opts, :provider, "configured-preview"),
      credential_ref: Keyword.get(opts, :credential_ref, "vault://preview"),
      request_timeout_ms: Keyword.get(opts, :request_timeout_ms, 300_000),
      ttl_seconds: Keyword.get(opts, :ttl_seconds, 86_400),
      projects: Keyword.get(opts, :projects, %{})
    )

    Process.put(@script_key, Keyword.get(opts, :script, :pending))
    Process.put(@status_key, Keyword.get(opts, :status, :pending))
    Process.put(@cleanup_key, Keyword.get(opts, :cleanup, :ok))
    Process.put(@requested_key, [])
    Process.put(@queried_key, [])
    Process.put(@cleaned_key, [])

    fn -> restore(original) end
  end

  @doc "Removes the configured preview path entirely, adapter included."
  def uninstall do
    original = Application.get_env(:sdd_orchestrator, :preview)
    Application.delete_env(:sdd_orchestrator, :preview)

    fn -> restore(original) end
  end

  @doc "Changes the answer later deployment requests receive."
  def script(script), do: Process.put(@script_key, script)

  @doc "Changes the answer later status queries receive."
  def script_status(script), do: Process.put(@status_key, script)

  @doc "Changes the answer later cleanup commands receive."
  def script_cleanup(script), do: Process.put(@cleanup_key, script)

  @doc "The deployment requests handed to the adapter, oldest first."
  def requested, do: @requested_key |> Process.get([]) |> Enum.reverse()

  @doc "The status queries handed to the adapter, oldest first."
  def queried, do: @queried_key |> Process.get([]) |> Enum.reverse()

  @doc "The cleanup commands handed to the adapter, oldest first."
  def cleaned, do: @cleaned_key |> Process.get([]) |> Enum.reverse()

  @doc "One ready answer with a participant-safe link."
  def ready(opts \\ []) do
    {:ok,
     %{
       status: "ready",
       provider_ref: Keyword.get(opts, :provider_ref, "preview-provider/deployment-1"),
       link: Keyword.get(opts, :link, "https://preview.example.test/branch-1"),
       expires_at: Keyword.get(opts, :expires_at)
     }}
  end

  @impl true
  def request(request) do
    Process.put(@requested_key, [request | Process.get(@requested_key, [])])
    answer(Process.get(@script_key, :pending), request)
  end

  @impl true
  def status(query) do
    Process.put(@queried_key, [query | Process.get(@queried_key, [])])
    answer(Process.get(@status_key, :pending), query)
  end

  @impl true
  def cleanup(command) do
    Process.put(@cleaned_key, [command | Process.get(@cleaned_key, [])])

    case Process.get(@cleanup_key, :ok) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A scripted function sees the exact value the adapter was handed, which is
  # how a test proves the provider was asked about the binding it expected.
  defp answer(script, value) when is_function(script, 1), do: script.(value)

  defp answer(:pending, value) do
    {:ok, %{status: "pending", provider_ref: "preview-provider/" <> short(value), link: nil}}
  end

  defp answer(:ready, _value), do: ready()

  defp answer(:failed, _value),
    do: {:ok, %{status: "failed", provider_ref: nil, link: nil, failure_reason: :quota_exhausted}}

  defp answer(:expired, _value),
    do: {:ok, %{status: "expired", provider_ref: "preview-provider/gone", link: nil}}

  defp answer({:error, reason}, _value), do: {:error, reason}
  defp answer({:raw, term}, _value), do: term

  defp short(%{request_key: "preview:v1:" <> digest}), do: binary_part(digest, 0, 12)
  defp short(_value), do: "unkeyed"

  # An unset key must fall back to the configured default rather than to `nil`,
  # which `Application.get_env/3` would return for an explicitly stored `nil`.
  defp restore(nil), do: Application.delete_env(:sdd_orchestrator, :preview)
  defp restore(original), do: Application.put_env(:sdd_orchestrator, :preview, original)
end
