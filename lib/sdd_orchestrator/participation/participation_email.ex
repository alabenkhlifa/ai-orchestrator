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
  @context_fields %{
    invitation: [:recipient, :project_label, :url],
    invitation_resent: [:recipient, :project_label, :url],
    invitation_canceled: [:recipient, :project_label],
    participant_removed: [:recipient, :project_label]
  }

  @type context :: %{
          required(:recipient) => String.t(),
          required(:project_label) => String.t(),
          optional(:url) => String.t()
        }

  @spec events() :: [atom()]
  def events, do: @events

  @doc "The exact template context approved for one participation email."
  @spec context_fields(atom()) :: [atom()]
  def context_fields(event), do: Map.get(@context_fields, event, [])

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
    cond do
      invitation_event?(event) and not is_binary(context[:url]) ->
        {:error, :missing_invitation_url}

      Enum.sort(Map.keys(context)) != Enum.sort(context_fields(event)) ->
        {:error, :unapproved_context}

      invitation_event?(event) and not safe_invitation_url?(context.url) ->
        {:error, :unsafe_invitation_url}

      true ->
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

  defp invitation_event?(event), do: event in ~w(invitation invitation_resent)a

  defp safe_invitation_url?(url) do
    origin = URI.parse(config(:app_origin))
    parsed = URI.parse(url)

    parsed.scheme in ~w(http https) and
      parsed.scheme == origin.scheme and
      parsed.host == origin.host and
      parsed.port == origin.port and
      is_nil(parsed.userinfo) and
      is_nil(parsed.fragment) and
      invitation_path?(parsed.path) and
      single_token_query?(parsed.query)
  end

  defp invitation_path?(path) do
    case String.split(path || "", "/", trim: true) do
      ["projects", "invitations", invitation_id, "accept"] ->
        match?({:ok, _uuid}, Ecto.UUID.cast(invitation_id))

      _other ->
        false
    end
  end

  defp single_token_query?(query) when is_binary(query) do
    case Enum.to_list(URI.query_decoder(query)) do
      [{"token", token}] -> token != ""
      _other -> false
    end
  rescue
    ArgumentError -> false
  end

  defp single_token_query?(_query), do: false

  defp config(key) do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(key)
  end
end
