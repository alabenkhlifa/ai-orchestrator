defmodule SddOrchestrator.RepositoryAssessments.RepositoryBindingPreparation do
  @moduledoc """
  A short-lived worker-verified repository binding prepared before assessment.

  The value is deliberately self-contained and content-free. It names only the
  project and canonical repository, one normalized repository-relative root,
  the current full commit, the contracts the owner confirmed, and opaque
  replay-control metadata. It is never a repository path or a durable record.
  """

  @max_ttl_seconds 5 * 60
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @commit_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  @fields [
    :project_id,
    :repository_provider,
    :repository_id,
    :root,
    :commit,
    :scanner_contract_digest,
    :disclosure_digest,
    :worker_ref,
    :nonce,
    :issued_at,
    :expires_at
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          repository_provider: String.t(),
          repository_id: String.t(),
          root: String.t(),
          commit: String.t(),
          scanner_contract_digest: String.t(),
          disclosure_digest: String.t(),
          worker_ref: Ecto.UUID.t(),
          nonce: Ecto.UUID.t(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec new(map()) :: {:ok, t()} | {:error, :invalid_preparation}
  def new(attrs) when is_map(attrs) do
    with true <- MapSet.new(Map.keys(attrs)) == MapSet.new(@fields),
         {:ok, project_id} <- uuid(attrs.project_id),
         {:ok, provider} <- identifier(attrs.repository_provider),
         {:ok, repository_id} <- identifier(attrs.repository_id),
         {:ok, root} <- normalize_root(attrs.root),
         {:ok, commit} <- full_commit(attrs.commit),
         {:ok, scanner_digest} <- digest(attrs.scanner_contract_digest),
         {:ok, disclosure_digest} <- digest(attrs.disclosure_digest),
         {:ok, worker_ref} <- uuid(attrs.worker_ref),
         {:ok, nonce} <- uuid(attrs.nonce),
         {:ok, issued_at} <- timestamp(attrs.issued_at),
         {:ok, expires_at} <- timestamp(attrs.expires_at),
         :ok <- valid_window(issued_at, expires_at) do
      {:ok,
       %__MODULE__{
         project_id: project_id,
         repository_provider: provider,
         repository_id: repository_id,
         root: root,
         commit: commit,
         scanner_contract_digest: scanner_digest,
         disclosure_digest: disclosure_digest,
         worker_ref: worker_ref,
         nonce: nonce,
         issued_at: issued_at,
         expires_at: expires_at
       }}
    else
      _invalid -> {:error, :invalid_preparation}
    end
  end

  def new(_attrs), do: {:error, :invalid_preparation}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = preparation) do
    case new(Map.from_struct(preparation)) do
      {:ok, ^preparation} -> true
      _invalid -> false
    end
  end

  def valid?(_preparation), do: false

  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: expires_at}, %DateTime{} = now),
    do: DateTime.compare(now, expires_at) != :lt

  @spec fingerprint(t()) :: binary()
  def fingerprint(%__MODULE__{} = preparation) do
    preparation
    |> Map.from_struct()
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @spec normalize_root(term()) :: {:ok, String.t()} | {:error, :invalid_root}
  def normalize_root(root) when is_binary(root) do
    trimmed = String.trim(root)

    cond do
      trimmed in ["", ".", "./"] ->
        {:ok, "."}

      Path.type(trimmed) != :relative ->
        {:error, :invalid_root}

      String.contains?(trimmed, ["\\", <<0>>]) ->
        {:error, :invalid_root}

      String.match?(trimmed, ~r/[\x00-\x1f\x7f]/u) ->
        {:error, :invalid_root}

      true ->
        segments = Path.split(trimmed)

        if Enum.any?(segments, &(&1 == "..")) do
          {:error, :invalid_root}
        else
          normalized =
            case Enum.reject(segments, &(&1 == ".")) do
              [] -> ""
              safe_segments -> Path.join(safe_segments)
            end

          {:ok, if(normalized == "", do: ".", else: normalized)}
        end
    end
  end

  def normalize_root(_root), do: {:error, :invalid_root}

  @spec full_commit(term()) :: {:ok, String.t()} | {:error, :invalid_commit}
  def full_commit(commit) when is_binary(commit) do
    normalized = String.downcase(commit)

    if Regex.match?(@commit_pattern, normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_commit}
  end

  def full_commit(_commit), do: {:error, :invalid_commit}

  @spec digest(term()) :: {:ok, String.t()} | {:error, :invalid_digest}
  def digest(value) when is_binary(value) do
    normalized = String.downcase(value)

    if Regex.match?(@digest_pattern, normalized),
      do: {:ok, normalized},
      else: {:error, :invalid_digest}
  end

  def digest(_value), do: {:error, :invalid_digest}

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp uuid(_value), do: :error

  defp identifier(value) when is_integer(value) and value >= 0,
    do: {:ok, Integer.to_string(value)}

  defp identifier(value) when is_binary(value) do
    normalized = String.trim(value)

    if byte_size(normalized) <= 255 and
         Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]*\z/, normalized),
       do: {:ok, normalized},
       else: :error
  end

  defp identifier(_value), do: :error

  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.truncate(value, :second)}
  defp timestamp(_value), do: :error

  defp valid_window(issued_at, expires_at) do
    ttl = DateTime.diff(expires_at, issued_at, :second)

    if ttl > 0 and ttl <= @max_ttl_seconds, do: :ok, else: :error
  end
end
