defmodule SddOrchestrator.Portability.PayloadPolicy do
  @moduledoc """
  Fail-closed allowlist and high-confidence secret filter for decrypted payloads.

  Only the approved project, canonical repository, and current specification
  fields may cross the package boundary. Values are data only and are never
  resolved as paths, URLs, templates, or commands.
  """

  alias SddOrchestrator.Portability.{PackageSection, ProjectPackage}

  @project_keys ~w(id name)
  @repository_keys ~w(provider repository_id)
  @specification_keys ~w(design id requirements tasks title)

  @secret_patterns [
    ~r/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
    ~r/\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}\b/,
    ~r/\bsk-[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    ~r/\bBearer\s+[A-Za-z0-9._~+\/=-]{12,}\b/i,
    ~r/\b(?:access|refresh|session|pairing)[_-]?token\s*[:=]\s*\S+/i,
    ~r/\b(?:password|passphrase|client_secret|api_key)\s*[:=]\s*\S+/i
  ]

  @spec validate(ProjectPackage.t()) :: :ok | {:error, atom()}
  def validate(%ProjectPackage{
        project: %PackageSection{content: project},
        repository: %PackageSection{content: repository},
        specifications: %PackageSection{content: specifications}
      }) do
    with :ok <- exact_map_keys(project, @project_keys),
         :ok <- exact_map_keys(repository, @repository_keys),
         :ok <- validate_specifications(specifications) do
      scan_values([project, repository, specifications])
    end
  end

  def validate(_package), do: {:error, :invalid_payload}

  @spec allowed_fields() :: %{atom() => [String.t()]}
  def allowed_fields do
    %{
      project: @project_keys,
      repository: @repository_keys,
      specification: @specification_keys
    }
  end

  defp validate_specifications(specifications) when is_list(specifications) do
    Enum.reduce_while(specifications, :ok, fn specification, :ok ->
      case exact_map_keys(specification, @specification_keys) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_specifications(_specifications), do: {:error, :invalid_payload}

  defp exact_map_keys(value, expected) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :forbidden_payload_field}
  end

  defp exact_map_keys(_value, _expected), do: {:error, :invalid_payload}

  defp scan_values(values) do
    values
    |> collect_strings([])
    |> Enum.find(&secret?/1)
    |> case do
      nil -> :ok
      _secret -> {:error, :secret_detected}
    end
  end

  defp collect_strings(value, acc) when is_binary(value), do: [value | acc]

  defp collect_strings(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {_key, child}, strings ->
      collect_strings(child, strings)
    end)
  end

  defp collect_strings(value, acc) when is_list(value) do
    Enum.reduce(value, acc, &collect_strings/2)
  end

  defp collect_strings(_value, acc), do: acc

  defp secret?(value), do: Enum.any?(@secret_patterns, &Regex.match?(&1, value))
end
