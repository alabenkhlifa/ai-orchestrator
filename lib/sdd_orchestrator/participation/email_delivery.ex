defmodule SddOrchestrator.Participation.EmailDelivery do
  @moduledoc """
  Sends the approved participation emails through the shared delivery boundary.

  The transport module and provider configuration are shared with passwordless
  access, but the builders, credentials, and diagnostics are separate: a
  participation delivery record never holds an invitation credential, a message
  body, or a provider response, and a failure logs only its event and a short
  code.

  Delivery is attempted after the authoritative state commits. One event,
  subject, and subject version records one outcome, so a retried lifecycle
  action updates that outcome instead of creating a second record.
  """

  require Logger

  alias SddOrchestrator.Participation.{ParticipationEmail, ParticipationEmailDelivery}
  alias SddOrchestrator.Repo

  @default_transport SddOrchestrator.HostedAccess.SwooshDelivery

  @type outcome :: {:ok, ParticipationEmailDelivery.t()} | {:error, atom()}

  @doc """
  Builds and sends one participation email, recording its minimized outcome.

  The result is `{:ok, delivery}` for a sent message and `{:error, reason}`
  when the message cannot be built; a provider failure still returns
  `{:ok, delivery}` with a `failed` status so the caller can surface and retry
  it without losing the committed lifecycle change.
  """
  @spec deliver(atom(), map()) :: outcome()
  def deliver(event, %{subject_ref: subject_ref} = context) do
    with {:ok, email} <- ParticipationEmail.build(event, context) do
      record =
        upsert(%{
          event_type: Atom.to_string(event),
          subject_ref: subject_ref,
          event_version: Map.get(context, :event_version, 1),
          recipient_address: context.recipient,
          status: "pending",
          failure_code: nil,
          delivered_at: nil,
          attempted_at: now()
        })

      send_and_record(record, email, event)
    end
  end

  def deliver(_event, _context), do: {:error, :invalid_context}

  @doc "Returns the recorded delivery outcome for one event and subject version."
  @spec result(atom(), Ecto.UUID.t(), pos_integer()) :: ParticipationEmailDelivery.t() | nil
  def result(event, subject_ref, event_version \\ 1) do
    Repo.get_by(ParticipationEmailDelivery,
      event_type: Atom.to_string(event),
      subject_ref: subject_ref,
      event_version: event_version
    )
  end

  @doc "The configured transport module, shared with the passwordless boundary."
  @spec transport() :: module()
  def transport do
    Application.get_env(:sdd_orchestrator, :participation_email_delivery, @default_transport)
  end

  defp send_and_record(record, email, event) do
    case safe_deliver(email) do
      {:ok, _result} ->
        {:ok, record_result(record, "sent", nil)}

      {:error, reason} ->
        Logger.warning("participation_email_delivery_failed event=#{event} code=#{reason}")
        {:ok, record_result(record, "failed", reason)}
    end
  end

  defp safe_deliver(email) do
    case transport().deliver(email) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :delivery_failed}
      _other -> {:error, :delivery_failed}
    end
  rescue
    _error -> {:error, :provider_unavailable}
  catch
    _kind, _reason -> {:error, :provider_unavailable}
  end

  defp upsert(attrs) do
    existing =
      Repo.get_by(ParticipationEmailDelivery,
        event_type: attrs.event_type,
        subject_ref: attrs.subject_ref,
        event_version: attrs.event_version
      )

    (existing || %ParticipationEmailDelivery{})
    |> ParticipationEmailDelivery.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  defp record_result(record, status, failure_code) do
    record
    |> ParticipationEmailDelivery.changeset(%{
      status: status,
      failure_code: failure_code && Atom.to_string(failure_code),
      delivered_at: (status == "sent" && now()) || nil
    })
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
