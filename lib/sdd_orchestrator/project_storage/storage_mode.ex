defmodule SddOrchestrator.ProjectStorage.StorageMode do
  @moduledoc """
  The one authoritative project-data storage mode.

  Modes are persisted as strings because they participate in destination
  constraints with `Workspace.kind`. Domain callers may pass the corresponding
  atoms at adapter boundaries.
  """

  @type t :: String.t()
  @type atom_mode :: :hosted | :device

  @values ["hosted", "device"]

  @doc "All persisted storage modes."
  @spec values() :: [t()]
  def values, do: @values

  @doc "Normalizes an accepted atom or string to its persisted value."
  @spec cast(t() | atom_mode() | term()) :: {:ok, t()} | :error
  def cast("hosted"), do: {:ok, "hosted"}
  def cast("device"), do: {:ok, "device"}
  def cast(:hosted), do: {:ok, "hosted"}
  def cast(:device), do: {:ok, "device"}
  def cast(_value), do: :error

  @doc "Returns whether a project mode matches its owning workspace kind."
  @spec compatible?(term(), term()) :: boolean()
  def compatible?(mode, workspace_kind) do
    with {:ok, normalized_mode} <- cast(mode),
         {:ok, normalized_kind} <- cast(workspace_kind) do
      normalized_mode == normalized_kind
    else
      :error -> false
    end
  end

  @doc "Converts a persisted mode into the atom used by adapter callbacks."
  @spec to_atom(term()) :: {:ok, atom_mode()} | :error
  def to_atom(mode) do
    case cast(mode) do
      {:ok, "hosted"} -> {:ok, :hosted}
      {:ok, "device"} -> {:ok, :device}
      :error -> :error
    end
  end
end
