defmodule SddOrchestrator.Delivery.ExecutionProfile do
  @moduledoc """
  The approved execution contract every continued attempt is bound to.

  A continuation is the same run carrying on, so it has to execute the same
  contract the repository's owner approved for the project, not something a
  caller, a worker, or a configuration file supplied. Reading it in one place
  is what keeps an answered question, a retry, a reconciliation, and a review
  rejection from drifting apart into four slightly different manifests.

  A project whose owner has approved no profile has no contract to continue
  against, which is a refusal rather than an empty set of checks.
  """

  alias SddOrchestrator.Accounts.{DeviceWorkspace, PersonalWorkspace}
  alias SddOrchestrator.Delivery.DeliveryStore
  alias SddOrchestrator.RepositoryAssessments

  @type authority :: DeliveryStore.authority()

  @doc """
  The manifest fields one project's approved profile decides.

  Returned as the manifest's own string-keyed values so a caller merges them
  into the map it is already building rather than restating each name.
  """
  @spec manifest_fields(authority(), Ecto.UUID.t()) ::
          {:ok, map()} | {:error, :no_execution_profile}
  def manifest_fields(authority, project_id) do
    with {:ok, profile} <-
           RepositoryAssessments.approved_profile(viewer(authority), project_id) do
      {:ok,
       %{
         "repository_base_revision" => profile.base_revision,
         "required_checks" => required_checks(profile),
         "repository_root" => profile.root,
         "commands" => profile.commands,
         "allowed_scope" => profile.allowed_scope
       }}
    end
  end

  # The profile store answers the owner's approved versions, so the viewer is
  # built from the project's storage authority rather than from whoever caused
  # the continuation. Their right to cause it was already checked.
  defp viewer(%PersonalWorkspace{account_id: account_id}), do: {:hosted, account_id}
  defp viewer(%DeviceWorkspace{} = workspace), do: {:device, workspace}

  # A profile names its required checks by the command that runs them, and
  # those names are already unique, so the manifest's named-check contract
  # carries the command as both the name and the command.
  defp required_checks(profile) do
    Enum.map(profile.required_checks, &%{"name" => &1, "command" => &1})
  end
end
