defmodule SddOrchestrator.Devices.PortableRepositoryIdentity do
  @moduledoc """
  Worker-local generation and exact matching of portable repository identities.

  A portable identity is a strict versioned value containing a random validation
  salt and an HMAC-SHA256 digest over the repository's sorted root commits. The
  salt permits an authorized worker to validate the same repository without a
  source workspace key. New generation always uses a fresh salt, so independent
  onboarding does not create a global repository-equality signal.

  Root commits, paths, credentials, and workspace identities remain inside the
  worker boundary and are never encoded in the portable value.
  """

  alias SddOrchestrator.Devices.RepositoryValidation

  @prefix "local-repo"
  @version_tag "v1"
  @version 1
  @salt_bytes 32
  @digest_bytes 32

  @enforce_keys [:version, :validation_salt, :digest]
  defstruct [:version, :validation_salt, :digest]

  @type t :: %__MODULE__{
          version: 1,
          validation_salt: binary(),
          digest: binary()
        }

  @type identity_error :: :invalid_identifier | :legacy_identifier
  @type error :: RepositoryValidation.error() | identity_error()
  @type comparator :: (binary(), binary() -> boolean())

  @doc """
  Generates a fresh portable identity for a repository.

  Calling this function twice for the same repository deliberately returns
  different identities. Each generated identity still validates that repository
  exactly when supplied back to a worker.
  """
  @spec generate(Path.t()) :: {:ok, String.t()} | {:error, RepositoryValidation.error()}
  def generate(path) do
    with {:ok, roots} <- RepositoryValidation.root_commit_ids(path) do
      salt = :crypto.strong_rand_bytes(@salt_bytes)

      {:ok,
       encode(%__MODULE__{version: @version, validation_salt: salt, digest: digest(roots, salt)})}
    end
  end

  @doc "Parses one canonical portable identity and rejects legacy or malformed values."
  @spec parse(term()) :: {:ok, t()} | {:error, identity_error()}
  def parse(identifier) when is_binary(identifier) do
    case String.split(identifier, ":", parts: 5) do
      [@prefix, @version_tag, encoded_salt, encoded_digest] ->
        with {:ok, salt} <- decode_component(encoded_salt, @salt_bytes),
             {:ok, digest} <- decode_component(encoded_digest, @digest_bytes) do
          {:ok,
           %__MODULE__{
             version: @version,
             validation_salt: salt,
             digest: digest
           }}
        else
          :error -> {:error, :invalid_identifier}
        end

      _other ->
        if legacy_identifier?(identifier),
          do: {:error, :legacy_identifier},
          else: {:error, :invalid_identifier}
    end
  end

  def parse(_identifier), do: {:error, :invalid_identifier}

  @doc "Encodes a parsed portable identity in its canonical external format."
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{
        version: @version,
        validation_salt: salt,
        digest: digest
      })
      when byte_size(salt) == @salt_bytes and byte_size(digest) == @digest_bytes do
    Enum.join(
      [@prefix, @version_tag, encode_component(salt), encode_component(digest)],
      ":"
    )
  end

  @doc """
  Recomputes and securely compares a supplied portable identity for `path`.

  Legacy identifiers are rejected here because they require the original
  workspace salt and must use `match_legacy/3`.
  """
  @spec match(Path.t(), term()) :: {:ok, boolean()} | {:error, error()}
  def match(path, identifier) do
    match_with_compare(path, identifier, &Plug.Crypto.secure_compare/2)
  end

  @doc false
  @spec match_with_compare(Path.t(), term(), comparator()) ::
          {:ok, boolean()} | {:error, error()}
  def match_with_compare(path, identifier, compare) when is_function(compare, 2) do
    with {:ok, identity} <- parse(identifier),
         {:ok, roots} <- RepositoryValidation.root_commit_ids(path) do
      {:ok, compare.(identity.digest, digest(roots, identity.validation_salt))}
    end
  end

  @doc """
  Reports whether a value has the legacy workspace-scoped fingerprint format.

  Recognition does not grant authority or perform a match. A legacy value can be
  validated only with its original workspace salt through `match_legacy/3`.
  """
  @spec legacy_identifier?(term()) :: boolean()
  def legacy_identifier?(identifier) when is_binary(identifier) do
    match?({:ok, _digest}, decode_component(identifier, @digest_bytes))
  end

  def legacy_identifier?(_identifier), do: false

  @doc """
  Validates a legacy workspace-scoped fingerprint with its original workspace
  salt using constant-time digest comparison.
  """
  @spec match_legacy(Path.t(), term(), binary()) ::
          {:ok, boolean()} | {:error, RepositoryValidation.error() | :invalid_identifier}
  def match_legacy(path, identifier, workspace_salt) when is_binary(workspace_salt) do
    match_legacy_with_compare(
      path,
      identifier,
      workspace_salt,
      &Plug.Crypto.secure_compare/2
    )
  end

  def match_legacy(_path, _identifier, _workspace_salt),
    do: {:error, :invalid_identifier}

  @doc false
  @spec match_legacy_with_compare(Path.t(), term(), binary(), comparator()) ::
          {:ok, boolean()} | {:error, RepositoryValidation.error() | :invalid_identifier}
  def match_legacy_with_compare(path, identifier, workspace_salt, compare)
      when is_binary(workspace_salt) and is_function(compare, 2) do
    with {:ok, expected_digest} <- decode_legacy(identifier),
         {:ok, %{fingerprint: actual_identifier}} <-
           RepositoryValidation.validate(path, workspace_salt),
         {:ok, actual_digest} <- decode_legacy(actual_identifier) do
      {:ok, compare.(expected_digest, actual_digest)}
    end
  end

  defp decode_legacy(identifier) when is_binary(identifier) do
    case decode_component(identifier, @digest_bytes) do
      {:ok, digest} -> {:ok, digest}
      :error -> {:error, :invalid_identifier}
    end
  end

  defp decode_legacy(_identifier), do: {:error, :invalid_identifier}

  defp digest(roots, salt) do
    :crypto.mac(:hmac, :sha256, salt, Enum.join(roots, "\n"))
  end

  defp encode_component(value), do: Base.url_encode64(value, padding: false)

  defp decode_component(encoded, expected_bytes) do
    with {:ok, decoded} <- Base.url_decode64(encoded, padding: false),
         true <- byte_size(decoded) == expected_bytes,
         true <- encode_component(decoded) == encoded do
      {:ok, decoded}
    else
      _ -> :error
    end
  end
end
