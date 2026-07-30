defmodule SddOrchestrator.Delivery.PreviewDeployment do
  @moduledoc """
  One non-production preview of the exact commit an attempt verified.

  A preview is a convenience, never a verdict. It is started *after* a verified
  completion and can neither produce nor withdraw one, so every field here is an
  observation about a deployment and none of them is an input to whether the
  work was proved. That separation is the reason a failed, timed-out, or absent
  preview leaves an otherwise verified feature exactly where it was.

  Identity is the binding, not the row. A deployment belongs to one run, one
  attempt, one branch, and one exact commit; a request for a different commit is
  a different deployment rather than a new state of this one. The binding is
  therefore frozen at the database by a trigger, and a second deployment of the
  same binding is refused by a unique index — which together are what make
  "requesting twice does nothing twice" a property of the store instead of a
  promise made by callers.

  Nothing that could authenticate to a provider is stored. What is kept is an
  opaque provider reference and, when the deployment succeeds, one participant-
  safe link: `https`, or `http` only on the loopback host a local worker serves.
  A link carrying user info, a query string, or a fragment is refused by the
  changeset and again by a check constraint, because a token in a query string
  is the ordinary way a preview URL becomes a credential.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.Delivery.{AgentRun, Feature, RunAttempt}
  alias SddOrchestrator.Projects.Project

  # `timed_out` and `expired` are deliberately not folded into `failed`. All
  # three stop the preview, but a reader deciding whether to retry, wait, or
  # look elsewhere needs to know which one happened.
  @statuses ~w(pending ready failed timed_out expired superseded)
  @failure_statuses ~w(failed timed_out)
  @open_statuses ~w(pending ready)
  @cleanup_states ~w(none requested done failed)

  @max_branch_bytes 200
  @max_commit_bytes 64
  @max_path_bytes 100
  @max_provider_bytes 100
  @max_provider_ref_bytes 200
  @max_link_bytes 500
  @max_failure_reason_bytes 100
  @max_cleanup_command_bytes 200

  # An opaque provider handle: no whitespace, no `@`, no query, no fragment. It
  # addresses a deployment at the provider and must never be usable as a link.
  @provider_ref_pattern ~r"\A[A-Za-z0-9][A-Za-z0-9._:/=-]{0,199}\z"

  @path_pattern ~r"\A[A-Za-z0-9][A-Za-z0-9._/-]{0,99}\z"

  # A machine-readable token, never provider prose. Prose is where a leaked
  # credential would ride in.
  @failure_reason_pattern ~r"\A[a-z][a-z0-9_]{0,99}\z"

  @https_link_pattern ~r"\Ahttps://[A-Za-z0-9._~-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?\z"

  # A device-authoritative project's worker serves its preview on the machine
  # that owns the data. Requiring TLS there would forbid the one case where the
  # link never leaves the participant's own computer.
  @loopback_link_pattern ~r"\Ahttp://(localhost|127[.]0[.]0[.]1)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?\z"

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "preview_deployments" do
    field :branch, :string
    field :commit_sha, :string
    field :path, :string
    field :provider, :string
    field :provider_ref, :string
    field :link, :string
    field :status, :string, default: "pending"
    field :failure_reason, :string
    field :requested_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :timeout_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :cleanup_state, :string, default: "none"
    field :cleanup_command_id, :string
    field :state_version, :integer, default: 1

    belongs_to :project, Project
    belongs_to :feature, Feature
    belongs_to :run, AgentRun
    belongs_to :attempt, RunAttempt
    belongs_to :superseded_by, __MODULE__

    timestamps()
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec failure_statuses() :: [String.t()]
  def failure_statuses, do: @failure_statuses

  @spec open_statuses() :: [String.t()]
  def open_statuses, do: @open_statuses

  @spec cleanup_states() :: [String.t()]
  def cleanup_states, do: @cleanup_states

  @spec max_link_bytes() :: pos_integer()
  def max_link_bytes, do: @max_link_bytes

  @spec max_provider_ref_bytes() :: pos_integer()
  def max_provider_ref_bytes, do: @max_provider_ref_bytes

  @doc "Reports whether a later deployment has replaced this one."
  @spec current?(t()) :: boolean()
  def current?(%__MODULE__{superseded_by_id: superseded_by_id}), do: is_nil(superseded_by_id)

  @doc "Reports whether the deployment can still change without a new request."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: status}), do: status in @open_statuses

  @doc """
  Reports whether the preview stopped without producing a usable link.

  Timeout counts, because the design records a timed-out request as a failed
  preview even though the reason a reader sees is the more specific one.
  """
  @spec failed?(t()) :: boolean()
  def failed?(%__MODULE__{status: status}), do: status in @failure_statuses

  @doc "Reports whether one term is a participant-safe preview link."
  @spec safe_link?(term()) :: boolean()
  def safe_link?(link) when is_binary(link) do
    byte_size(link) <= @max_link_bytes and
      (Regex.match?(@https_link_pattern, link) or Regex.match?(@loopback_link_pattern, link))
  end

  def safe_link?(_link), do: false

  @doc """
  Reports whether one term is a well-formed opaque provider reference.

  A reference that contains `//` is refused however well formed it otherwise is:
  that is what a URL looks like, and a handle a reader could mistake for a link
  defeats the reason links are validated separately at all.
  """
  @spec valid_provider_ref?(term()) :: boolean()
  def valid_provider_ref?(ref) when is_binary(ref),
    do: Regex.match?(@provider_ref_pattern, ref) and not String.contains?(ref, "//")

  def valid_provider_ref?(_ref), do: false

  @doc "Reports whether one term is a configurable preview path."
  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path), do: Regex.match?(@path_pattern, path)
  def valid_path?(_path), do: false

  @doc """
  Records one requested deployment, bound to what the attempt actually verified.

  The binding fields are written once and never again: the trigger behind this
  table rejects any later change to them, so a deployment cannot be repointed at
  another commit after the fact.
  """
  def request_changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :branch,
      :commit_sha,
      :path,
      :provider,
      :provider_ref,
      :link,
      :status,
      :failure_reason,
      :requested_at,
      :ready_at,
      :timeout_at,
      :expires_at
    ])
    |> put_default_requested_at()
    |> put_change(:cleanup_state, "none")
    |> put_change(:cleanup_command_id, nil)
    |> put_change(:superseded_by_id, nil)
    |> put_change(:state_version, 1)
    |> validate_required([
      :project_id,
      :feature_id,
      :run_id,
      :attempt_id,
      :branch,
      :commit_sha,
      :path,
      :provider,
      :status,
      :requested_at,
      :timeout_at
    ])
    |> validate_exclusion(:status, ["superseded"])
    |> apply_shared_rules()
  end

  @doc """
  Records what the provider now says about a deployment already requested.

  Only an open deployment accepts an observation. A terminal one is already the
  answer, and letting a late provider poll reopen it is how a preview that was
  reported failed silently becomes ready again.
  """
  def observe_changeset(%__MODULE__{} = deployment, attrs, expected_state_version) do
    deployment
    |> cast(attrs, [:status, :provider_ref, :link, :failure_reason, :ready_at, :expires_at])
    |> validate_expected_version(expected_state_version)
    |> validate_observable()
    |> validate_required([:status])
    |> validate_exclusion(:status, ["superseded"])
    |> optimistic_lock(:state_version)
    |> apply_shared_rules()
  end

  @doc """
  Links one deployment to the deployment that replaced it.

  A later attempt verifying another commit does not invalidate what this one
  proved; it only means this preview is no longer the one to look at. The link
  is recorded once, so the chain a reader follows cannot be rewritten.
  """
  def supersede_changeset(%__MODULE__{} = deployment, superseded_by_id, expected_state_version) do
    deployment
    |> change(%{})
    |> validate_expected_version(expected_state_version)
    |> validate_supersedable(superseded_by_id)
    |> put_change(:superseded_by_id, superseded_by_id)
    |> put_change(:status, "superseded")
    |> validate_required([:superseded_by_id])
    |> optimistic_lock(:state_version)
    |> apply_shared_rules()
  end

  @doc """
  Records the durable cleanup command and, later, what it achieved.

  The command identifier is written before the provider is called so a cleanup
  interrupted by a restart is still visible as owed rather than forgotten.
  """
  def cleanup_changeset(%__MODULE__{} = deployment, attrs, expected_state_version) do
    deployment
    |> cast(attrs, [:cleanup_state, :cleanup_command_id])
    |> validate_expected_version(expected_state_version)
    |> validate_required([:cleanup_state, :cleanup_command_id])
    |> optimistic_lock(:state_version)
    |> apply_shared_rules()
  end

  @doc "The device-adapter value shape, with no Ecto or hosted dependency."
  @spec to_value(t()) :: map()
  def to_value(%__MODULE__{} = deployment) do
    %{
      "id" => deployment.id,
      "project_id" => deployment.project_id,
      "feature_id" => deployment.feature_id,
      "run_id" => deployment.run_id,
      "attempt_id" => deployment.attempt_id,
      "branch" => deployment.branch,
      "commit_sha" => deployment.commit_sha,
      "path" => deployment.path,
      "provider" => deployment.provider,
      "provider_ref" => deployment.provider_ref,
      "link" => deployment.link,
      "status" => deployment.status,
      "failure_reason" => deployment.failure_reason,
      "requested_at" => encode_time(deployment.requested_at),
      "ready_at" => encode_time(deployment.ready_at),
      "timeout_at" => encode_time(deployment.timeout_at),
      "expires_at" => encode_time(deployment.expires_at),
      "cleanup_state" => deployment.cleanup_state,
      "cleanup_command_id" => deployment.cleanup_command_id,
      "superseded_by_id" => deployment.superseded_by_id,
      "state_version" => deployment.state_version
    }
  end

  @spec from_value(map()) :: {:ok, t()} | {:error, :invalid_preview_value}
  def from_value(%{} = value) do
    with true <- value["status"] in @statuses,
         true <- value["cleanup_state"] in @cleanup_states,
         true <- is_integer(value["state_version"]) and value["state_version"] > 0,
         true <- is_binary(value["id"]) and is_binary(value["project_id"]),
         true <- is_binary(value["feature_id"]) and is_binary(value["run_id"]),
         true <- is_binary(value["attempt_id"]) and is_binary(value["branch"]),
         true <- is_binary(value["commit_sha"]) and is_binary(value["path"]),
         true <- is_binary(value["provider"]),
         true <- is_nil(value["link"]) or safe_link?(value["link"]),
         {:ok, requested_at} <- decode_time(value["requested_at"]),
         true <- not is_nil(requested_at),
         {:ok, ready_at} <- decode_time(value["ready_at"]),
         {:ok, timeout_at} <- decode_time(value["timeout_at"]),
         true <- not is_nil(timeout_at),
         {:ok, expires_at} <- decode_time(value["expires_at"]) do
      {:ok,
       %__MODULE__{
         id: value["id"],
         project_id: value["project_id"],
         feature_id: value["feature_id"],
         run_id: value["run_id"],
         attempt_id: value["attempt_id"],
         branch: value["branch"],
         commit_sha: value["commit_sha"],
         path: value["path"],
         provider: value["provider"],
         provider_ref: value["provider_ref"],
         link: value["link"],
         status: value["status"],
         failure_reason: value["failure_reason"],
         requested_at: requested_at,
         ready_at: ready_at,
         timeout_at: timeout_at,
         expires_at: expires_at,
         cleanup_state: value["cleanup_state"],
         cleanup_command_id: value["cleanup_command_id"],
         superseded_by_id: value["superseded_by_id"],
         state_version: value["state_version"]
       }}
    else
      _invalid -> {:error, :invalid_preview_value}
    end
  end

  def from_value(_value), do: {:error, :invalid_preview_value}

  defp put_default_requested_at(changeset) do
    case get_field(changeset, :requested_at) do
      nil -> put_change(changeset, :requested_at, DateTime.utc_now())
      _present -> changeset
    end
  end

  defp validate_expected_version(changeset, expected) do
    if changeset.data.state_version == expected do
      changeset
    else
      add_error(changeset, :state_version, "is stale")
    end
  end

  defp validate_observable(changeset) do
    if open?(changeset.data) do
      changeset
    else
      add_error(changeset, :status, "is already final")
    end
  end

  defp validate_supersedable(changeset, superseded_by_id) do
    cond do
      not is_nil(changeset.data.superseded_by_id) ->
        add_error(changeset, :superseded_by_id, "is already recorded")

      superseded_by_id == changeset.data.id ->
        add_error(changeset, :superseded_by_id, "cannot supersede itself")

      true ->
        changeset
    end
  end

  # A stopped preview has to say why, and a ready one has to have somewhere to
  # send the reader. Either half missing is a record that looks informative and
  # is not.
  defp validate_status_pairing(changeset) do
    status = get_field(changeset, :status)
    link = get_field(changeset, :link)
    reason = get_field(changeset, :failure_reason)

    cond do
      status == "ready" and is_nil(link) ->
        add_error(changeset, :link, "is required for a ready preview")

      status in @failure_statuses and is_nil(reason) ->
        add_error(changeset, :failure_reason, "is required for a #{status} preview")

      true ->
        changeset
    end
  end

  defp validate_link(changeset) do
    case get_field(changeset, :link) do
      nil -> changeset
      link -> if safe_link?(link), do: changeset, else: add_error(changeset, :link, "is not safe")
    end
  end

  defp validate_provider_ref(changeset) do
    case get_field(changeset, :provider_ref) do
      nil ->
        changeset

      ref ->
        if valid_provider_ref?(ref) do
          changeset
        else
          add_error(changeset, :provider_ref, "is not an opaque provider reference")
        end
    end
  end

  defp apply_shared_rules(changeset) do
    changeset
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:cleanup_state, @cleanup_states)
    |> validate_number(:state_version, greater_than: 0)
    |> validate_length(:branch, max: @max_branch_bytes, count: :bytes)
    |> validate_length(:commit_sha, max: @max_commit_bytes, count: :bytes)
    |> validate_length(:path, max: @max_path_bytes, count: :bytes)
    |> validate_length(:provider, max: @max_provider_bytes, count: :bytes)
    |> validate_length(:provider_ref, max: @max_provider_ref_bytes, count: :bytes)
    |> validate_length(:link, max: @max_link_bytes, count: :bytes)
    |> validate_length(:failure_reason, max: @max_failure_reason_bytes, count: :bytes)
    |> validate_length(:cleanup_command_id, max: @max_cleanup_command_bytes, count: :bytes)
    |> validate_format(:path, @path_pattern)
    |> validate_format(:failure_reason, @failure_reason_pattern)
    |> validate_link()
    |> validate_provider_ref()
    |> validate_status_pairing()
    |> check_constraint(:status, name: :preview_deployments_status_allowed)
    |> check_constraint(:cleanup_state, name: :preview_deployments_cleanup_state_allowed)
    |> check_constraint(:branch, name: :preview_deployments_branch_length)
    |> check_constraint(:commit_sha, name: :preview_deployments_commit_sha_length)
    |> check_constraint(:path, name: :preview_deployments_path_shape)
    |> check_constraint(:provider, name: :preview_deployments_provider_length)
    |> check_constraint(:provider_ref, name: :preview_deployments_provider_ref_shape)
    |> check_constraint(:link, name: :preview_deployments_link_safe)
    |> check_constraint(:failure_reason, name: :preview_deployments_failure_reason_shape)
    |> check_constraint(:link, name: :preview_deployments_ready_link)
    |> check_constraint(:failure_reason, name: :preview_deployments_failure_reason_present)
    |> check_constraint(:superseded_by_id, name: :preview_deployments_supersession_pairing)
    |> check_constraint(:superseded_by_id, name: :preview_deployments_supersession_distinct)
    |> check_constraint(:cleanup_command_id, name: :preview_deployments_cleanup_pairing)
    |> check_constraint(:state_version, name: :preview_deployments_state_version_positive)
    |> unique_constraint([:run_id, :attempt_id, :commit_sha],
      name: :preview_deployments_binding_index
    )
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:feature_id)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:superseded_by_id)
  end

  defp encode_time(nil), do: nil
  defp encode_time(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp decode_time(nil), do: {:ok, nil}

  defp decode_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, _reason} -> :error
    end
  end

  defp decode_time(_value), do: :error
end
