defmodule SddOrchestrator.AIRuntime.AgentRuntimeObservation do
  @moduledoc """
  One ordered minimized observation of a working agent.

  A row records elapsed time, token counters when available, an estimated cost
  and the basis it was calculated from when calculable, the quota buckets that
  apply, the current status, the label every one of those values carries, and
  the observation time. Prompt or completion content, provider account
  identity, credentials, raw provider errors, and the worker-local profile
  reference never belong in this schema.

  Ordering and idempotency are database invariants. `(session_id, sequence)`
  and `(session_id, event_key)` are both unique, so history cannot be silently
  reordered and one event cannot be stored twice even if two writers race.

  Check constraints carry the meaning of the vocabulary rather than leaving it
  to the application: a label a value can never honestly carry is refused, a
  missing value is stored as `unknown` with the value column NULL instead of a
  zero that would read as a fact, and a paused agent must name the resumable
  reason it paused for.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias SddOrchestrator.AIRuntime.ObservationAdapter

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @elapsed_sources ~w(worker_observed unknown)
  @token_sources ~w(provider_fact worker_observed unknown)
  @cost_sources ~w(local_estimate unknown)
  @quota_sources ~w(provider_fact unknown)
  @status_sources ~w(provider_fact worker_observed unknown)

  @basis_keys ~w(
    price_version price_source model input_tokens output_tokens
    input_unit_price output_unit_price
  )a
  @decimal_basis_keys ~w(input_unit_price output_unit_price)a

  @derive {Inspect,
           only: [
             :id,
             :account_id,
             :session_id,
             :sequence,
             :observed_at,
             :elapsed_source,
             :tokens_source,
             :cost_source,
             :quota_source,
             :status,
             :status_source,
             :pause_reason,
             :inserted_at
           ]}

  @type t :: %__MODULE__{}

  schema "agent_runtime_observations" do
    field :sequence, :integer
    field :event_key, :string
    field :observed_at, :utc_datetime

    field :elapsed_seconds, :integer
    field :elapsed_source, :string

    field :input_tokens, :integer
    field :output_tokens, :integer
    field :total_tokens, :integer
    field :tokens_source, :string

    field :estimated_cost_amount, :decimal
    field :estimated_cost_currency, :string
    field :estimated_cost_basis, :map
    field :cost_source, :string

    field :quota_refs, :map
    field :quota_source, :string

    field :status, :string
    field :status_source, :string
    field :pause_reason, :string

    field :unknown_fields, {:array, :string}

    belongs_to :account, SddOrchestrator.Accounts.Account
    belongs_to :session, SddOrchestrator.AIRuntime.AIRuntimeSession

    timestamps()
  end

  @doc "Builds one immutable observation from already validated runtime facts."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(observation, attrs) do
    observation
    |> cast(attrs, [
      :account_id,
      :session_id,
      :sequence,
      :event_key,
      :observed_at,
      :elapsed_seconds,
      :elapsed_source,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :tokens_source,
      :estimated_cost_amount,
      :estimated_cost_currency,
      :estimated_cost_basis,
      :cost_source,
      :quota_refs,
      :quota_source,
      :status,
      :status_source,
      :pause_reason,
      :unknown_fields
    ])
    |> validate_required([
      :account_id,
      :session_id,
      :sequence,
      :event_key,
      :observed_at,
      :elapsed_source,
      :tokens_source,
      :cost_source,
      :quota_refs,
      :quota_source,
      :status,
      :status_source,
      :unknown_fields
    ])
    |> validate_inclusion(:elapsed_source, @elapsed_sources)
    |> validate_inclusion(:tokens_source, @token_sources)
    |> validate_inclusion(:cost_source, @cost_sources)
    |> validate_inclusion(:quota_source, @quota_sources)
    |> validate_inclusion(:status_source, @status_sources)
    |> validate_inclusion(:status, ObservationAdapter.states())
    |> validate_number(:sequence,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: ObservationAdapter.max_sequence()
    )
    |> validate_observation()
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:session_id,
      name: :agent_runtime_observations_account_session_fkey
    )
    |> unique_constraint([:session_id, :sequence],
      name: :agent_runtime_observations_session_sequence_index,
      error_key: :sequence
    )
    |> unique_constraint([:session_id, :event_key],
      name: :agent_runtime_observations_session_event_key_index,
      error_key: :event_key
    )
    |> check_constraint(:sequence, name: :agent_runtime_observations_ordering_check)
    |> check_constraint(:elapsed_source, name: :agent_runtime_observations_source_check)
    |> check_constraint(:elapsed_seconds, name: :agent_runtime_observations_elapsed_check)
    |> check_constraint(:total_tokens, name: :agent_runtime_observations_tokens_check)
    |> check_constraint(:estimated_cost_amount, name: :agent_runtime_observations_cost_check)
    |> check_constraint(:quota_refs, name: :agent_runtime_observations_quota_check)
    |> check_constraint(:status, name: :agent_runtime_observations_status_check)
    |> check_constraint(:unknown_fields, name: :agent_runtime_observations_unknowns_check)
  end

  @doc "Flattens one validated observation into its stored columns."
  @spec to_attrs(map()) :: map()
  def to_attrs(observation) do
    %{
      sequence: observation.sequence,
      event_key: observation.event_key,
      observed_at: observation.observed_at,
      elapsed_seconds: observation.elapsed.seconds,
      elapsed_source: observation.elapsed.source,
      input_tokens: observation.tokens.input,
      output_tokens: observation.tokens.output,
      total_tokens: observation.tokens.total,
      tokens_source: observation.tokens.source,
      estimated_cost_amount: observation.estimated_cost.amount,
      estimated_cost_currency: observation.estimated_cost.currency,
      estimated_cost_basis: observation.estimated_cost.basis,
      cost_source: observation.estimated_cost.source,
      quota_refs: %{"items" => observation.quota.buckets},
      quota_source: observation.quota.source,
      status: observation.status.state,
      status_source: observation.status.source,
      pause_reason: observation.status.pause_reason,
      unknown_fields: observation.unknown_fields
    }
  end

  @doc "The stored values one row holds, in the adapter's normalized shape."
  @spec payload(t()) :: map()
  def payload(%__MODULE__{} = observation) do
    %{
      event_key: observation.event_key,
      sequence: observation.sequence,
      observed_at: observation.observed_at,
      elapsed: %{seconds: observation.elapsed_seconds, source: observation.elapsed_source},
      tokens: %{
        input: observation.input_tokens,
        output: observation.output_tokens,
        total: observation.total_tokens,
        source: observation.tokens_source
      },
      estimated_cost: %{
        amount: observation.estimated_cost_amount,
        currency: observation.estimated_cost_currency,
        basis: decode_basis(observation.estimated_cost_basis),
        source: observation.cost_source
      },
      quota: %{
        buckets: decode_buckets(observation.quota_refs),
        source: observation.quota_source
      },
      status: %{
        state: observation.status,
        pause_reason: observation.pause_reason,
        source: observation.status_source
      },
      unknown_fields: observation.unknown_fields || []
    }
  end

  @doc "Decodes one stored estimate basis back into its normalized shape."
  @spec decode_basis(term()) :: map() | nil
  def decode_basis(basis) when is_map(basis) do
    Map.new(@basis_keys, fn key ->
      {key, decode_basis_value(key, Map.get(basis, Atom.to_string(key), Map.get(basis, key)))}
    end)
  end

  def decode_basis(_basis), do: nil

  @doc "Decodes the stored applicable quota bucket references."
  @spec decode_buckets(term()) :: [map()]
  def decode_buckets(%{"items" => items}) when is_list(items),
    do: Enum.map(items, &decode_bucket/1)

  def decode_buckets(%{items: items}) when is_list(items), do: Enum.map(items, &decode_bucket/1)
  def decode_buckets(_quota_refs), do: []

  defp decode_bucket(bucket) when is_map(bucket) do
    %{
      id: Map.get(bucket, "id", Map.get(bucket, :id)),
      scope: Map.get(bucket, "scope", Map.get(bucket, :scope)),
      model: Map.get(bucket, "model", Map.get(bucket, :model))
    }
  end

  defp decode_bucket(bucket), do: bucket

  defp decode_basis_value(key, value) when key in @decimal_basis_keys and is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = parsed, ""} -> parsed
      _other -> value
    end
  end

  defp decode_basis_value(_key, value), do: value

  # The row is re-validated through the one definition of what an observation
  # may contain, so a value the boundary would refuse can never be persisted by
  # another caller building the changeset directly.
  defp validate_observation(changeset) do
    case ObservationAdapter.validate_observation(candidate(changeset)) do
      {:ok, normalized} ->
        changeset
        |> put_change(:quota_refs, %{"items" => encode(normalized.quota.buckets)})
        |> put_change(:estimated_cost_basis, encode(normalized.estimated_cost.basis))

      {:error, _reason} ->
        add_error(changeset, :event_key, "contains invalid observation facts")
    end
  end

  defp candidate(changeset) do
    %{
      event_key: get_field(changeset, :event_key),
      sequence: get_field(changeset, :sequence),
      observed_at: get_field(changeset, :observed_at),
      elapsed: %{
        seconds: get_field(changeset, :elapsed_seconds),
        source: get_field(changeset, :elapsed_source)
      },
      tokens: %{
        input: get_field(changeset, :input_tokens),
        output: get_field(changeset, :output_tokens),
        total: get_field(changeset, :total_tokens),
        source: get_field(changeset, :tokens_source)
      },
      estimated_cost: %{
        amount: get_field(changeset, :estimated_cost_amount),
        currency: get_field(changeset, :estimated_cost_currency),
        basis: decode_basis(get_field(changeset, :estimated_cost_basis)),
        source: get_field(changeset, :cost_source)
      },
      quota: %{
        buckets: decode_buckets(get_field(changeset, :quota_refs)),
        source: get_field(changeset, :quota_source)
      },
      status: %{
        state: get_field(changeset, :status),
        pause_reason: get_field(changeset, :pause_reason),
        source: get_field(changeset, :status_source)
      },
      unknown_fields: get_field(changeset, :unknown_fields)
    }
  end

  defp encode(nil), do: nil
  defp encode(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode(value) when is_list(value), do: Enum.map(value, &encode/1)

  defp encode(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), encode(item)} end)
  end

  defp encode(value), do: value
end
