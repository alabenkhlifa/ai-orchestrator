defmodule SddOrchestrator.RepositoryAssessments.ProfileStore do
  @moduledoc """
  Append-only authoritative storage contract for approved profile versions.

  Dispatch follows the project's established storage authority. A device
  project never falls back to PostgreSQL.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryExecutionProfile,
    RepositoryExecutionProfileProposal
  }

  alias SddOrchestrator.RepositoryAssessments.ProfileStore.{Device, Hosted}

  @type authority :: {:hosted, Ecto.UUID.t()} | {:device, DeviceWorkspace.t()}

  @callback append(
              authority(),
              RepositoryAssessment.t(),
              RepositoryExecutionProfileProposal.t(),
              Ecto.UUID.t(),
              DateTime.t()
            ) :: {:ok, RepositoryExecutionProfile.t()} | {:error, atom() | Ecto.Changeset.t()}

  @callback list(authority(), Ecto.UUID.t()) :: [RepositoryExecutionProfile.t()]
  @callback count(authority(), Ecto.UUID.t()) :: non_neg_integer()

  @spec append(
          authority(),
          RepositoryAssessment.t(),
          RepositoryExecutionProfileProposal.t(),
          Ecto.UUID.t(),
          DateTime.t()
        ) :: {:ok, RepositoryExecutionProfile.t()} | {:error, atom() | Ecto.Changeset.t()}
  def append({:hosted, _account_id} = authority, assessment, proposal, actor_ref, approved_at),
    do: Hosted.append(authority, assessment, proposal, actor_ref, approved_at)

  def append(
        {:device, %DeviceWorkspace{}} = authority,
        assessment,
        proposal,
        actor_ref,
        approved_at
      ),
      do: Device.append(authority, assessment, proposal, actor_ref, approved_at)

  def append(_authority, _assessment, _proposal, _actor_ref, _approved_at),
    do: {:error, :unsupported_authority}

  @spec list(authority(), Ecto.UUID.t()) :: [RepositoryExecutionProfile.t()]
  def list({:hosted, _account_id} = authority, project_id), do: Hosted.list(authority, project_id)

  def list({:device, %DeviceWorkspace{}} = authority, project_id),
    do: Device.list(authority, project_id)

  def list(_authority, _project_id), do: []

  @spec count(authority(), Ecto.UUID.t()) :: non_neg_integer()
  def count(authority, project_id), do: length(list(authority, project_id))
end
