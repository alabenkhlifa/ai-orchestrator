defmodule SddOrchestrator.Worker.Configuration do
  @moduledoc """
  Worker-local durable configuration: how this worker reaches the control
  plane, the credential it was issued at pairing, and what it may run.

  Stored as a single owner-only JSON file under the worker's home directory
  (see `home/1`). This module never opens a database connection or calls a
  control-plane context — it is plain struct and file I/O, so the worker
  runtime can load it without starting the application.
  """

  @enforce_keys [
    :control_plane_address,
    :device_workspace_id,
    :worker_credential,
    :agent_adapter,
    :agent_executable,
    :workspace_root,
    :project_id,
    :worker_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          control_plane_address: String.t(),
          device_workspace_id: String.t(),
          worker_credential: String.t(),
          agent_adapter: String.t(),
          agent_executable: String.t(),
          workspace_root: String.t(),
          project_id: String.t(),
          worker_id: String.t()
        }

  @agent_adapters ~w(claude_code codex)
  @file_name "worker.json"

  @doc """
  The worker-local storage root.

  Resolved as: the given `override` if non-nil, else the
  `:worker_home` application env (set by tests to point at a temp
  directory), else `~/.sdd_orchestrator/worker`.
  """
  @spec home(String.t() | nil) :: String.t()
  def home(override \\ nil)
  def home(override) when is_binary(override), do: override

  def home(nil) do
    Application.get_env(:sdd_orchestrator, :worker_home) ||
      Path.join(System.user_home!(), ".sdd_orchestrator/worker")
  end

  @doc "The full path to the worker configuration file under `home/1`."
  @spec path(String.t() | nil) :: String.t()
  def path(override \\ nil), do: Path.join(home(override), @file_name)

  @doc "The agent adapters a worker configuration may declare."
  @spec agent_adapters() :: [String.t()]
  def agent_adapters, do: @agent_adapters

  @doc """
  Builds a configuration from a completed pairing result and the operator's
  CLI-supplied fields.

  `pairing_result` is the `%{worker: worker, credential: credential}` map
  returned by completing pairing. `cli_fields` must have
  `:control_plane_address`, `:agent_adapter`,
  `:agent_executable`, `:workspace_root`, and `:project_id`.
  """
  @spec from_pairing(map(), map()) :: t()
  def from_pairing(%{worker: worker, credential: credential}, cli_fields) do
    %__MODULE__{
      control_plane_address: Map.fetch!(cli_fields, :control_plane_address),
      device_workspace_id: worker.device_workspace_id,
      worker_credential: credential,
      agent_adapter: Map.fetch!(cli_fields, :agent_adapter),
      agent_executable: Map.fetch!(cli_fields, :agent_executable),
      workspace_root: Map.fetch!(cli_fields, :workspace_root),
      project_id: Map.fetch!(cli_fields, :project_id),
      worker_id: worker.id
    }
  end

  @doc """
  Persists the configuration worker-locally.

  Creates `home/1` if needed and restricts it to owner-only (`0700`), then
  writes the configuration file and restricts it to owner-only (`0600`). Both
  permissions are (re)applied on every write.
  """
  # `home_override` is a CLI-supplied path (`--home`) or the worker's own
  # configured/default home directory — trusted application configuration,
  # never web or user input, matching this project's one existing precedent
  # (`Devices.DeviceStore.Local.init/1`). Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  @spec store(t(), String.t() | nil) :: :ok
  def store(%__MODULE__{} = config, home_override \\ nil) do
    dir = home(home_override)
    file = path(home_override)

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    File.write!(file, Jason.encode!(to_map(config), pretty: true))
    File.chmod!(file, 0o600)

    :ok
  end

  @doc """
  Loads the worker configuration from `home/1`.

  Returns a typed error instead of raising: `{:error, :not_paired}` when no
  configuration file exists yet, or `{:error, {:invalid_configuration,
  reason}}` when the file exists but is unreadable, not valid JSON, not a
  JSON object, or missing a required field.
  """
  @spec load(String.t() | nil) ::
          {:ok, t()} | {:error, :not_paired} | {:error, {:invalid_configuration, term()}}
  def load(home_override \\ nil) do
    file = path(home_override)

    if File.exists?(file) do
      with {:ok, contents} <- safe_read(file),
           {:ok, decoded} <- safe_decode(contents) do
        from_map(decoded)
      end
    else
      {:error, :not_paired}
    end
  end

  # `file` is derived from the same trusted `home_override` as `store/2`
  # above. Documented false positive.
  # sobelow_skip ["Traversal.FileModule"]
  defp safe_read(file) do
    case File.read(file) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:invalid_configuration, {:unreadable, reason}}}
    end
  end

  defp safe_decode(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:invalid_configuration, :not_an_object}}
      {:error, reason} -> {:error, {:invalid_configuration, {:invalid_json, reason}}}
    end
  end

  defp from_map(decoded) do
    fields = Enum.map(@enforce_keys, &Atom.to_string/1)

    case Enum.find(fields, fn field -> blank?(decoded[field]) end) do
      nil ->
        {:ok,
         %__MODULE__{
           control_plane_address: decoded["control_plane_address"],
           device_workspace_id: decoded["device_workspace_id"],
           worker_credential: decoded["worker_credential"],
           agent_adapter: decoded["agent_adapter"],
           agent_executable: decoded["agent_executable"],
           workspace_root: decoded["workspace_root"],
           project_id: decoded["project_id"],
           worker_id: decoded["worker_id"]
         }}

      missing_field ->
        {:error, {:invalid_configuration, {:missing_field, missing_field}}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp to_map(%__MODULE__{} = config) do
    %{
      "control_plane_address" => config.control_plane_address,
      "device_workspace_id" => config.device_workspace_id,
      "worker_credential" => config.worker_credential,
      "agent_adapter" => config.agent_adapter,
      "agent_executable" => config.agent_executable,
      "workspace_root" => config.workspace_root,
      "project_id" => config.project_id,
      "worker_id" => config.worker_id
    }
  end
end
