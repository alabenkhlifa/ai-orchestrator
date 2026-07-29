defmodule SddOrchestrator.Delivery.ArtifactStore do
  @moduledoc """
  One contract over the two places an evidence artifact can be stored privately.

  Screenshots and larger approved proof are private project data. A hosted
  project keeps them in PostgreSQL, encrypted at rest; a device-authoritative
  project keeps them in the worker-owned device store, sealed with the device
  vault. `specs/05` forbids keeping a device project's data in the hosted
  database, so — exactly as `DeliveryStore` — these are two adapters that must
  behave identically rather than one implementation with a flag.

  A reference is digest-addressed and opaque: `artifact:v1:sha256:<digest>`. It
  carries no scheme, no host, no query string, and no credential, so it cannot
  become a link and cannot be dereferenced by anything but this module. The
  digest is the caller's declared content hash, recomputed here before anything
  is stored, which is what makes a reference verifiable rather than merely
  unique.

  Everything a reader needs in order to judge an artifact — content type, byte
  size, digest, redaction state — lives on the artifact. Everything about where
  it came from — run, attempt, branch, commit — lives on the `Evidence` row that
  names the reference, and is deliberately not duplicated here.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.ArtifactStore.{Artifact, Device, Hosted}
  alias SddOrchestrator.Delivery.{DeliveryStore, Evidence, ParticipantGuard, SecretBoundary}

  @content_types ~w(image/png image/jpeg image/webp text/plain)
  @max_bytes 5 * 1024 * 1024
  @ref_prefix "artifact:v1:sha256:"
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()
  @type ref :: String.t()

  @type attrs :: %{
          required(:content) => binary(),
          required(:content_type) => String.t(),
          required(:digest) => String.t(),
          optional(:redacted) => boolean()
        }

  @type stored :: %{
          content: binary(),
          content_type: String.t(),
          digest: String.t(),
          redacted: boolean(),
          byte_size: non_neg_integer()
        }

  @type error ::
          :empty_artifact
          | :unsupported_content_type
          | :artifact_too_large
          | :digest_mismatch
          | :invalid_redaction
          | :artifact_conflict
          | :unsupported_authority
          | atom()

  @doc "Stores one already-validated artifact and returns its opaque reference."
  @callback put(authority(), Ecto.UUID.t(), stored()) :: {:ok, ref()} | {:error, error()}

  @doc "Reads one artifact, bytes included, for an authorized caller."
  @callback fetch(authority(), Ecto.UUID.t(), ref()) :: {:ok, Artifact.t()} | {:error, :not_found}

  @doc "Reads one artifact's metadata without loading its bytes."
  @callback stat(authority(), Ecto.UUID.t(), ref()) :: {:ok, Artifact.t()} | {:error, :not_found}

  @doc "Removes one artifact. Removing what is not there is not an error."
  @callback delete(authority(), Ecto.UUID.t(), ref()) :: :ok

  @doc "Removes every artifact one project holds, and says how many that was."
  @callback delete_project(authority(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}

  @doc "Lists the references one project currently holds."
  @callback list_refs(authority(), Ecto.UUID.t()) :: [ref()]

  @doc "The content types an artifact may declare."
  @spec content_types() :: [String.t()]
  def content_types, do: @content_types

  @doc "The largest artifact either authority will accept."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The opaque, non-dereferenceable prefix every reference carries."
  @spec ref_prefix() :: String.t()
  def ref_prefix, do: @ref_prefix

  @doc """
  Reports whether one authority resolves to an adapter at all.

  Every read answers an unusable authority with the same empty result it would
  give a project that genuinely holds nothing, so a caller that must not treat
  "could not ask" as "nothing stored" has to be able to tell them apart first.
  """
  @spec supported?(term()) :: boolean()
  def supported?(%PersonalWorkspace{}), do: true
  def supported?(%DeviceWorkspace{}), do: true
  def supported?(_authority), do: false

  @doc "The reference that addresses one content digest."
  @spec ref_for(String.t()) :: ref()
  def ref_for(digest) when is_binary(digest), do: @ref_prefix <> digest

  @doc "Reports whether one term is a well-formed artifact reference."
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref), do: match?({:ok, _digest}, digest_from_ref(ref))

  @doc "Recovers the content digest one reference addresses."
  @spec digest_from_ref(term()) :: {:ok, String.t()} | :error
  def digest_from_ref(@ref_prefix <> digest) when byte_size(digest) == 64 do
    if Regex.match?(@digest_pattern, digest), do: {:ok, digest}, else: :error
  end

  def digest_from_ref(_ref), do: :error

  @doc """
  Checks one artifact against the limits both adapters hold in common.

  This runs before any adapter is called, so a hosted project and a device
  project cannot disagree about what is storable. The digest is recomputed here
  rather than trusted, which is the whole reason a reference means anything.
  """
  @spec validate(term()) :: {:ok, stored()} | {:error, error()}
  def validate(%{content: content, content_type: content_type, digest: digest} = attrs) do
    redacted = Map.get(attrs, :redacted, false)

    with :ok <- validate_content(content),
         :ok <- validate_content_type(content_type),
         :ok <- validate_size(content),
         :ok <- validate_digest(content, digest),
         :ok <- validate_redaction(redacted),
         :ok <- SecretBoundary.validate(content) do
      {:ok,
       %{
         content: content,
         content_type: content_type,
         digest: digest,
         redacted: redacted,
         byte_size: byte_size(content)
       }}
    end
  end

  def validate(_attrs), do: {:error, :invalid_artifact}

  @doc """
  Stores one artifact under the project's own storage authority.

  Storing the same bytes twice returns the same reference and stores nothing
  new. Storing the same bytes under a contradictory description is refused:
  content-addressed bytes cannot be both a screenshot and a log, or both
  redacted and not.
  """
  @spec put(authority(), Ecto.UUID.t(), attrs()) :: {:ok, ref()} | {:error, error()}
  def put(authority, project_id, attrs) do
    case validate(attrs) do
      {:ok, validated} -> dispatch(authority, :put, [project_id, validated])
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads one artifact's bytes. A reference this project does not hold is absent."
  @spec fetch(authority(), Ecto.UUID.t(), ref()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def fetch(authority, project_id, ref) do
    case digest_from_ref(ref) do
      {:ok, _digest} -> dispatch(authority, :fetch, [project_id, ref])
      :error -> {:error, :not_found}
    end
  end

  @doc "Reads one artifact's metadata without its bytes."
  @spec stat(authority(), Ecto.UUID.t(), ref()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def stat(authority, project_id, ref) do
    case digest_from_ref(ref) do
      {:ok, _digest} -> dispatch(authority, :stat, [project_id, ref])
      :error -> {:error, :not_found}
    end
  end

  @doc "Removes one artifact. A malformed or absent reference is already removed."
  @spec delete(authority(), Ecto.UUID.t(), ref()) :: :ok
  def delete(authority, project_id, ref) do
    case digest_from_ref(ref) do
      {:ok, _digest} -> dispatch(authority, :delete, [project_id, ref])
      :error -> :ok
    end
  end

  @doc "Removes every artifact one project holds. The cleanup seam project deletion uses."
  @spec delete_project(authority(), Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def delete_project(authority, project_id),
    do: dispatch(authority, :delete_project, [project_id])

  @doc "Lists one project's stored references, so orphans can be found."
  @spec list_refs(authority(), Ecto.UUID.t()) :: [ref()]
  def list_refs(authority, project_id), do: dispatch(authority, :list_refs, [project_id])

  @doc """
  Reads the artifact one item of evidence names, for one acting person.

  Every refusal answers the same way. A stranger, a participant of another
  project, an unknown item, an item belonging elsewhere, and an item that never
  had an artifact are all `{:error, :not_found}`, so asking cannot reveal
  whether the content exists.
  """
  @spec fetch_for_evidence(
          authority(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          ParticipantGuard.actor()
        ) :: {:ok, Artifact.t()} | {:error, :not_found}
  def fetch_for_evidence(authority, project_id, evidence_id, actor) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :read_evidence),
         {:ok, evidence} <- find_evidence(authority, project_id, evidence_id),
         {:ok, ref} <- named_artifact(evidence),
         {:ok, artifact} <- fetch(authority, project_id, ref) do
      {:ok, artifact}
    else
      _undisclosed -> {:error, :not_found}
    end
  end

  defp find_evidence(authority, project_id, evidence_id) do
    authority
    |> DeliveryStore.list_evidence(project_id)
    |> Enum.find(&(&1.id == evidence_id))
    |> case do
      nil -> {:error, :not_found}
      evidence -> {:ok, evidence}
    end
  end

  # An item with no artifact is answered exactly like an item that does not
  # exist, because the difference is itself a disclosure.
  defp named_artifact(%Evidence{artifact_ref: ref}) when is_binary(ref), do: {:ok, ref}
  defp named_artifact(_evidence), do: {:error, :not_found}

  defp validate_content(content) when is_binary(content) and byte_size(content) > 0, do: :ok
  defp validate_content(_content), do: {:error, :empty_artifact}

  defp validate_content_type(content_type) when content_type in @content_types, do: :ok
  defp validate_content_type(_content_type), do: {:error, :unsupported_content_type}

  defp validate_size(content) when byte_size(content) <= @max_bytes, do: :ok
  defp validate_size(_content), do: {:error, :artifact_too_large}

  # The declared digest is recomputed rather than believed. A reference derived
  # from a digest nobody checked would address bytes that may never have matched.
  defp validate_digest(content, digest) when is_binary(digest) do
    if :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower) == digest do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp validate_digest(_content, _digest), do: {:error, :digest_mismatch}

  # Redaction is a privacy claim about the bytes. A value that is not plainly
  # true or false is refused rather than quietly read as "not redacted".
  defp validate_redaction(redacted) when is_boolean(redacted), do: :ok
  defp validate_redaction(_redacted), do: {:error, :invalid_redaction}

  # A configured adapter replaces both real ones, which is how a test scripts an
  # unavailable store without a database or a device worker.
  defp dispatch(authority, function, args) do
    case Application.get_env(:sdd_orchestrator, :artifact_store) do
      nil -> dispatch_authority(authority, function, args)
      module -> apply(module, function, [authority | args])
    end
  end

  defp dispatch_authority(%PersonalWorkspace{} = authority, function, args),
    do: apply(Hosted, function, [authority | args])

  defp dispatch_authority(%DeviceWorkspace{} = authority, function, args),
    do: apply(Device, function, [authority | args])

  defp dispatch_authority(_authority, :put, _args), do: {:error, :unsupported_authority}
  defp dispatch_authority(_authority, :fetch, _args), do: {:error, :not_found}
  defp dispatch_authority(_authority, :stat, _args), do: {:error, :not_found}
  defp dispatch_authority(_authority, :delete, _args), do: :ok
  defp dispatch_authority(_authority, :delete_project, _args), do: {:ok, 0}
  defp dispatch_authority(_authority, :list_refs, _args), do: []
end
