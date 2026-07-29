defmodule SddOrchestrator.Delivery.QuestionRouting do
  @moduledoc """
  Who one blocking question is waiting on.

  A blocked run stopped on a decision it must not make alone, so the product
  has to name the person who can make it. That person is the feature's current
  assignee when `Assigned` has a value, otherwise its current creator, and the
  immutable project owner when neither of them is still authorized.

  That resolution is not repeated here. `Assignment.responsible/2` already
  answers it once for the whole slice, and routing asks it again rather than
  keeping a second copy that could drift away from the field the screen shows.
  What this module adds is the question-shaped view of the answer: the
  responder set to tag, whether the person reading the screen is in it, and
  whether the person pressing answer may.

  Routing fails closed. A departed assignee and a departed creator both mean
  the owner, never the former participant, and responsibility is re-derived on
  every call rather than trusted from whenever the question was asked. A caller
  who is not the responder is told only that the action is unavailable — never
  who the responder is. Every identity leaves here as a project display name or
  an account reference; no participant email reaches a return value, an
  activity payload, or the screen.
  """

  alias SddOrchestrator.Delivery.{Assignment, Feature, ParticipantGuard}

  @type actor :: ParticipantGuard.actor()
  @type member :: ParticipantGuard.member()

  @type error :: :unauthorized

  @doc """
  The people one open question is currently waiting on.

  A set rather than a single member, because a caller that notifies or renders
  should not have to care whether responsibility resolved to one person or to a
  later handoff's several. A feature from another project answers with none of
  them, which keeps an out-of-scope read from disclosing membership.
  """
  @spec responders(Ecto.UUID.t(), Feature.t()) :: [member()]
  def responders(project_id, %Feature{} = feature) do
    with :ok <- scoped?(project_id, feature),
         {:ok, member} <- Assignment.responsible(project_id, feature) do
      [member]
    else
      _unavailable -> []
    end
  end

  @doc """
  Reports whether the acting person is one of the current responders.

  Asked fresh every time, so someone tagged this morning who left at noon is
  not tagged now.
  """
  @spec tagged?(Ecto.UUID.t(), Feature.t(), actor()) :: boolean()
  def tagged?(project_id, %Feature{} = feature, actor) do
    case ParticipantGuard.authorize(project_id, actor) do
      {:ok, member} -> responder?(project_id, feature, member)
      {:error, :unauthorized} -> false
    end
  end

  @doc """
  Authorizes the acting person to answer this feature's open question.

  Being a current participant is not enough: answering commits a product
  decision to the shared specification, so it belongs to the person the
  question is actually waiting on. Every refusal is the same `:unauthorized`,
  so a participant who is denied cannot use the denial to work out who the
  responder is.
  """
  @spec authorize_answer(Ecto.UUID.t(), actor(), Feature.t()) ::
          {:ok, member()} | {:error, error()}
  def authorize_answer(project_id, actor, %Feature{} = feature) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :answer_question),
         true <- responder?(project_id, feature, member) do
      {:ok, member}
    else
      _denied -> {:error, :unauthorized}
    end
  end

  @doc """
  The project display name to show beside an open question.

  `nil` when responsibility cannot resolve at all, which leaves the caller to
  render its own neutral text rather than an invented name or an address.
  """
  @spec responder_label(Ecto.UUID.t(), Feature.t()) :: String.t() | nil
  def responder_label(project_id, %Feature{} = feature) do
    case responders(project_id, feature) do
      [member | _rest] -> ParticipantGuard.display_name(member)
      [] -> nil
    end
  end

  @doc """
  The activity tag recording who a question is waiting on when it is asked.

  An account reference, never a name: display names resolve at render time from
  current participation, exactly as assignment history does, so a later rename
  or departure is reflected instead of frozen into the record.
  """
  @spec tag(Ecto.UUID.t(), Feature.t()) :: map()
  def tag(project_id, %Feature{} = feature) do
    case responders(project_id, feature) do
      [%{account_id: account_id} | _rest] -> %{"responder_account_id" => account_id}
      [] -> %{}
    end
  end

  defp responder?(project_id, feature, %{account_id: account_id}) do
    project_id
    |> responders(feature)
    |> Enum.any?(&(&1.account_id == account_id))
  end

  defp scoped?(project_id, %Feature{project_id: project_id}), do: :ok
  defp scoped?(_project_id, %Feature{}), do: {:error, :unauthorized}
end
