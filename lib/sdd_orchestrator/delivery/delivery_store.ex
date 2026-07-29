defmodule SddOrchestrator.Delivery.DeliveryStore do
  @moduledoc """
  One contract over the two places feature-delivery state can be authoritative.

  A hosted project commits through PostgreSQL; a device-authoritative project
  commits through the worker-owned device store. `specs/05` prohibits keeping a
  device project's data in the hosted database merely to run the dashboard, so
  these cannot be one implementation with a flag — they are two adapters that
  must behave identically.

  Writes are expressed as an ordered list of named steps rather than as
  changesets, because a changeset is a hosted concept. Each adapter interprets
  the same steps: the hosted one as an `Ecto.Multi`, the device one as a batch
  the worker applies under its single serialized boundary. Both apply the whole
  list or none of it, and both reject a step whose expected state version has
  been superseded.

  A step may reference an earlier step's result with `{:ref, step_name, field}`,
  which is what lets one commit create a run, create its first attempt against
  that run, append the activity that names both, and enqueue the start command —
  atomically, in either authority.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}

  alias SddOrchestrator.Delivery.{
    ActivityEntry,
    AgentRun,
    BlockingQuestion,
    Feature,
    RunAttempt,
    RunCommand
  }

  alias SddOrchestrator.Delivery.DeliveryStore.{Device, Hosted}

  @type authority :: PersonalWorkspace.t() | DeviceWorkspace.t()

  @type operation ::
          {:insert_run, map()}
          | {:transition_run, AgentRun.t(), String.t(), keyword()}
          | {:set_effective_revision, AgentRun.t(), String.t(), String.t()}
          | {:advance_attempt_number, AgentRun.t(), pos_integer()}
          | {:resume_run, AgentRun.t(), String.t(), String.t(), pos_integer()}
          | {:insert_attempt, map()}
          | {:transition_attempt, RunAttempt.t(), String.t()}
          | {:claim_lease, RunAttempt.t(), String.t(), DateTime.t()}
          | {:observe_sequence, RunAttempt.t(), non_neg_integer()}
          | {:transition_feature, Feature.t(), String.t(), keyword()}
          | {:set_feature_status, Feature.t(), String.t()}
          | {:clear_assignment, Feature.t()}
          | {:insert_blocking_question, map()}
          | {:resolve_question, BlockingQuestion.t(), String.t(), String.t() | nil}
          | {:append_activity, map()}
          | {:enqueue_command, map()}

  @type step :: {atom(), operation()}
  @type result :: %{atom() => term()}

  @type error :: :stale_state | :unsupported_authority | :invalid_step | term()

  @doc "Applies one ordered batch of delivery writes atomically."
  @callback commit(authority(), Ecto.UUID.t(), [step()]) ::
              {:ok, result()} | {:error, atom(), error()}

  @doc "Reads one run."
  @callback fetch_run(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, AgentRun.t()} | :error

  @doc "Reads one feature."
  @callback fetch_feature(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, Feature.t()} | :error

  @doc """
  Lists one project's features, optionally narrowed to one assignee.

  A departure has to find every feature the former participant still holds
  without knowing which ones they are, and that question belongs to whichever
  store is authoritative for the project rather than to the hosted database.
  """
  @callback list_features(authority(), Ecto.UUID.t(), keyword()) :: [Feature.t()]

  @doc "Reads the run's one current attempt, when it has one."
  @callback current_attempt(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, RunAttempt.t()} | :error

  @doc """
  Reads the run's highest-numbered attempt, current or terminal.

  A continuation after a terminal attempt has nothing current to read, and still
  needs the ordering and fence the next attempt must advance past.
  """
  @callback latest_attempt(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, RunAttempt.t()} | :error

  @doc "Reads the run's one open blocking question, when it has one."
  @callback open_question(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
              {:ok, BlockingQuestion.t()} | :error

  @doc "Lists one feature's activity in authoritative order."
  @callback list_activity(authority(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
              [ActivityEntry.t()]

  @doc "Claims due commands for one dispatcher."
  @callback claim_commands(authority(), Ecto.UUID.t(), String.t(), keyword()) :: [RunCommand.t()]

  @doc "Records a worker acknowledgement and its replayable result."
  @callback acknowledge_command(authority(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
              {:ok, RunCommand.t()} | {:error, :not_found | term()}

  @doc "The operations both adapters must interpret identically."
  @spec operations() :: [atom()]
  def operations do
    ~w(
      insert_run transition_run set_effective_revision advance_attempt_number
      resume_run insert_attempt transition_attempt claim_lease observe_sequence
      transition_feature set_feature_status clear_assignment
      insert_blocking_question resolve_question append_activity enqueue_command
    )a
  end

  @doc """
  Reports whether one authority resolves to an adapter at all.

  Every read answers an unusable authority with the same empty result it would
  give a project that genuinely has nothing, so a caller that must not treat
  "could not ask" as "nothing to do" has to be able to tell them apart first.
  """
  @spec supported?(term()) :: boolean()
  def supported?(%PersonalWorkspace{}), do: true
  def supported?(%DeviceWorkspace{}), do: true
  def supported?(_authority), do: false

  @spec commit(authority(), Ecto.UUID.t(), [step()]) ::
          {:ok, result()} | {:error, atom(), error()}
  def commit(authority, project_id, steps),
    do: dispatch(authority, :commit, [project_id, steps])

  @spec fetch_run(authority(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, AgentRun.t()} | :error
  def fetch_run(authority, project_id, run_id),
    do: dispatch(authority, :fetch_run, [project_id, run_id])

  @spec fetch_feature(authority(), Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Feature.t()} | :error
  def fetch_feature(authority, project_id, feature_id),
    do: dispatch(authority, :fetch_feature, [project_id, feature_id])

  @spec list_features(authority(), Ecto.UUID.t(), keyword()) :: [Feature.t()]
  def list_features(authority, project_id, opts \\ []),
    do: dispatch(authority, :list_features, [project_id, opts])

  @spec current_attempt(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RunAttempt.t()} | :error
  def current_attempt(authority, project_id, run_id),
    do: dispatch(authority, :current_attempt, [project_id, run_id])

  @spec latest_attempt(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RunAttempt.t()} | :error
  def latest_attempt(authority, project_id, run_id),
    do: dispatch(authority, :latest_attempt, [project_id, run_id])

  @spec open_question(authority(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, BlockingQuestion.t()} | :error
  def open_question(authority, project_id, run_id),
    do: dispatch(authority, :open_question, [project_id, run_id])

  @spec list_activity(authority(), Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: [ActivityEntry.t()]
  def list_activity(authority, project_id, feature_id, opts \\ []),
    do: dispatch(authority, :list_activity, [project_id, feature_id, opts])

  @spec claim_commands(authority(), Ecto.UUID.t(), String.t(), keyword()) :: [RunCommand.t()]
  def claim_commands(authority, project_id, owner, opts \\ []),
    do: dispatch(authority, :claim_commands, [project_id, owner, opts])

  @spec acknowledge_command(authority(), Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, RunCommand.t()} | {:error, :not_found | term()}
  def acknowledge_command(authority, project_id, command_id, result \\ %{}),
    do: dispatch(authority, :acknowledge_command, [project_id, command_id, result])

  @doc """
  Resolves `{:ref, step, field}` placeholders against results so far.

  Both adapters share this so a step list means the same thing in either
  authority; a placeholder naming a step that has not run is an error rather
  than a silent `nil`.
  """
  @spec resolve(term(), result()) :: {:ok, term()} | {:error, :invalid_step}
  def resolve({:ref, step, field}, results) do
    case Map.fetch(results, step) do
      {:ok, value} -> {:ok, Map.get(value, field)}
      :error -> {:error, :invalid_step}
    end
  end

  def resolve(%{} = attrs, results) when not is_struct(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve(value, results) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def resolve(value, _results), do: {:ok, value}

  defp dispatch(%PersonalWorkspace{} = authority, function, args),
    do: apply(Hosted, function, [authority | args])

  defp dispatch(%DeviceWorkspace{} = authority, function, args),
    do: apply(Device, function, [authority | args])

  defp dispatch(_authority, :commit, _args), do: {:error, :authority, :unsupported_authority}
  defp dispatch(_authority, :fetch_run, _args), do: :error
  defp dispatch(_authority, :fetch_feature, _args), do: :error
  defp dispatch(_authority, :list_features, _args), do: []
  defp dispatch(_authority, :current_attempt, _args), do: :error
  defp dispatch(_authority, :latest_attempt, _args), do: :error
  defp dispatch(_authority, :open_question, _args), do: :error
  defp dispatch(_authority, :list_activity, _args), do: []
  defp dispatch(_authority, :claim_commands, _args), do: []
  defp dispatch(_authority, :acknowledge_command, _args), do: {:error, :not_found}
end
