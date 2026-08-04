defmodule SddOrchestrator.AIRuntime.RuntimeProjections do
  @moduledoc """
  Access-safe read-only projection boundary for one runtime session.

  This module publishes `capability:ai-runtime-observation`. It composes the
  pinned-session, ordered-observation, quota, and spending-ceiling boundaries as
  a caller and writes nothing: no adapter is contacted, no worker is called, no
  row is inserted, updated, or deleted.

  Two audiences read the same run through two different projections.

    * The connection owner reads the owner-exact projection. The connection is
      theirs, so it may carry the account-wide quota facts, the credits and
      paid-continuation state those facts contain, and the strict spending
      ceiling of the run.
    * A current authorized project participant reads the participant-safe
      projection. It carries the project's own run usage, the selected model and
      reasoning effort, and a safe availability state, and nothing else.
      Unrelated account-wide quota, credits, spend, and another project's usage
      never cross this boundary.

  Absent evidence is projected as an explicit marker rather than as a value. An
  unknown quota is `%{state: :unknown}` and is never read as zero or unlimited,
  a session that carries no ceiling at all reports `%{state: :not_applicable}`,
  and a ceiling whose ledger has not been opened yet reports `%{state:
  :unknown}` rather than an empty ledger. Usage keeps one stable shape and
  labels an unobserved value `:unknown` at its source instead of reporting it as
  zero.

  ## What is enforced, and what the caller owns

  Participant authorization is evaluated against the project the caller names,
  through `SddOrchestrator.Participation.Boundary`, on every call, and the
  answer never widens beyond the single session reference the caller names. A
  caller who is not a current member of the named project is denied, so a
  participant of another project is denied under this project's scope. Every
  denial is the same `{:error, :unavailable}`: a denied caller learns neither
  whether the project exists, nor whether the session exists, nor whether they
  used to be a member, nor which check failed.

  Slice 11 cannot itself map a session to a project. A session records an opaque
  consumer reference, not a project, so binding a run reference to its project
  remains the calling slice's obligation — exactly as
  `SddOrchestrator.Privacy.Rights.retire_runtime_consumers/2` already requires
  the project to name its own consumer references. This boundary guarantees the
  authorization check and the single-session scope; it does not, and cannot,
  guarantee that the session the caller named belongs to the project the caller
  named.

  Presentation stays outside this boundary. Slice 07 and Slice 12 remain the
  owners of their own surfaces.
  """

  alias SddOrchestrator.Accounts.Account

  alias SddOrchestrator.AIRuntime.{
    AIRuntimeSession,
    Quotas,
    RuntimeCosts,
    RuntimeObservations,
    RuntimeSessions
  }

  alias SddOrchestrator.Participation.Boundary
  alias SddOrchestrator.Repo

  @owner_keys ~w(session_id consumer consumer_ref provider authentication_mode model effort
                 pinned_at availability usage quota spend observations)a

  @participant_keys ~w(session_id model effort usage availability observations)a

  @participant_observation_keys ~w(sequence observed_at elapsed tokens status unknown_fields)a

  # The owner sees the boundary of the run, not the internal reservation
  # mechanics the ceiling is enforced with.
  @spend_keys ~w(currency ceiling reserved observed remaining paused pause_reason)a

  # The one project capability a run projection is evidence for.
  @evidence_capability :read_run_evidence

  @unknown %{state: :unknown}
  @not_applicable %{state: :not_applicable}
  @unknown_availability %{state: :unknown, pause_reason: nil, source: :unknown}

  @typedoc "Safe owner-projection failures."
  @type owner_error :: :account_unavailable | :not_found | :invalid_request

  @typedoc "The single uniform participant denial."
  @type participant_error :: :unavailable

  @typedoc "An actor as the participation boundary resolves it."
  @type actor :: %{
          optional(:account_id) => Ecto.UUID.t() | nil,
          optional(:hosted_identity_id) => Ecto.UUID.t() | nil
        }

  @doc """
  The owner-exact projection of one runtime session.

  Authorization is account ownership: the session is account-scoped, so a
  session belonging to another account is refused as `:not_found` rather than
  disclosed. There is no second authorization path here.

  The account-wide quota is read through the owner's connection. A session whose
  connection reference has been detached, and a quota whose evidence is missing
  or no longer current, both project `%{state: :unknown}`.
  """
  @spec owner_projection(Account.t() | Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, owner_error()}
  def owner_projection(account_or_id, session_id, opts \\ []) do
    with {:ok, session} <- RuntimeSessions.get_session(account_or_id, session_id),
         {:ok, observations} <-
           RuntimeObservations.list_observations(
             account_or_id,
             session.session_id,
             observation_opts(opts)
           ) do
      latest = latest_observation(account_or_id, session.session_id)

      {:ok,
       %{
         session_id: session.session_id,
         consumer: session.consumer,
         consumer_ref: session.consumer_ref,
         provider: session.provider,
         authentication_mode: session.authentication_mode,
         model: session.model,
         effort: session.effort,
         pinned_at: session.pinned_at,
         availability: availability(latest),
         usage: owner_usage(latest),
         quota: quota(account_or_id, session, opts),
         spend: spend(account_or_id, session),
         observations: observations
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The participant-safe projection of one project run.

  Every requirement is checked on every call and every failure is the same
  denial: the actor must be a current member of the named project, must
  currently hold `#{inspect(@evidence_capability)}` there, the session must
  resolve, and it must be a working-agent run. A support-assistant session is a
  personal support conversation rather than a project run and is refused here
  even for a valid participant.
  """
  @spec participant_projection(Ecto.UUID.t(), actor(), Ecto.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, participant_error()}
  def participant_projection(project_id, actor, session_id, opts \\ []) do
    with true <- is_map(actor),
         {:ok, _member} <- Boundary.current_member(project_id, actor),
         true <- Boundary.authorized?(project_id, actor, @evidence_capability),
         {:ok, account_id, session} <- run_session(session_id),
         {:ok, observations} <-
           RuntimeObservations.list_observations(
             account_id,
             session.session_id,
             observation_opts(opts)
           ) do
      latest = latest_observation(account_id, session.session_id)

      {:ok,
       %{
         session_id: session.session_id,
         model: session.model,
         effort: session.effort,
         usage: participant_usage(latest),
         availability: availability(latest),
         observations: Enum.map(observations, &participant_observation/1)
       }}
    else
      _denied -> {:error, :unavailable}
    end
  end

  @doc "The exact top-level keys of the owner-exact projection."
  @spec owner_keys() :: [atom()]
  def owner_keys, do: @owner_keys

  @doc "The exact top-level keys of the participant-safe projection."
  @spec participant_keys() :: [atom()]
  def participant_keys, do: @participant_keys

  @doc "The exact keys of one participant-safe observation."
  @spec participant_observation_keys() :: [atom()]
  def participant_observation_keys, do: @participant_observation_keys

  # A participant is generally not the connection owner, so the session is
  # resolved by its own reference and only then re-read through the pinned
  # session boundary inside its owning account.
  defp run_session(session_id) do
    with {:ok, session_id} <- cast_id(session_id),
         %AIRuntimeSession{account_id: account_id} <- Repo.get(AIRuntimeSession, session_id),
         {:ok, %{consumer: :working_agent} = session} <-
           RuntimeSessions.get_session(account_id, session_id) do
      {:ok, account_id, session}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp latest_observation(account_or_id, session_id) do
    case RuntimeObservations.latest_observation(account_or_id, session_id) do
      {:ok, observation} -> observation
      {:error, _reason} -> nil
    end
  end

  # A detached connection leaves stored history readable, but there is no
  # account-wide fact left to read through it.
  defp quota(_account_or_id, %{connection_id: nil}, _opts), do: @unknown

  defp quota(account_or_id, session, opts) do
    case Quotas.current_quota(account_or_id, session.connection_id, quota_opts(opts)) do
      {:ok, quota} -> quota
      {:error, _reason} -> @unknown
    end
  end

  # A ChatGPT session carries no ceiling at all; an API-key session whose ledger
  # is not open yet has one that is simply not known here.
  defp spend(_account_or_id, %{authentication_mode: "chatgpt"}), do: @not_applicable

  defp spend(account_or_id, session) do
    case RuntimeCosts.get_ledger(account_or_id, session.session_id) do
      {:ok, ledger} -> Map.take(ledger, @spend_keys)
      {:error, _reason} -> @unknown
    end
  end

  defp availability(nil), do: @unknown_availability

  defp availability(%{status: status}),
    do: %{state: status.state, pause_reason: status.pause_reason, source: status.source}

  # The owner may see what a turn is estimated to have cost. A participant sees
  # the same elapsed time and token counters without it.
  defp owner_usage(observation),
    do: Map.put(participant_usage(observation), :estimated_cost, estimated_cost(observation))

  defp participant_usage(nil), do: %{elapsed: unknown_elapsed(), tokens: unknown_tokens()}

  defp participant_usage(observation),
    do: %{elapsed: observation.elapsed, tokens: observation.tokens}

  defp estimated_cost(nil), do: unknown_estimated_cost()
  defp estimated_cost(observation), do: observation.estimated_cost

  defp participant_observation(observation),
    do: Map.take(observation, @participant_observation_keys)

  defp unknown_elapsed, do: %{seconds: nil, source: :unknown}

  defp unknown_tokens, do: %{input: nil, output: nil, total: nil, source: :unknown}

  defp unknown_estimated_cost,
    do: %{amount: nil, currency: nil, basis: nil, source: :unknown}

  defp observation_opts(opts), do: Keyword.take(opts, [:limit])

  defp quota_opts(opts), do: Keyword.take(opts, [:now])

  defp cast_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :unavailable}
    end
  end

  defp cast_id(_id), do: {:error, :unavailable}
end
