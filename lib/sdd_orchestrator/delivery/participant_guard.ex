defmodule SddOrchestrator.Delivery.ParticipantGuard do
  @moduledoc """
  The one fail-closed participation check every feature-delivery action uses.

  This module consumes `capability:project-participation-boundary` and adds
  nothing to it. It never mutates participation: it asks who the acting person
  currently is in one project and whether they may take one protected action,
  and it re-asks on every call, so a removal or leave takes effect immediately.

  Two disclosure rules hold on every path. A denied caller learns only that the
  action is unavailable — never whether the project exists, whether they were
  once a member, or which check failed. And a permitted caller receives project
  display names only; another participant's email address never reaches this
  slice.
  """

  alias SddOrchestrator.Participation.Boundary

  @protected_actions ~w(
    view_board
    view_feature
    comment
    assign
    start_run
    answer_question
    retry_run
    cancel_run
    review
    read_evidence
  )a

  @action_capabilities %{
    view_board: :read_feature_content,
    view_feature: :read_feature_content,
    comment: :comment,
    assign: :edit_feature_content,
    start_run: :edit_feature_content,
    answer_question: :edit_specifications,
    retry_run: :edit_feature_content,
    cancel_run: :edit_feature_content,
    review: :edit_feature_content,
    read_evidence: :read_run_evidence
  }

  @type actor :: %{
          optional(:account_id) => Ecto.UUID.t() | nil,
          optional(:hosted_identity_id) => Ecto.UUID.t() | nil
        }

  @type member :: Boundary.member()

  @spec protected_actions() :: [atom()]
  def protected_actions, do: @protected_actions

  @doc """
  Resolves the acting person as a current member of one project.

  Every unauthorized case returns the same result, so a caller cannot learn
  whether the project exists or whether they used to belong to it.
  """
  @spec authorize(Ecto.UUID.t(), actor()) :: {:ok, member()} | {:error, :unauthorized}
  def authorize(project_id, actor) do
    case Boundary.current_member(project_id, normalize(actor)) do
      {:ok, member} -> {:ok, member}
      {:error, :not_a_member} -> {:error, :unauthorized}
    end
  end

  @doc """
  Authorizes one protected feature-delivery action for the acting person.

  An unknown action name is denied rather than allowed by default.
  """
  @spec authorize_action(Ecto.UUID.t(), actor(), atom()) ::
          {:ok, member()} | {:error, :unauthorized}
  def authorize_action(project_id, actor, action) do
    with true <- action in @protected_actions,
         {:ok, member} <- authorize(project_id, actor),
         true <- Boundary.authorized?(project_id, normalize(actor), capability_for(action)) do
      {:ok, member}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists the project's current members for presentation.

  The result is empty for a project the acting person cannot read, which keeps
  membership and project existence equally undisclosed.
  """
  @spec current_members(Ecto.UUID.t(), actor()) :: [member()]
  def current_members(project_id, actor) do
    case authorize(project_id, actor) do
      {:ok, _member} -> Boundary.current_members(project_id)
      {:error, :unauthorized} -> []
    end
  end

  @doc """
  Returns the project's deterministic responsibility fallback: its owner.
  """
  @spec owner(Ecto.UUID.t()) :: {:ok, member()} | {:error, :unauthorized}
  def owner(project_id) do
    case Boundary.owner(project_id) do
      {:ok, owner} -> {:ok, owner}
      {:error, :unavailable} -> {:error, :unauthorized}
    end
  end

  @doc "The project display name to render for one member, never their email."
  @spec display_name(member()) :: String.t()
  def display_name(%{display_name: display_name}), do: display_name

  defp capability_for(action), do: Map.fetch!(@action_capabilities, action)

  defp normalize(actor) when is_map(actor) do
    %{
      account_id: Map.get(actor, :account_id),
      hosted_identity_id: Map.get(actor, :hosted_identity_id)
    }
  end

  defp normalize(_actor), do: %{account_id: nil, hosted_identity_id: nil}
end
