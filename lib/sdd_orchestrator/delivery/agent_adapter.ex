defmodule SddOrchestrator.Delivery.AgentAdapter.Launch do
  @moduledoc """
  One agent this worker started, and how it came by its context.

  `thread_start` is the reason this value exists. A resumed provider thread and
  a thread rebuilt from the manifest produce the same running agent, so nothing
  downstream could tell them apart by watching the work — yet the difference
  decides whether the attempt's context is provider memory or the approved
  record, and a caller that cannot see it cannot reason about either.
  """

  alias SddOrchestrator.Delivery.ExecutionManifest

  @enforce_keys [:handle, :manifest, :agent_version, :agent_input, :thread_ref, :thread_start]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          handle: term(),
          manifest: ExecutionManifest.t(),
          agent_version: String.t(),
          agent_input: %{required(String.t()) => term()},
          thread_ref: String.t() | nil,
          thread_start: :new | :resumed
        }
end

defmodule SddOrchestrator.Delivery.AgentAdapter do
  @moduledoc """
  The one boundary a configured coding agent is launched and observed through.

  Everything the agent learns arrives as a single projected input: identities,
  digests, the approved slice, the isolated branch, the required-check contract,
  the continuation reason, and the directory it may work in. Repository, model,
  worker, and control-plane secrets resolve inside the worker's own boundary and
  never appear there, and the subprocess environment is an allowlist rather than
  the worker's own — a credential the agent never receives is one it cannot
  leak into a diff, a log, or a provider request.

  The agent is launched only in the directory `Workspace` proves belongs to this
  run. A working directory that cannot be proven is refused before a process
  exists, because a branch name is not isolation and a cheap refusal is worth
  more than an expensive cleanup.

  A provider thread is an optimization, never the checkpoint. When one cannot be
  resumed the adapter starts a new thread from the same projected input, so
  losing provider memory costs a warm start rather than the attempt. The result
  says which happened.

  Events leave here only as the shared protocol's normalized envelopes, and the
  agent's vocabulary is deliberately narrower than the protocol's: an agent may
  report progress, evidence, a blocking question, and its own failure, but it
  may not declare verification complete or a workspace ready — those belong to
  the worker and the check runner. Anything else is dropped with a typed reason
  rather than forwarded raw, because a provider stream is exactly where
  unreviewed content and credential material would otherwise enter durable
  project activity.
  """

  alias SddOrchestrator.Delivery.AgentAdapter.Launch
  alias SddOrchestrator.Delivery.ExecutionManifest
  alias SddOrchestrator.Delivery.ProtocolCodec
  alias SddOrchestrator.Delivery.SecretBoundary
  alias SddOrchestrator.Delivery.Worker.Workspace
  alias SddOrchestrator.Delivery.WorkerProtocol

  @agent_protocol_majors [1]

  # A subprocess needs to be located, to read its own tool configuration, to
  # decode text the same way twice, and to have somewhere to write scratch
  # files. Nothing else in the worker's environment is the agent's business.
  @environment_allowlist ~w(HOME LANG LC_ALL PATH TMPDIR)

  # This boundary resolves no credential and must not be able to acquire one by
  # asking, which is the same rule the worker's repository boundary follows.
  @fixed_environment %{"GIT_TERMINAL_PROMPT" => "0"}

  # An agent reports what it did and what stopped it. Claiming the work is
  # verified, or that a workspace is ready, would let the agent stand in for the
  # evidence that proves it.
  @agent_event_types %{
    "blocked" => "blocked",
    "evidence" => "evidence",
    "failed" => "failed",
    "progress" => "progress"
  }

  @terminal_event_types ~w(blocked failed)

  # A thread the provider will not hand back is a warm-start loss, not an
  # attempt failure, so only these start errors fall back to a new thread.
  @thread_losses ~w(thread_expired thread_incompatible thread_not_found)a

  # A refused credential keeps its own reason. Collapsing it into "invalid
  # input" would hide the single failure this boundary exists to report.
  @secret_reasons ~w(secret_field_rejected secret_material_rejected)a

  @type agent_input :: %{required(String.t()) => term()}

  @type environment :: [{String.t(), String.t() | nil}]

  @type input :: %{
          required(:agent_input) => agent_input(),
          required(:environment) => environment(),
          required(:thread_ref) => String.t() | nil
        }

  @type handle :: %{
          required(:reference) => term(),
          required(:thread_ref) => String.t() | nil,
          required(:resumed?) => boolean()
        }

  @type agent_event :: %{required(String.t()) => term()}

  @type observation :: %{
          events: [map()],
          dropped: [{non_neg_integer(), atom()}],
          last_sequence: non_neg_integer(),
          terminal: String.t() | nil
        }

  @type error ::
          :agent_exited
          | :agent_launch_failed
          | :agent_unavailable
          | :incompatible_agent_version
          | :invalid_agent_input
          | :secret_field_rejected
          | :secret_material_rejected
          | Workspace.error()

  @doc "The installed agent's own protocol version, answered before any launch."
  @callback installed_version() :: {:ok, String.t()} | {:error, atom()}

  @doc "Starts or resumes one agent for the projected input it is handed."
  @callback start(input()) :: {:ok, handle()} | {:error, atom()}

  @doc "Returns whatever the running agent has produced since the last call."
  @callback observe(handle()) :: {:ok, [agent_event()]} | {:error, atom()}

  @doc "The configured coding-agent adapter, defaulting to the unavailable stand-in."
  @spec adapter() :: module()
  def adapter do
    Application.get_env(
      :sdd_orchestrator,
      :agent_adapter,
      SddOrchestrator.Delivery.AgentAdapter.Unavailable
    )
  end

  @spec environment_allowlist() :: [String.t()]
  def environment_allowlist, do: @environment_allowlist

  @spec agent_event_types() :: [String.t()]
  def agent_event_types, do: @agent_event_types |> Map.keys() |> Enum.sort()

  @doc """
  The installed agent's protocol version, refused unless this worker speaks it.

  Compatibility is settled before a process exists, so an agent this worker
  cannot understand never reaches the workspace. An adapter that cannot answer
  at all is treated as no agent rather than as an agent of unknown vintage.
  """
  @spec version(module()) :: {:ok, String.t()} | {:error, error()}
  def version(module \\ adapter()) do
    case module.installed_version() do
      {:ok, reported} -> confirm_version(reported)
      _unanswered -> {:error, :agent_unavailable}
    end
  end

  @doc """
  The environment one agent subprocess receives, and everything it does not.

  The allowlist carries values; every other variable the worker holds is
  returned cleared, so the agent inherits nothing by default. Stripping by name
  rather than by pattern is what makes this provable: a credential the worker
  never anticipated is removed for being unlisted, not for looking secret.
  """
  @spec environment() :: environment()
  def environment do
    own = System.get_env()

    own
    |> Map.drop(@environment_allowlist)
    |> Map.new(fn {name, _value} -> {name, nil} end)
    |> Map.merge(Map.take(own, @environment_allowlist))
    |> Map.merge(@fixed_environment)
    |> Enum.sort()
  end

  @doc """
  The minimum input one agent needs, projected from the manifest it must obey.

  The projection is a whitelist rather than a redaction: a field is here because
  the approved work cannot be done without it. The worker's own execution target
  is absent for that reason, and so is every credential — the manifest's rules
  are re-derived first so a hand-built manifest cannot widen what reaches an
  agent, and the finished input is checked again on its own terms.

  The working directory is proven to be this run's before anything is projected,
  so an agent input can never name a directory the run does not own.
  """
  @spec project(ExecutionManifest.t(), Path.t()) :: {:ok, agent_input()} | {:error, error()}
  def project(manifest, working_directory)

  def project(%ExecutionManifest{} = manifest, working_directory) do
    with :ok <- Workspace.ensure_working_directory(manifest, working_directory),
         {:ok, valid} <- revalidate(manifest),
         projected = projection(valid, working_directory),
         :ok <- SecretBoundary.validate(projected) do
      {:ok, projected}
    end
  end

  def project(_manifest, _working_directory), do: {:error, :invalid_agent_input}

  @doc """
  Starts one agent for this attempt inside its own proven working directory.

  Version, then input, then process: every gate the worker can fail is one it
  fails before there is anything to clean up.

  `:thread_ref` offers a provider thread to resume. A provider that refuses it
  does not fail the attempt — the same input starts a new thread instead, and
  the result records which of the two happened.
  """
  @spec launch(ExecutionManifest.t(), Path.t(), keyword()) ::
          {:ok, Launch.t()} | {:error, error()}
  def launch(manifest, working_directory, opts \\ [])

  def launch(%ExecutionManifest{} = manifest, working_directory, opts) do
    module = Keyword.get_lazy(opts, :adapter, &adapter/0)

    with {:ok, agent_version} <- version(module),
         {:ok, projected} <- project(manifest, working_directory),
         {:ok, handle, thread_start} <-
           start_agent(module, projected, Keyword.get(opts, :thread_ref)) do
      {:ok,
       %Launch{
         handle: handle,
         manifest: manifest,
         agent_version: agent_version,
         agent_input: projected,
         thread_ref: handle.thread_ref,
         thread_start: thread_start
       }}
    end
  end

  def launch(_manifest, _working_directory, _opts), do: {:error, :invalid_agent_input}

  @doc """
  Drains this agent's events into the shared protocol's normalized envelopes.

  Nothing the agent produced leaves as it arrived. The envelope is assembled
  from the run's own identity and the attempt's fence, and is accepted only if
  the shared codec accepts it, which is also where a credential-bearing payload
  is rejected. A dropped event consumes no sequence number, so the stream a run
  ingests stays contiguous whatever the provider emitted.
  """
  @spec observe(Launch.t(), keyword()) :: {:ok, observation()} | {:error, error()}
  def observe(%Launch{} = launch, opts) do
    module = Keyword.get_lazy(opts, :adapter, &adapter/0)

    with {:ok, binding} <- binding(launch, opts),
         {:ok, events} <- drain(module, launch.handle) do
      {:ok, normalize(events, binding)}
    end
  end

  defp confirm_version(reported) when is_binary(reported) do
    with {major, rest} <- Integer.parse(reported),
         true <- major in @agent_protocol_majors,
         true <- rest == "" or String.starts_with?(rest, ".") do
      {:ok, reported}
    else
      _incompatible -> {:error, :incompatible_agent_version}
    end
  end

  defp confirm_version(_reported), do: {:error, :incompatible_agent_version}

  defp revalidate(manifest) do
    case manifest |> ExecutionManifest.to_map() |> ExecutionManifest.new() do
      {:ok, valid} -> {:ok, valid}
      {:error, reason} when reason in @secret_reasons -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_agent_input}
    end
  end

  defp projection(manifest, working_directory) do
    %{
      "project_id" => manifest.project_id,
      "feature_id" => manifest.feature_id,
      "run_id" => manifest.run_id,
      "attempt_number" => manifest.attempt_number,
      "approved_slice" => manifest.approved_slice,
      "starting_revision_id" => manifest.starting_revision_id,
      "starting_revision_digest" => manifest.starting_revision_digest,
      "effective_revision_id" => manifest.effective_revision_id,
      "effective_revision_digest" => manifest.effective_revision_digest,
      "manifest_digest" => ExecutionManifest.digest(manifest),
      "target_branch" => manifest.target_branch,
      "required_checks" => manifest.required_checks,
      "continuation" => manifest.continuation,
      "agent_ref" => manifest.agent_ref,
      "working_directory" => working_directory
    }
  end

  defp start_agent(module, projected, nil), do: new_thread(module, projected)

  defp start_agent(module, projected, thread_ref) when is_binary(thread_ref) do
    case request(module, projected, thread_ref) do
      {:ok, %{resumed?: true} = handle} -> {:ok, handle, :resumed}
      {:ok, handle} -> {:ok, handle, :new}
      {:error, reason} when reason in @thread_losses -> new_thread(module, projected)
      {:error, reason} -> {:error, launch_error(reason)}
    end
  end

  defp start_agent(_module, _projected, _thread_ref), do: {:error, :invalid_agent_input}

  defp new_thread(module, projected) do
    case request(module, projected, nil) do
      {:ok, %{resumed?: false} = handle} -> {:ok, handle, :new}
      {:ok, _claimed} -> {:error, :agent_launch_failed}
      {:error, reason} -> {:error, launch_error(reason)}
    end
  end

  defp request(module, projected, thread_ref) do
    case module.start(%{
           agent_input: projected,
           environment: environment(),
           thread_ref: thread_ref
         }) do
      {:ok, handle} -> confirm_handle(handle)
      {:error, reason} -> {:error, reason}
    end
  end

  defp confirm_handle(
         %{reference: _reference, thread_ref: thread_ref, resumed?: resumed?} = handle
       )
       when (is_binary(thread_ref) or is_nil(thread_ref)) and is_boolean(resumed?),
       do: {:ok, handle}

  defp confirm_handle(_handle), do: {:error, :agent_launch_failed}

  defp launch_error(:agent_unavailable), do: :agent_unavailable
  defp launch_error(_reason), do: :agent_launch_failed

  defp binding(launch, opts) do
    command_id = Keyword.get(opts, :command_id)
    fence_token = Keyword.get(opts, :fence_token)
    last_sequence = Keyword.get(opts, :last_sequence, 0)

    if WorkerProtocol.valid_id?(command_id) and positive?(fence_token) and
         non_negative?(last_sequence) do
      {:ok,
       %{
         manifest: launch.manifest,
         command_id: command_id,
         fence_token: fence_token,
         sequence: last_sequence
       }}
    else
      {:error, :invalid_agent_input}
    end
  end

  defp positive?(value), do: is_integer(value) and value > 0
  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp drain(module, handle) do
    case module.observe(handle) do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:error, :agent_unavailable} -> {:error, :agent_unavailable}
      _stopped -> {:error, :agent_exited}
    end
  end

  defp normalize(events, binding) do
    {kept, dropped, sequence} =
      events
      |> Enum.with_index()
      |> Enum.reduce({[], [], binding.sequence}, &accumulate(&1, &2, binding))

    kept = Enum.reverse(kept)

    %{
      events: kept,
      dropped: Enum.reverse(dropped),
      last_sequence: sequence,
      terminal: terminal(kept)
    }
  end

  defp accumulate({event, index}, {kept, dropped, sequence}, binding) do
    case envelope(event, binding, sequence + 1) do
      {:ok, envelope} -> {[envelope | kept], dropped, sequence + 1}
      {:error, reason} -> {kept, [{index, reason} | dropped], sequence}
    end
  end

  defp envelope(event, binding, sequence) when is_map(event) and not is_struct(event) do
    with {:ok, event_type} <- agent_event_type(Map.get(event, "type")),
         {:ok, payload} <- payload(event) do
      accept(%{
        "protocol_version" => WorkerProtocol.version(),
        "type" => "event",
        "event_id" => WorkerProtocol.generate_id(),
        "run_id" => binding.manifest.run_id,
        "attempt_number" => binding.manifest.attempt_number,
        "command_id" => binding.command_id,
        "fence_token" => binding.fence_token,
        "sequence" => sequence,
        "event_type" => event_type,
        "occurred_at" => Map.get(event, "occurred_at"),
        "source" => "agent",
        "payload" => payload
      })
    end
  end

  defp envelope(_event, _binding, _sequence), do: {:error, :invalid_agent_event}

  defp accept(envelope) do
    case ProtocolCodec.validate(envelope) do
      :ok -> {:ok, envelope}
      {:error, _reason} = error -> error
    end
  end

  defp agent_event_type(type) do
    case Map.fetch(@agent_event_types, type) do
      {:ok, event_type} -> {:ok, event_type}
      :error -> {:error, :unsupported_agent_event}
    end
  end

  defp payload(%{"payload" => payload}) when is_map(payload) and not is_struct(payload),
    do: {:ok, payload}

  defp payload(_event), do: {:error, :invalid_agent_event}

  defp terminal(envelopes) do
    Enum.find_value(envelopes, fn envelope ->
      type = envelope["event_type"]

      if type in @terminal_event_types, do: type
    end)
  end
end

defmodule SddOrchestrator.Delivery.AgentAdapter.Unavailable do
  @moduledoc """
  The default adapter: no coding agent is configured.

  Answering `:agent_unavailable` to every question keeps an unconfigured
  deployment from launching an agent nobody chose, and makes the absence of
  configuration a refusal rather than a silently selected provider.
  """
  @behaviour SddOrchestrator.Delivery.AgentAdapter

  @impl true
  def installed_version, do: {:error, :agent_unavailable}

  @impl true
  def start(_input), do: {:error, :agent_unavailable}

  @impl true
  def observe(_handle), do: {:error, :agent_unavailable}
end
