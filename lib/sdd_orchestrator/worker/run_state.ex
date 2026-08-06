defmodule SddOrchestrator.Worker.RunState do
  @moduledoc """
  Worker-local durable record of the attempt currently or most recently in
  flight.

  Written before a command's acceptance is acknowledged and read back on
  reconnect or restart, so an already-accepted command, a superseded fence,
  or a duplicate redelivery is recognised from disk rather than from process
  memory a restart would lose. Stored as a single owner-only JSON file under
  the same worker home directory as `SddOrchestrator.Worker.Configuration`
  (see `Configuration.home/1`, reused rather than re-resolved here) — no
  Ecto, no database, no control-plane context, so the worker runtime can
  read and write it without starting the application.

  A record holds `:current` — the attempt this worker most recently
  accepted — and `:previous`, set only when accepting a new attempt
  supersedes an older one still marked `"accepted"`. `:previous` is the
  durable fact that nothing runs under the superseded fence anymore, even
  though this task starts no real process to stop; a later task that does
  start one reads this same record to know it must not continue. Both are
  `nil` for a fresh worker that has never received a command.
  """

  alias SddOrchestrator.Worker.Configuration

  @file_name "run_state.json"
  @lifecycle_states ~w(accepted stopped)

  @enforce_keys [
    :command_id,
    :operation,
    :project_id,
    :feature_id,
    :run_id,
    :attempt_number,
    :fence_token,
    :manifest_digest,
    :last_sequence,
    :agent_thread_ref,
    :lifecycle
  ]
  defstruct @enforce_keys

  # `:agent_thread_ref` is the one field legitimately absent until a later
  # task launches an agent.
  @required_entry_fields @enforce_keys
                         |> Enum.reject(&(&1 == :agent_thread_ref))
                         |> Enum.map(&Atom.to_string/1)

  @type t :: %__MODULE__{
          command_id: String.t(),
          operation: String.t(),
          project_id: String.t(),
          feature_id: String.t(),
          run_id: String.t(),
          attempt_number: pos_integer(),
          fence_token: pos_integer(),
          manifest_digest: String.t(),
          last_sequence: non_neg_integer(),
          agent_thread_ref: String.t() | nil,
          lifecycle: String.t()
        }

  @type snapshot :: %{current: t() | nil, previous: t() | nil}

  @doc "The lifecycle values a stored entry may carry."
  @spec lifecycle_states() :: [String.t()]
  def lifecycle_states, do: @lifecycle_states

  @doc "An empty record for a worker that has never accepted a command."
  @spec empty() :: snapshot()
  def empty, do: %{current: nil, previous: nil}

  @doc "The full path to the run-state file under `home/1`."
  @spec path(String.t() | nil) :: String.t()
  def path(home_override \\ nil), do: Path.join(Configuration.home(home_override), @file_name)

  @doc """
  Loads the run-state record from `home/1`.

  No stored file is a legitimate, common case — a worker that has never
  received a command — and returns `{:ok, empty()}` rather than an error. A
  present but unreadable, non-JSON, non-object, or incomplete file returns a
  typed `{:error, {:invalid_run_state, reason}}` instead of raising.
  """
  @spec load(String.t() | nil) :: {:ok, snapshot()} | {:error, {:invalid_run_state, term()}}
  def load(home_override \\ nil) do
    file = path(home_override)

    if File.exists?(file) do
      with {:ok, contents} <- safe_read(file),
           {:ok, decoded} <- safe_decode(contents) do
        from_map(decoded)
      end
    else
      {:ok, empty()}
    end
  end

  @doc """
  Persists the run-state record worker-locally.

  Creates `home/1` if needed and restricts it to owner-only (`0700`), then
  writes the run-state file and restricts it to owner-only (`0600`). Both
  permissions are (re)applied on every write, matching
  `Configuration.store/2`.
  """
  @spec store(snapshot(), String.t() | nil) :: :ok
  def store(%{current: current, previous: previous}, home_override \\ nil)
      when (is_nil(current) or is_struct(current, __MODULE__)) and
             (is_nil(previous) or is_struct(previous, __MODULE__)) do
    dir = Configuration.home(home_override)
    file = path(home_override)

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    File.write!(file, Jason.encode!(to_map(current, previous), pretty: true))
    File.chmod!(file, 0o600)

    :ok
  end

  defp safe_read(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:invalid_run_state, {:unreadable, reason}}}
    end
  end

  defp safe_decode(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_run_state, :not_an_object}}
      {:error, reason} -> {:error, {:invalid_run_state, {:invalid_json, reason}}}
    end
  end

  defp from_map(decoded) do
    with {:ok, current} <- decode_entry(Map.get(decoded, "current")),
         {:ok, previous} <- decode_entry(Map.get(decoded, "previous")) do
      {:ok, %{current: current, previous: previous}}
    end
  end

  defp decode_entry(nil), do: {:ok, nil}

  defp decode_entry(entry) when is_map(entry) do
    case Enum.find(@required_entry_fields, fn field -> blank?(entry[field]) end) do
      nil -> build_entry(entry)
      missing_field -> {:error, {:invalid_run_state, {:missing_field, missing_field}}}
    end
  end

  defp decode_entry(_entry), do: {:error, {:invalid_run_state, :invalid_entry}}

  defp build_entry(entry) do
    with :ok <- validate_lifecycle(entry["lifecycle"]),
         :ok <- validate_positive(entry["attempt_number"]),
         :ok <- validate_positive(entry["fence_token"]),
         :ok <- validate_non_negative(entry["last_sequence"]) do
      {:ok,
       %__MODULE__{
         command_id: entry["command_id"],
         operation: entry["operation"],
         project_id: entry["project_id"],
         feature_id: entry["feature_id"],
         run_id: entry["run_id"],
         attempt_number: entry["attempt_number"],
         fence_token: entry["fence_token"],
         manifest_digest: entry["manifest_digest"],
         last_sequence: entry["last_sequence"],
         agent_thread_ref: entry["agent_thread_ref"],
         lifecycle: entry["lifecycle"]
       }}
    end
  end

  defp validate_lifecycle(value) do
    if value in @lifecycle_states,
      do: :ok,
      else: {:error, {:invalid_run_state, {:invalid_lifecycle, value}}}
  end

  defp validate_positive(value) do
    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, {:invalid_run_state, :invalid_ordering_value}}
  end

  defp validate_non_negative(value) do
    if is_integer(value) and value >= 0,
      do: :ok,
      else: {:error, {:invalid_run_state, :invalid_ordering_value}}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp to_map(current, previous) do
    %{"current" => entry_to_map(current), "previous" => entry_to_map(previous)}
  end

  defp entry_to_map(nil), do: nil

  defp entry_to_map(%__MODULE__{} = entry) do
    %{
      "command_id" => entry.command_id,
      "operation" => entry.operation,
      "project_id" => entry.project_id,
      "feature_id" => entry.feature_id,
      "run_id" => entry.run_id,
      "attempt_number" => entry.attempt_number,
      "fence_token" => entry.fence_token,
      "manifest_digest" => entry.manifest_digest,
      "last_sequence" => entry.last_sequence,
      "agent_thread_ref" => entry.agent_thread_ref,
      "lifecycle" => entry.lifecycle
    }
  end
end
