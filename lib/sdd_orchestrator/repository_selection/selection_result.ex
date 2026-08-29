defmodule SddOrchestrator.RepositorySelection.SelectionResult do
  @moduledoc """
  A worker's answer to one open selection request.

  The worker holds the path, runs the Git check there, and sends back only
  verdicts: which of the requested identities matched, the folder's own name,
  and a freshly generated identity when one was asked for. That is the whole
  point of the round trip. The repository stays on the Mac and the control
  plane learns nothing about where it lives.

  `new/1` is the only way to build one, and it is strict on purpose. A worker
  answer arrives from outside the control plane, so an unknown outcome, a
  `matches` value that is not a list, a folder name that is really a path, or
  any key this module does not recognise is refused as `:invalid_result`
  before it can reach a requester. The recognised-key rule is what keeps a
  path out: a map carrying `path`, `folder_path`, or `remote_url` is refused
  by the same check that refuses any other stray key.
  """

  @enforce_keys [:request_id, :outcome]
  defstruct [:request_id, :outcome, :folder_name, :identity, matches: []]

  @outcomes [:selected, :cancelled, :not_a_git_repository, :empty_repository, :inaccessible]
  @keys [:request_id, :outcome, :folder_name, :matches, :identity]

  @typedoc "What the worker did with the request. Everything but `:selected` is a refusal to name a repository."
  @type outcome ::
          :selected | :cancelled | :not_a_git_repository | :empty_repository | :inaccessible

  @type t :: %__MODULE__{
          request_id: String.t(),
          outcome: outcome(),
          folder_name: String.t() | nil,
          matches: [term()],
          identity: String.t() | nil
        }

  @doc "The outcomes a worker may answer with."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc """
  Builds one result from a worker's plain map, with string or atom keys.

  Returns `{:error, :invalid_result}` for anything a trusted worker would
  never send, so a malformed or hostile answer is refused at the boundary
  rather than delivered to a requester.
  """
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_result}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_keys(attrs),
         {:ok, request_id} <- fetch_request_id(attrs),
         {:ok, outcome} <- fetch_outcome(attrs),
         {:ok, folder_name} <- fetch_folder_name(attrs),
         {:ok, matches} <- fetch_matches(attrs),
         {:ok, identity} <- fetch_identity(attrs) do
      {:ok,
       %__MODULE__{
         request_id: request_id,
         outcome: outcome,
         folder_name: folder_name,
         matches: matches,
         identity: identity
       }}
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

  # A folder name is the last path segment. A value holding a separator is a
  # path, which this boundary refuses rather than passes on.
  defp fetch_folder_name(attrs) do
    case Map.get(attrs, :folder_name) do
      nil -> {:ok, nil}
      name when is_binary(name) -> reject_path(name)
      _other -> {:error, :invalid_result}
    end
  end

  defp reject_path(name) do
    if String.contains?(name, ["/", "\\"]) do
      {:error, :invalid_result}
    else
      {:ok, name}
    end
  end

  defp fetch_matches(attrs) do
    case Map.get(attrs, :matches, []) do
      matches when is_list(matches) -> {:ok, matches}
      _other -> {:error, :invalid_result}
    end
  end

  defp fetch_identity(attrs) do
    case Map.get(attrs, :identity) do
      nil -> {:ok, nil}
      identity when is_binary(identity) -> {:ok, identity}
      _other -> {:error, :invalid_result}
    end
  end
end
