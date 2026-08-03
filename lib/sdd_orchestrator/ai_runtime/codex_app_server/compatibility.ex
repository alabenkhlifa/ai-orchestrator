defmodule SddOrchestrator.AIRuntime.CodexAppServer.Compatibility do
  @moduledoc """
  Fail-closed compatibility registry for the worker-local Codex App Server.

  A generated schema belongs to exactly one installed Codex version. The
  adapter therefore accepts only an explicitly registered `{version, digest}`
  pair. Production registrations are deployment evidence and intentionally do
  not live in this module.
  """

  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @type registry :: %{optional(String.t()) => [String.t()]}

  @spec verify(String.t(), String.t(), registry()) ::
          :ok | {:error, :unsupported_version | :unsupported_schema_digest}
  def verify(version, schema_digest, registry)
      when is_binary(version) and is_binary(schema_digest) and is_map(registry) do
    case Map.fetch(registry, version) do
      :error ->
        {:error, :unsupported_version}

      {:ok, digests} when is_list(digests) ->
        normalized = String.downcase(schema_digest)

        if Regex.match?(@digest_pattern, normalized) and normalized in digests do
          :ok
        else
          {:error, :unsupported_schema_digest}
        end

      {:ok, _invalid_entry} ->
        {:error, :unsupported_schema_digest}
    end
  end

  def verify(_version, _schema_digest, _registry), do: {:error, :unsupported_version}
end
