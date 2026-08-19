defmodule SddOrchestrator.ProjectAssistant.Guard do
  @moduledoc """
  The fail-closed hosted-participation check every project-assistant action
  on a hosted project uses.

  This mirrors `SddOrchestrator.Delivery.ParticipantGuard`'s contract
  exactly — it consumes `capability:project-participation-boundary` and adds
  nothing to it, never mutates participation, and re-asks on every call, so a
  removal or leave takes effect immediately. A denied caller learns only that
  the action is unavailable — never whether the project exists, whether they
  were once a member, or which check failed.

  This guard covers hosted projects only. `Participation.owner/1` is explicit
  that "a device-authoritative project has no hosted owner and cannot
  participate in hosted collaboration" — a device project never has an owner
  or participant row for `Participation.Boundary.current_member/2` to find,
  so it always denies. `ProjectAssistantStore.Device` therefore authorizes
  the acting device workspace directly instead of routing through this
  module, the same split `SpecificationStore.Hosted` and
  `SpecificationStore.Device` already draw for specification authorization.

  Task 1 owned three actions: `open_panel`, `read_history`, and `delete`.
  Task 2 adds `confirm_boundary` (reviewing and confirming the disclosed
  processing summary) and `ask` (submitting a question, layered under its
  own processing-boundary confirmation gate in
  `SddOrchestrator.ProjectAssistant.BoundaryGate`). Task 7 adds
  `open_citation` — the same authorization a stored citation must pass
  again whenever it is read after creation (design.md: "A stored citation
  does not preserve access after participation or source permission
  ends") — without changing this contract: it is one more name in the
  closed list, checked exactly like every other action.
  """

  alias SddOrchestrator.Participation.Boundary

  @protected_actions ~w(open_panel read_history delete confirm_boundary ask open_citation)a

  @type actor :: %{
          optional(:account_id) => Ecto.UUID.t() | nil,
          optional(:hosted_identity_id) => Ecto.UUID.t() | nil
        }

  @type member :: Boundary.member()

  @spec protected_actions() :: [atom()]
  def protected_actions, do: @protected_actions

  @doc """
  Authorizes one protected project-assistant action for the acting person on
  a hosted project.

  An unknown action name is denied rather than allowed by default, and every
  denial — invalid action, stale identity, removed participant, absent
  identity, or cross-project identity — returns the same result.
  """
  @spec authorize_action(Ecto.UUID.t(), actor(), atom()) ::
          {:ok, member()} | {:error, :unauthorized}
  def authorize_action(project_id, actor, action) do
    with true <- action in @protected_actions,
         {:ok, member} <- Boundary.current_member(project_id, normalize(actor)) do
      {:ok, member}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  defp normalize(actor) when is_map(actor) do
    %{
      account_id: Map.get(actor, :account_id),
      hosted_identity_id: Map.get(actor, :hosted_identity_id)
    }
  end

  defp normalize(_actor), do: %{account_id: nil, hosted_identity_id: nil}
end
