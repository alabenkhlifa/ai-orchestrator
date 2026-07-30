defmodule SddOrchestrator.Delivery.PreviewAdapter do
  @moduledoc """
  One contract over whatever actually serves a project's branch previews.

  The slice needs deterministic preview behaviour without selecting,
  provisioning, or authenticating to a provider, so this is a behaviour with
  three operations — request, status, cleanup — and a policy that says whether a
  project may use it at all. Nothing here provisions infrastructure and nothing
  here decides whether work was verified.

  Authorization is preconfigured, per project, and closed by default. A project
  with no configured preview path gets no request at all, and a path the project
  did not authorize is refused rather than attempted. That is what keeps a
  preview from becoming a way to reach an environment nobody approved.

  Credentials resolve here and stay here. A request carries the *reference* to a
  credential — `credential_ref`, an opaque configured name — never the credential
  itself, and `SecretBoundary` re-checks every request before it leaves. What the
  adapter does with that reference is the adapter's business; what is stored
  afterwards is only the provider's opaque handle and one safe link.

  A provider's own words are never kept. Failure reasons are accepted only as
  atoms and recorded as tokens, because a free-text provider message is exactly
  where a credential would ride into a durable record.
  """

  alias SddOrchestrator.Delivery.{PreviewDeployment, SecretBoundary}

  @default_provider "configured-preview"
  @default_request_timeout_ms 5 * 60 * 1_000
  @default_ttl_seconds 24 * 60 * 60

  @observable_statuses ~w(pending ready failed expired)

  @type policy :: %{
          adapter: module(),
          provider: String.t(),
          path: String.t(),
          credential_ref: String.t() | nil,
          request_timeout_ms: pos_integer(),
          ttl_seconds: pos_integer()
        }

  # The credential reference is optional in each shape because the caller never
  # supplies it: this module resolves it from configuration and adds it on the
  # way out, which is precisely what keeps it out of anything a caller builds.
  @type request :: %{
          required(:request_key) => String.t(),
          required(:project_id) => Ecto.UUID.t(),
          required(:feature_id) => Ecto.UUID.t(),
          required(:run_id) => Ecto.UUID.t(),
          required(:attempt_id) => Ecto.UUID.t(),
          required(:branch) => String.t(),
          required(:commit_sha) => String.t(),
          required(:path) => String.t(),
          required(:provider) => String.t(),
          optional(:credential_ref) => String.t() | nil
        }

  @type query :: %{
          required(:request_key) => String.t(),
          required(:provider) => String.t(),
          required(:provider_ref) => String.t() | nil,
          optional(:credential_ref) => String.t() | nil
        }

  @type cleanup :: %{
          required(:command_id) => String.t(),
          required(:request_key) => String.t(),
          required(:provider) => String.t(),
          required(:provider_ref) => String.t() | nil,
          required(:reason) => String.t(),
          optional(:credential_ref) => String.t() | nil
        }

  @type observation :: %{
          status: String.t(),
          provider_ref: String.t() | nil,
          link: String.t() | nil,
          expires_at: DateTime.t() | nil,
          failure_reason: String.t() | nil
        }

  @type error ::
          :preview_not_configured
          | :preview_not_authorized
          | :preview_path_not_authorized
          | :preview_request_rejected
          | :invalid_preview_response
          | atom()

  @doc """
  Requests one deployment of the exact commit the request names.

  The provider is expected to key on `request_key`, so a redelivered request
  returns the deployment it already made rather than creating a second one.
  """
  @callback request(request()) :: {:ok, map()} | {:error, atom()}

  @doc "Reports what the provider currently says about one requested deployment."
  @callback status(query()) :: {:ok, map()} | {:error, atom()}

  @doc "Releases one deployment. Releasing what is already gone is not an error."
  @callback cleanup(cleanup()) :: :ok | {:error, atom()}

  @doc "The configured preview policy for this deployment."
  @spec configured() :: keyword()
  def configured, do: Application.get_env(:sdd_orchestrator, :preview, [])

  @doc "The statuses a provider may report about a deployment it holds."
  @spec observable_statuses() :: [String.t()]
  def observable_statuses, do: @observable_statuses

  @doc """
  Resolves whether this project may preview, and on which authorized path.

  Closed by default at every step: no configured adapter, a project that was
  never listed, an empty path list, and a path the project did not authorize are
  four distinct refusals, and none of them results in a provider call.
  """
  @spec authorize(Ecto.UUID.t(), String.t() | nil) :: {:ok, policy()} | {:error, error()}
  def authorize(project_id, requested_path \\ nil) do
    config = configured()

    with {:ok, adapter} <- configured_adapter(config),
         {:ok, paths} <- authorized_paths(config, project_id),
         {:ok, path} <- authorized_path(paths, requested_path) do
      {:ok,
       %{
         adapter: adapter,
         provider: Keyword.get(config, :provider, @default_provider),
         path: path,
         credential_ref: Keyword.get(config, :credential_ref),
         request_timeout_ms:
           Keyword.get(config, :request_timeout_ms, @default_request_timeout_ms),
         ttl_seconds: Keyword.get(config, :ttl_seconds, @default_ttl_seconds)
       }}
    end
  end

  @doc """
  The stable key one binding presents to the provider.

  Derived from the run, attempt, commit, and path rather than from a generated
  identifier, so the same binding produces the same key in a later process and
  the provider's own idempotency can do its half of the work.
  """
  @spec request_key(map()) :: String.t()
  def request_key(%{run_id: run_id, attempt_id: attempt_id, commit_sha: commit, path: path}) do
    digest =
      :sha256
      |> :crypto.hash(Enum.join([run_id, attempt_id, commit, path], "\n"))
      |> Base.encode16(case: :lower)

    "preview:v1:" <> digest
  end

  @doc """
  Asks the provider to deploy, and normalizes whatever it answers.

  The request is scanned for credential material on the way out, so an adapter
  cannot be handed a secret even by a caller that meant well.
  """
  @spec request(policy(), request()) :: {:ok, observation()} | {:error, error()}
  def request(%{adapter: adapter} = policy, request) do
    with :ok <- outbound(request) do
      adapter
      |> invoke(:request, [Map.put(request, :credential_ref, policy.credential_ref)])
      |> normalize()
    end
  end

  @doc "Asks the provider what became of a deployment it was already given."
  @spec status(policy(), query()) :: {:ok, observation()} | {:error, error()}
  def status(%{adapter: adapter} = policy, query) do
    with :ok <- outbound(query) do
      adapter
      |> invoke(:status, [Map.put(query, :credential_ref, policy.credential_ref)])
      |> normalize()
    end
  end

  @doc """
  Asks the provider to release one deployment.

  This is the seam project deletion and cancellation call. It never reports what
  the provider said beyond success or a reason token, because a cleanup message
  is provider prose like any other.
  """
  @spec cleanup(policy(), cleanup()) :: :ok | {:error, error()}
  def cleanup(%{adapter: adapter} = policy, command) do
    with :ok <- outbound(command) do
      case invoke(adapter, :cleanup, [Map.put(command, :credential_ref, policy.credential_ref)]) do
        :ok -> :ok
        {:error, reason} -> {:error, reason_token(reason)}
        _unusable -> {:error, :invalid_preview_response}
      end
    end
  end

  @doc """
  Turns whatever the provider returned into a recordable observation.

  Public because the reason a malformed provider answer is refused has to be
  provable without a provider. Everything is checked: the status is one of the
  four a provider may report, the reference is opaque, the link is safe, and a
  ready deployment without a link is a contradiction rather than a success.
  """
  @spec normalize({:ok, map()} | {:error, term()} | term()) ::
          {:ok, observation()} | {:error, error()}
  def normalize({:ok, %{} = answer}) do
    with {:ok, status} <- observed_status(answer),
         {:ok, provider_ref} <- observed_provider_ref(answer),
         {:ok, link} <- observed_link(answer),
         {:ok, expires_at} <- observed_expiry(answer),
         :ok <- ready_has_link(status, link) do
      {:ok,
       %{
         status: status,
         provider_ref: provider_ref,
         link: link,
         expires_at: expires_at,
         failure_reason: observed_failure_reason(status, answer)
       }}
    end
  end

  def normalize({:error, reason}), do: {:error, reason_token(reason)}
  def normalize(_unusable), do: {:error, :invalid_preview_response}

  @doc """
  Reduces one provider reason to a machine-readable token.

  Only an atom survives. A binary reason is discarded entirely rather than
  sanitized, because a provider message that happens to contain a token would
  survive any sanitizing that still preserved the message.
  """
  @spec reason_token(term()) :: atom()
  def reason_token(reason) when is_atom(reason) and not is_nil(reason) do
    if Regex.match?(~r"\A[a-z][a-z0-9_]{0,99}\z", Atom.to_string(reason)) do
      reason
    else
      :provider_error
    end
  end

  def reason_token(_reason), do: :provider_error

  defp configured_adapter(config) do
    case Keyword.get(config, :adapter) do
      nil -> {:error, :preview_not_configured}
      adapter when is_atom(adapter) -> {:ok, adapter}
      _invalid -> {:error, :preview_not_configured}
    end
  end

  # A project is authorized by being listed, never by defaulting. An unlisted
  # project and a project listed with no paths are the same answer: this project
  # has no preconfigured preview path.
  defp authorized_paths(config, project_id) do
    config
    |> Keyword.get(:projects, %{})
    |> project_paths(project_id)
    |> case do
      [_first | _rest] = paths -> {:ok, paths}
      _none -> {:error, :preview_not_authorized}
    end
  end

  defp project_paths(projects, project_id) when is_map(projects) do
    case Map.get(projects, project_id) do
      paths when is_list(paths) -> Enum.filter(paths, &PreviewDeployment.valid_path?/1)
      path when is_binary(path) -> Enum.filter([path], &PreviewDeployment.valid_path?/1)
      _none -> []
    end
  end

  defp project_paths(_projects, _project_id), do: []

  defp authorized_path(paths, nil), do: {:ok, hd(paths)}

  defp authorized_path(paths, requested) do
    if requested in paths, do: {:ok, requested}, else: {:error, :preview_path_not_authorized}
  end

  # The last gate before a value leaves the control plane. A caller that put a
  # credential into a request is refused here rather than trusted, which is the
  # same rule every other worker-facing value already obeys.
  defp outbound(value) do
    case SecretBoundary.validate(value) do
      :ok -> :ok
      {:error, _reason} -> {:error, :preview_request_rejected}
    end
  end

  # An adapter that raises or exits is a provider failure, not a control-plane
  # crash: a preview can never be allowed to take down the path that recorded a
  # verified completion.
  defp invoke(adapter, function, args) do
    apply(adapter, function, args)
  rescue
    _error -> {:error, :provider_error}
  catch
    :exit, _reason -> {:error, :provider_unavailable}
  end

  defp observed_status(answer) do
    case answer[:status] || answer["status"] do
      status when status in @observable_statuses -> {:ok, status}
      _unusable -> {:error, :invalid_preview_response}
    end
  end

  defp observed_provider_ref(answer) do
    case answer[:provider_ref] || answer["provider_ref"] do
      nil -> {:ok, nil}
      ref -> if PreviewDeployment.valid_provider_ref?(ref), do: {:ok, ref}, else: bad_response()
    end
  end

  defp observed_link(answer) do
    case answer[:link] || answer["link"] do
      nil -> {:ok, nil}
      link -> if PreviewDeployment.safe_link?(link), do: {:ok, link}, else: bad_response()
    end
  end

  defp observed_expiry(answer) do
    case answer[:expires_at] || answer["expires_at"] do
      nil -> {:ok, nil}
      %DateTime{} = at -> {:ok, at}
      _unusable -> bad_response()
    end
  end

  # A provider reporting "failed" without a reason still has to record one, so
  # the reader is told the provider refused rather than shown a blank.
  defp observed_failure_reason("failed", answer) do
    case answer[:failure_reason] || answer["failure_reason"] do
      nil -> "provider_failed"
      reason -> reason |> reason_token() |> Atom.to_string()
    end
  end

  defp observed_failure_reason(_status, _answer), do: nil

  defp ready_has_link("ready", nil), do: bad_response()
  defp ready_has_link(_status, _link), do: :ok

  defp bad_response, do: {:error, :invalid_preview_response}
end
