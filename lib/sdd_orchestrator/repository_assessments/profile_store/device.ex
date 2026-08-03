defmodule SddOrchestrator.RepositoryAssessments.ProfileStore.Device do
  @moduledoc "Device-local append-only profile-store adapter."

  @behaviour SddOrchestrator.RepositoryAssessments.ProfileStore

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal
  }

  @impl true
  def append(
        {:device, %DeviceWorkspace{} = authority},
        %RepositoryAssessment{} = assessment,
        %RepositoryExecutionProfileProposal{} = proposal,
        actor_ref,
        %DateTime{} = approved_at
      ) do
    with true <- actor_ref == authority.id,
         {:ok, project} <- authorize(authority, assessment.project_id),
         true <- exact_binding?(project, assessment),
         true <- RepositoryAssessment.strict?(assessment) and assessment.state == "completed",
         true <- RepositoryExecutionProfileProposal.matches_assessment?(proposal, assessment),
         {:ok, value} <-
           Devices.append_repository_execution_profile(
             assessment.project_id,
             assessment.id,
             RepositoryExecutionProfileProposal.to_value(proposal),
             actor_ref,
             DateTime.to_iso8601(DateTime.truncate(approved_at, :microsecond))
           ) do
      RepositoryExecutionProfile.from_value(value)
    else
      false -> {:error, :stale_assessment}
      {:error, :not_found} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  def append(_authority, _assessment, _proposal, _actor_ref, _approved_at),
    do: {:error, :unsupported_authority}

  @impl true
  def list({:device, %DeviceWorkspace{} = authority}, project_id) do
    with {:ok, _project} <- authorize(authority, project_id) do
      project_id
      |> Devices.list_repository_execution_profiles()
      |> Enum.reduce_while([], fn value, profiles ->
        case RepositoryExecutionProfile.from_value(value) do
          {:ok, profile} -> {:cont, [profile | profiles]}
          {:error, :invalid_profile} -> {:halt, []}
        end
      end)
      |> Enum.sort_by(& &1.version)
    else
      _missing -> []
    end
  end

  def list(_authority, _project_id), do: []

  @impl true
  def count(authority, project_id), do: length(list(authority, project_id))

  defp authorize(%DeviceWorkspace{id: authority_id} = authority, project_id) do
    with {:ok, %DeviceWorkspace{id: ^authority_id}} <- Devices.get_workspace(),
         {:ok, %{storage_mode: "device", status: "connected"} = project} <-
           Devices.get_project(project_id),
         true <- DeviceWorkspace.owns_project?(authority, project) do
      {:ok, project}
    else
      _missing -> {:error, :not_found}
    end
  end

  defp exact_binding?(project, assessment) do
    project.repository_provider == assessment.repository_provider and
      project.repository_id == assessment.repository_id
  end
end
