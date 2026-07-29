defmodule SddOrchestrator.Portability.DeviceRestore do
  @moduledoc """
  Atomic device-authoritative adapter for one validated project backup.

  The project, canonical repository identity, minimal provenance, and current
  specifications are contributed to one worker-owned `DeviceTransaction`.
  Nothing device-authoritative is inserted into hosted project, specification,
  or provenance tables.
  """

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.{DeviceProject, DeviceTransaction}

  alias SddOrchestrator.Portability.{
    DeviceRestoreContribution,
    PackageProvenance,
    PackageValidator,
    ProjectPackage,
    RestoreDecision,
    RestorePackage,
    SecurityLog
  }

  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Specifications.SpecificationRestore
  alias SddOrchestrator.SpecificationStore

  @type success :: %{
          project: DeviceProject.t(),
          provenance: PackageProvenance.t(),
          specifications: list(),
          replay?: boolean()
        }

  @spec restore(DeviceWorkspace.t(), ProjectPackage.t(), RestoreDecision.t(), keyword()) ::
          {:ok, success()}
          | {:error,
             :acknowledgement_lost
             | :destination_unavailable
             | :identity_conflict
             | :invalid_restore
             | :name_conflict
             | :not_found
             | :repository_conflict
             | :specification_conflict
             | :injected_failure
             | term()}
  def restore(
        %DeviceWorkspace{} = authority,
        %ProjectPackage{} = package,
        %RestoreDecision{} = decision,
        opts
      ) do
    result =
      with {:ok, %DeviceWorkspace{id: authority_id}} <- Devices.get_workspace(),
           true <- authority_id == authority.id,
           true <- Devices.worker_status(authority.id) == :detected,
           :ok <- PackageValidator.validate(package),
           {:ok, idempotency_key} <-
             SpecificationRestore.validate_idempotency_key(Keyword.get(opts, :idempotency_key)),
           {:ok, specification_values} <- RestorePackage.specification_values(package),
           :ok <- RestorePackage.decision_matches(decision, package),
           {:ok, project} <- device_project(authority, decision, opts),
           {:ok, provenance} <- provenance(package, project, opts),
           {:ok, transaction} <- DeviceTransaction.new(project.id),
           {:ok, transaction} <-
             DeviceTransaction.put(
               transaction,
               :project_restore,
               %DeviceRestoreContribution{
                 idempotency_key: idempotency_key,
                 project: project,
                 provenance: provenance,
                 fault: project_fault(Keyword.get(opts, :fault))
               }
             ),
           {:ok, transaction} <-
             SpecificationStore.prepare_restore(
               authority,
               transaction,
               specification_values,
               idempotency_key: idempotency_key,
               fault: specification_fault(Keyword.get(opts, :fault))
             ),
           {:ok, changes} <- Devices.commit_transaction(transaction) do
        restore_result(changes, Keyword.get(opts, :fault))
      else
        false -> {:error, :destination_unavailable}
        {:error, _reason} = error -> error
      end

    SecurityLog.audit(result, :restore_commit)
  end

  def restore(_authority, _package, _decision, _opts) do
    SecurityLog.audit({:error, :invalid_restore}, :restore_commit)
  end

  defp device_project(authority, decision, opts) do
    changeset = Project.rename_changeset(%Project{}, %{name: decision.display_name})

    case Ecto.Changeset.apply_action(changeset, :validate) do
      {:ok, validated} ->
        inserted_at = Keyword.get(opts, :restored_at, now())

        {:ok,
         %DeviceProject{
           id: decision.project_id,
           workspace_id: authority.id,
           name: validated.name,
           name_key: validated.name_key,
           repository_provider: decision.repository_provider,
           repository_id: decision.repository_id,
           repository_fingerprint:
             if(decision.repository_provider == "local", do: decision.repository_id),
           status: "disconnected",
           storage_mode: "device",
           idempotency_key: nil,
           inserted_at: inserted_at
         }}

      {:error, _changeset} ->
        {:error, :invalid_restore}
    end
  end

  defp provenance(package, project, opts) do
    %PackageProvenance{}
    |> PackageProvenance.create_changeset(%{
      project_id: project.id,
      payload_schema_version: package.payload_schema_version,
      restored_at: Keyword.get(opts, :restored_at, now())
    })
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, provenance} -> {:ok, provenance}
      {:error, _changeset} -> {:error, :invalid_restore}
    end
  end

  defp project_fault(fault) when fault in [:after_project, :after_provenance], do: fault
  defp project_fault(_fault), do: nil

  defp specification_fault(:after_specification), do: :after_specification
  defp specification_fault(_fault), do: nil

  defp restore_result(_changes, :after_commit), do: {:error, :acknowledgement_lost}

  defp restore_result(
         %{
           project_restore: %{
             project: project,
             provenance: provenance,
             replay?: replay?
           },
           specification_restore: specifications
         },
         _fault
       ) do
    {:ok,
     %{
       project: project,
       provenance: provenance,
       specifications: specifications,
       replay?: replay?
     }}
  end

  defp restore_result(_changes, _fault), do: {:error, :invalid_restore}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
