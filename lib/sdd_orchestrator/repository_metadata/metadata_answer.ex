defmodule SddOrchestrator.RepositoryMetadata.MetadataAnswer do
  @moduledoc """
  A worker's answer to one open metadata request.

  The worker resolves the request's opaque references into the repository on
  the Mac, checks it, and sends back only verdicts: the repository's identity,
  its normalized root, and the commit it is at, or a refusal, or a
  cancellation. The repository stays on the Mac and the control plane learns
  nothing about where it lives.

  `new/1` is the only way to build one, and it is strict on purpose. A worker
  answer arrives from outside the control plane, so an unknown outcome, a
  refusal reason this module does not recognise, a missing value field for the
  outcome that requires it, or any key this module does not recognise is
  refused as `:invalid_result` before it can reach a requester. The
  recognised-key rule is what keeps a stray field, such as a path, out of a
  worker's answer.
  """

  @enforce_keys [:request_id, :outcome]
  defstruct [:request_id, :outcome, :repository_provider, :repository_id, :root, :commit, :reason]

  @outcomes [:metadata, :refused, :cancelled]
  @refusal_reasons [:repository_mismatch, :root_escape, :repository_unavailable]
  @keys [:request_id, :outcome, :repository_provider, :repository_id, :root, :commit, :reason]

  @typedoc "What the worker did with the request."
  @type outcome :: :metadata | :refused | :cancelled

  @typedoc "Why the worker refused to answer."
  @type refusal_reason :: :repository_mismatch | :root_escape | :repository_unavailable

  @type t :: %__MODULE__{
          request_id: String.t(),
          outcome: outcome(),
          repository_provider: String.t() | nil,
          repository_id: String.t() | nil,
          root: String.t() | nil,
          commit: String.t() | nil,
          reason: refusal_reason() | nil
        }

  @doc "The refusal reasons a worker may answer with."
  @spec refusal_reasons() :: [refusal_reason()]
  def refusal_reasons, do: @refusal_reasons

  @doc """
  Builds one answer from a worker's plain map, with string or atom keys.

  Returns `{:error, :invalid_result}` for anything a trusted worker would
  never send, so a malformed or hostile answer is refused at the boundary
  rather than delivered to a requester.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_result}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs),
         {:ok, request_id} <- fetch_request_id(attrs),
         {:ok, outcome} <- fetch_outcome(attrs),
         {:ok, fields} <- fetch_outcome_fields(outcome, attrs) do
      {:ok, struct!(__MODULE__, Map.merge(%{request_id: request_id, outcome: outcome}, fields))}
    end
  end

  def new(_attrs), do: {:error, :invalid_result}

  # Every key is checked against the allowlist before anything is read, so an
  # unrecognised key is refused even when the rest of the answer is valid.
  defp normalize_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case known_key(key) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, :invalid_result}}
      end
    end)
  end

  defp known_key(key) when is_atom(key), do: if(key in @keys, do: {:ok, key}, else: :error)

  defp known_key(key) when is_binary(key) do
    Enum.find_value(@keys, :error, fn known ->
      if Atom.to_string(known) == key, do: {:ok, known}
    end)
  end

  defp known_key(_key), do: :error

  defp fetch_request_id(%{request_id: id}) when is_binary(id), do: {:ok, id}
  defp fetch_request_id(_attrs), do: {:error, :invalid_result}

  defp fetch_outcome(%{outcome: outcome}) when outcome in @outcomes, do: {:ok, outcome}

  defp fetch_outcome(%{outcome: outcome}) when is_binary(outcome) do
    Enum.find_value(@outcomes, {:error, :invalid_result}, fn known ->
      if Atom.to_string(known) == outcome, do: {:ok, known}
    end)
  end

  defp fetch_outcome(_attrs), do: {:error, :invalid_result}

  # A "metadata" answer must carry every value field: it is the only outcome
  # a requester's blocked call resolves into a result.
  defp fetch_outcome_fields(:metadata, attrs) do
    with {:ok, repository_provider} <- require_binary(attrs, :repository_provider),
         {:ok, repository_id} <- require_binary(attrs, :repository_id),
         {:ok, root} <- require_binary(attrs, :root),
         {:ok, commit} <- require_binary(attrs, :commit) do
      {:ok,
       %{
         repository_provider: repository_provider,
         repository_id: repository_id,
         root: root,
         commit: commit
       }}
    end
  end

  defp fetch_outcome_fields(:refused, attrs) do
    with {:ok, reason} <- fetch_reason(attrs) do
      {:ok, %{reason: reason}}
    end
  end

  defp fetch_outcome_fields(:cancelled, _attrs), do: {:ok, %{}}

  defp require_binary(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, :invalid_result}
    end
  end

  defp fetch_reason(%{reason: reason}) when reason in @refusal_reasons, do: {:ok, reason}

  defp fetch_reason(%{reason: reason}) when is_binary(reason) do
    Enum.find_value(@refusal_reasons, {:error, :invalid_result}, fn known ->
      if Atom.to_string(known) == reason, do: {:ok, known}
    end)
  end

  defp fetch_reason(_attrs), do: {:error, :invalid_result}
end
