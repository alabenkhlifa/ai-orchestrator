defmodule SddOrchestrator.Specifications.SpecificationAuthorizationPolicy do
  @moduledoc """
  Additive hosted authorization contract for later project participation.

  A policy decides only whether its caller may use the named project. The
  specification boundary still loads the persisted hosted project and preserves
  its existing project, specification, and revision identities.
  """

  @callback authorize_project(authority :: term(), project_id :: String.t()) ::
              :ok | {:error, :not_found}
end
