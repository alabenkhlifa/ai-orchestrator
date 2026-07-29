defmodule SddOrchestrator.ArtifactStoreDouble do
  @moduledoc """
  A deterministic private-artifact adapter for tests.

  It records what it was asked to store and replays a scripted answer, so a
  caller that has to survive an unavailable or refusing artifact store can be
  proven without PostgreSQL or a device worker. The script and the recording
  live in the calling process, which keeps concurrent tests from seeing each
  other's requests.

  The default script stores in the process dictionary and answers with the same
  reference the real adapters would return, so a test only scripts a failure
  when the failure is the thing under test.
  """
  @behaviour SddOrchestrator.Delivery.ArtifactStore

  alias SddOrchestrator.Delivery.ArtifactStore
  alias SddOrchestrator.Delivery.ArtifactStore.Artifact

  @script_key {__MODULE__, :script}
  @stored_key {__MODULE__, :stored}
  @requested_key {__MODULE__, :requested}

  @doc "Installs this double as the configured artifact store for one test."
  def install(script \\ :store) do
    original = Application.get_env(:sdd_orchestrator, :artifact_store)
    Application.put_env(:sdd_orchestrator, :artifact_store, __MODULE__)
    Process.put(@script_key, script)
    Process.put(@stored_key, %{})
    Process.put(@requested_key, [])

    fn -> restore(original) end
  end

  @doc "Changes the scripted answer for later requests."
  def script(script), do: Process.put(@script_key, script)

  @doc "The artifacts handed to the adapter, oldest first."
  def requested, do: @requested_key |> Process.get([]) |> Enum.reverse()

  @impl true
  def put(_authority, project_id, attrs) do
    Process.put(@requested_key, [{project_id, attrs} | Process.get(@requested_key, [])])

    case Process.get(@script_key, :store) do
      :store -> store(project_id, attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch(_authority, project_id, ref) do
    case Map.fetch(stored(), {project_id, ref}) do
      {:ok, artifact} -> {:ok, artifact}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def stat(authority, project_id, ref) do
    case fetch(authority, project_id, ref) do
      {:ok, artifact} -> {:ok, %{artifact | content: nil}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def delete(_authority, project_id, ref) do
    Process.put(@stored_key, Map.delete(stored(), {project_id, ref}))
    :ok
  end

  @impl true
  def delete_project(_authority, project_id) do
    {removed, kept} =
      Enum.split_with(stored(), fn {{held, _ref}, _artifact} -> held == project_id end)

    Process.put(@stored_key, Map.new(kept))
    {:ok, length(removed)}
  end

  @impl true
  def list_refs(_authority, project_id) do
    stored()
    |> Enum.flat_map(fn
      {{^project_id, ref}, _artifact} -> [ref]
      _other -> []
    end)
    |> Enum.sort()
  end

  defp store(project_id, attrs) do
    ref = ArtifactStore.ref_for(attrs.digest)

    artifact = %Artifact{
      ref: ref,
      digest: attrs.digest,
      content_type: attrs.content_type,
      byte_size: attrs.byte_size,
      redacted: attrs.redacted,
      content: attrs.content
    }

    Process.put(@stored_key, Map.put(stored(), {project_id, ref}, artifact))
    {:ok, ref}
  end

  defp stored, do: Process.get(@stored_key, %{})

  # An unset key must fall back to the configured default rather than to `nil`,
  # which `Application.get_env/3` would return for an explicitly stored `nil`.
  defp restore(nil), do: Application.delete_env(:sdd_orchestrator, :artifact_store)

  defp restore(original),
    do: Application.put_env(:sdd_orchestrator, :artifact_store, original)
end
