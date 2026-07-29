defmodule SddOrchestrator.Participation.ParticipationEmail do
  @moduledoc """
  Builds the four approved participation emails.

  Each message carries only the project display name, what happened or is
  required, and one safe product link. Specifications, feature content,
  comments, evidence, repository details, other participants, and account
  existence signals never appear, and the same wording is used whether or not
  the address already has an account.
  """

  import Swoosh.Email

  @events ~w(invitation invitation_resent invitation_canceled participant_removed)a

  @type context :: %{
          required(:recipient) => String.t(),
          required(:project_label) => String.t(),
          optional(:url) => String.t(),
          optional(atom()) => term()
        }

  @spec events() :: [atom()]
  def events, do: @events

  @spec build(atom(), context()) :: {:ok, Swoosh.Email.t()} | {:error, atom()}
  def build(event, context) when event in @events do
    with :ok <- validate_context(event, context) do
      {:ok,
       new()
       |> to(context.recipient)
       |> from({"SDD Orchestrator", config(:from_email)})
       |> subject(subject_line(event, context))
       |> text_body(body(event, context))}
    end
  end

  def build(_event, _context), do: {:error, :unsupported_event}

  @doc "Builds the invited person's acceptance link for one invitation credential."
  @spec invitation_url(Ecto.UUID.t(), String.t()) :: String.t()
  def invitation_url(invitation_id, raw_token) do
    query = URI.encode_query(%{"token" => raw_token})
    "#{config(:app_origin)}/projects/invitations/#{invitation_id}/accept?#{query}"
  end

  defp validate_context(event, %{recipient: recipient, project_label: label} = context)
       when is_binary(recipient) and is_binary(label) do
    if event in ~w(invitation invitation_resent)a and not is_binary(context[:url]) do
      {:error, :missing_invitation_url}
    else
      :ok
    end
  end

  defp validate_context(_event, _context), do: {:error, :invalid_context}

  defp subject_line(:invitation, context), do: "You're invited to #{context.project_label}"

  defp subject_line(:invitation_resent, context),
    do: "Your new invitation link for #{context.project_label}"

  defp subject_line(:invitation_canceled, context),
    do: "The invitation to #{context.project_label} was canceled"

  defp subject_line(:participant_removed, context),
    do: "You no longer have access to #{context.project_label}"

  defp body(:invitation, context) do
    """
    You have been invited to work on the project "#{context.project_label}".

    Open this link to confirm your email address and decide whether to join:

    #{context.url}

    The link expires in 7 days and can be used once. If you were not expecting
    this invitation, you can ignore this email.
    """
  end

  defp body(:invitation_resent, context) do
    """
    Here is a new invitation link for the project "#{context.project_label}".

    #{context.url}

    Any earlier link no longer works. This link expires in 7 days and can be
    used once. If you were not expecting this invitation, you can ignore this
    email.
    """
  end

  defp body(:invitation_canceled, context) do
    """
    The invitation to work on the project "#{context.project_label}" was
    canceled, and its link no longer works.

    No action is needed. If you still expect to join, ask the person who
    invited you to send a new invitation.
    """
  end

  defp body(:participant_removed, context) do
    """
    You no longer have access to the project "#{context.project_label}".

    Your account is unchanged and you keep access to your other projects. If
    you think this was a mistake, contact the person who runs that project.
    """
  end

  defp config(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(key)
  end
end
