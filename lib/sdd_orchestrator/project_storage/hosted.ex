defmodule SddOrchestrator.ProjectStorage.Hosted do
  @moduledoc """
  The hosted `ProjectStorage` adapter: "In my SDD Orchestrator account".

  Hosted storage is always available in this slice and initializes inside the
  project-registration `Ecto.Multi`, so it commits or rolls back atomically with
  the project. There is no external resource to release on abort — a failed
  transaction rolls back the inserted row — so `abort/2` is a no-op.

  This is the only storage adapter Slice 01 implements. The device adapter and its
  production preparation are owned by `specs/02-local-project-onboarding/`; the
  registration transaction validates the device readiness receipt directly (see
  `SddOrchestrator.Projects`).
  """
  @behaviour SddOrchestrator.ProjectStorage

  alias Ecto.Multi
  alias SddOrchestrator.Projects.ProjectOnboardingAttempt
  alias SddOrchestrator.ProjectStorage.HostedProjectStorage

  @impl true
  def availability(%ProjectOnboardingAttempt{} = _attempt, _opts), do: :available

  @doc """
  Adds hosted-storage initialization to the project-registration multi.

  The `:project` step must already be part of the multi; this reads the inserted
  project to derive the storage root and insert the hosted storage row under the
  same transaction.
  """
  @impl true
  def prepare(%Multi{} = multi, %ProjectOnboardingAttempt{} = _attempt, _opts) do
    multi =
      Multi.insert(multi, :storage, fn %{project: project} ->
        HostedProjectStorage.create_changeset(%HostedProjectStorage{}, %{
          project_id: project.id,
          root: root_for(project),
          state: "ready"
        })
      end)

    {:ok, multi}
  end

  @impl true
  def abort(_context, _opts), do: :ok

  # An internal, stable storage key. Not a filesystem path or repository location.
  defp root_for(%{id: id}), do: "hosted/" <> id
end
