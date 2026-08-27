defmodule SddOrchestrator.Portability.HostedLocalRepositoryMachines do
  @moduledoc """
  Paired-machine selection for connecting a hosted local-repository project.

  The binding boundary requires an explicitly selected device workspace and
  worker, so a machine is never picked for the owner when there is more than one
  to pick from. When exactly one active paired worker exists the choice collapses
  to that worker, because presenting a one-item list asks a question with no
  alternative answer.

  `offer/2` describes what the page should present. `confirm/3` decides what is
  actually connected, and it re-reads the paired set at submit time: a machine
  paired between rendering and submitting must not be silently substituted for
  the one the owner saw. Having no paired worker is reported as
  `:no_worker_paired` — a distinct result carrying graphical install and pairing
  guidance, never a failed connection.

  Only the derived facts a picker needs leave this module: an opaque worker id
  and whether that machine is reachable right now. No device label, credential,
  path, or raw compatibility descriptor is exposed.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices.{LocalWorker, Pairing, PairingGuidance, WorkerDiscovery}

  @type machine :: %{worker_id: Ecto.UUID.t(), available?: boolean()}

  @type offer :: %{
          selection: :single | :explicit,
          machines: [machine()],
          preselected_worker_id: Ecto.UUID.t() | nil
        }

  @type step :: PairingGuidance.step()

  @type guidance :: PairingGuidance.guidance()

  @type confirm_error :: :no_worker_paired | :selection_required | :unauthorized_worker

  @doc """
  Describes the machines available for selection on the owner's device workspace.

  A single active worker collapses the choice; two or more require an explicit
  one. No device workspace at all is the same answer as no paired worker, because
  the owner's next step is identical.
  """
  @spec offer(DeviceWorkspace.t() | nil, keyword()) ::
          {:ok, offer()} | {:error, :no_worker_paired}
  def offer(device_workspace, opts \\ [])

  def offer(%DeviceWorkspace{id: device_workspace_id}, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Pairing.active_workers(device_workspace_id) do
      [] ->
        {:error, :no_worker_paired}

      [%LocalWorker{} = only] ->
        {:ok,
         %{
           selection: :single,
           machines: [machine(only, now)],
           preselected_worker_id: only.id
         }}

      workers ->
        {:ok,
         %{
           selection: :explicit,
           machines: Enum.map(workers, &machine(&1, now)),
           preselected_worker_id: nil
         }}
    end
  end

  def offer(nil, _opts), do: {:error, :no_worker_paired}

  @doc """
  Confirms the worker to connect against the paired set as it is at submit time.

  `worker_id` is the machine the owner explicitly chose, or `nil` when the page
  presented the collapsed single-machine case. A `nil` choice is honoured only
  while exactly one active worker still exists; if another was paired in the
  meantime the owner is asked to choose rather than being given a machine they
  never saw.
  """
  @spec confirm(DeviceWorkspace.t() | nil, Ecto.UUID.t() | nil, keyword()) ::
          {:ok, Ecto.UUID.t()} | {:error, confirm_error()}
  def confirm(device_workspace, worker_id, opts \\ [])

  def confirm(%DeviceWorkspace{id: device_workspace_id}, worker_id, _opts)
      when is_binary(worker_id) do
    device_workspace_id
    |> Pairing.active_workers()
    |> Enum.find(&(&1.id == worker_id))
    |> case do
      %LocalWorker{id: id} -> {:ok, id}
      nil -> {:error, :unauthorized_worker}
    end
  end

  def confirm(%DeviceWorkspace{id: device_workspace_id}, nil, _opts) do
    case Pairing.active_workers(device_workspace_id) do
      [] -> {:error, :no_worker_paired}
      [%LocalWorker{id: id}] -> {:ok, id}
      _several -> {:error, :selection_required}
    end
  end

  def confirm(nil, _worker_id, _opts), do: {:error, :no_worker_paired}

  @doc """
  Graphical steps for an owner with no paired worker on this machine.

  The wording is owned by `PairingGuidance`, so every surface that asks for a
  pairing code says the same thing. Nothing is restated here.

  This page hands the owner off without a pairing field of its own, so it renders
  only the steps that obtain the code and never `PairingGuidance.paste_step/0`.
  """
  @spec guidance() :: guidance()
  defdelegate guidance(), to: PairingGuidance

  defp machine(%LocalWorker{} = worker, now) do
    %{
      worker_id: worker.id,
      available?: WorkerDiscovery.status([worker], now: now) == :detected
    }
  end
end
