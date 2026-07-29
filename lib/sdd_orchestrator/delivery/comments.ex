defmodule SddOrchestrator.Delivery.Comments do
  @moduledoc """
  Participant comments on one feature.

  A comment is not a separate record: it is one `ActivityEntry` of type
  `comment`, appended in project order alongside agent progress, questions,
  answers, and evidence. Keeping them in one ordered history is the point —
  a reviewer reads what happened and what people said about it as a single
  story rather than reconciling two timelines.

  A comment is explanatory only. Nothing here can satisfy a required check or
  move a feature between columns; agent prose and participant prose have
  exactly the same standing as evidence, which is none.
  """

  alias SddOrchestrator.Delivery.{Activity, ActivityEntry, Features, ParticipantGuard}

  @max_body_bytes 4_000

  # A comment is free text from a person, so it is the one payload most likely
  # to carry a pasted token or address. Both are refused rather than stored and
  # redacted later.
  @secret_shapes [
    ~r/\bsk-[A-Za-z0-9]{16,}/,
    ~r/\bghp_[A-Za-z0-9]{20,}/,
    ~r/\bgithub_pat_[A-Za-z0-9_]{20,}/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/\bAKIA[0-9A-Z]{16}\b/
  ]

  @email_shape ~r/[\w.+-]+@[\w-]+\.[\w.-]+/

  @type actor :: ParticipantGuard.actor()

  @type error ::
          :unauthorized
          | :not_found
          | :empty_comment
          | :comment_too_long
          | :redacted_content
          | :duplicate_comment

  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc """
  Adds one comment to a feature's activity as the acting current participant.

  Re-submitting identical text as the last comment on the same feature is
  treated as a duplicate submission rather than a second comment, which is what
  a double-clicked button and a replayed form produce.
  """
  @spec add(Ecto.UUID.t(), actor(), Ecto.UUID.t(), String.t()) ::
          {:ok, ActivityEntry.t()} | {:error, error()}
  def add(project_id, actor, feature_id, body) do
    with {:ok, member} <- ParticipantGuard.authorize_action(project_id, actor, :comment),
         {:ok, feature} <- Features.fetch(project_id, actor, feature_id),
         {:ok, text} <- validate(body),
         :ok <- reject_duplicate(project_id, feature.id, member, text) do
      Activity.append(%{
        project_id: project_id,
        feature_id: feature.id,
        actor_kind: "participant",
        actor_account_id: member.account_id,
        type: "comment",
        payload: %{"body" => text}
      })
      |> case do
        {:ok, entry} -> {:ok, entry}
        {:error, _changeset} -> {:error, :duplicate_comment}
      end
    end
  end

  @doc "Lists a feature's comments in project order for an authorized member."
  @spec list(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, [ActivityEntry.t()]} | {:error, :unauthorized}
  def list(project_id, actor, feature_id) do
    with {:ok, entries} <-
           Activity.list(project_id, actor, feature_id, limit: Activity.max_limit()) do
      {:ok, Enum.filter(entries, &(&1.type == "comment"))}
    end
  end

  defp validate(body) when is_binary(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" -> {:error, :empty_comment}
      byte_size(trimmed) > @max_body_bytes -> {:error, :comment_too_long}
      redacted?(trimmed) -> {:error, :redacted_content}
      true -> {:ok, trimmed}
    end
  end

  defp validate(_body), do: {:error, :empty_comment}

  defp redacted?(text) do
    Enum.any?(@secret_shapes, &Regex.match?(&1, text)) or Regex.match?(@email_shape, text)
  end

  # Only the immediately preceding comment is compared. An intentional repeat
  # later in a conversation is a real comment; the same text twice in a row is
  # a resubmission.
  defp reject_duplicate(project_id, feature_id, member, text) do
    project_id
    |> last_comment(feature_id)
    |> case do
      %ActivityEntry{actor_account_id: account_id, payload: %{"body" => ^text}}
      when account_id == member.account_id ->
        {:error, :duplicate_comment}

      _other ->
        :ok
    end
  end

  defp last_comment(project_id, feature_id) do
    project_id
    |> Activity.list(owner_actor(project_id), feature_id, limit: Activity.max_limit())
    |> case do
      {:ok, entries} -> entries |> Enum.filter(&(&1.type == "comment")) |> List.last()
      {:error, :unauthorized} -> nil
    end
  end

  defp owner_actor(project_id) do
    case ParticipantGuard.owner(project_id) do
      {:ok, owner} ->
        %{account_id: owner.account_id, hosted_identity_id: owner.hosted_identity_id}

      {:error, :unauthorized} ->
        %{account_id: nil, hosted_identity_id: nil}
    end
  end
end
