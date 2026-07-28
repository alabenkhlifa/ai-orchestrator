defmodule SddOrchestrator.Devices.DeviceTransaction do
  @moduledoc """
  Opaque caller-owned transaction plan for one device-authoritative project.

  Domain capabilities add typed contributions to this value. The configured
  device worker commits supported contributions under its single serialized
  persistence boundary; it never sends device-authoritative content to hosted
  persistence.
  """

  @enforce_keys [:project_id]
  defstruct [:project_id, contributions: %{}]

  @type t :: %__MODULE__{
          project_id: Ecto.UUID.t(),
          contributions: %{optional(atom()) => term()}
        }

  @spec new(String.t()) :: {:ok, t()} | {:error, :invalid_project}
  def new(project_id) do
    case Ecto.UUID.cast(project_id) do
      {:ok, id} -> {:ok, %__MODULE__{project_id: id}}
      :error -> {:error, :invalid_project}
    end
  end

  @spec put(t(), atom(), term()) :: {:ok, t()} | {:error, :restore_conflict}
  def put(%__MODULE__{} = transaction, name, contribution) when is_atom(name) do
    case Map.fetch(transaction.contributions, name) do
      :error ->
        {:ok,
         %{transaction | contributions: Map.put(transaction.contributions, name, contribution)}}

      {:ok, ^contribution} ->
        {:ok, transaction}

      {:ok, _other} ->
        {:error, :restore_conflict}
    end
  end
end
