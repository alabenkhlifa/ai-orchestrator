defmodule SddOrchestrator.Delivery.RunNotifications do
  @moduledoc """
  Telling the fewest people who have to act that one run stopped.

  Three lifecycle moments reach a person: a run pausing on a question, verified
  work waiting for a decision, and a run that ended terminally. Each carries its
  own recipient set, resolved from current participation at projection time —
  the responsible participant for a block, that person and the project owner for
  a review, and the run's initiator beside both of them for a failure. Someone
  holding two of those roles is told once, and someone whose access ended is not
  told at all.

  Projection runs after the authoritative transition commits, never inside it.
  Delivery state may be device-authoritative while account notifications are
  hosted records, so the two cannot share one transaction. What that costs is
  at-least-once delivery, and what makes that safe is the store's event, subject,
  version, and recipient key: the same event projected twice stores one record.
  The version half of that key is the run's state version *after* its transition,
  so a run that blocks a second time is a new notification rather than a
  duplicate the key swallows.

  A project whose participation resolves to nobody produces no notification and
  no error. That is the fail-closed recipient path doing its job rather than a
  special case, and it is also what keeps a genuinely device-authoritative
  project — whose participation is not a hosted record at all — from copying its
  feature titles into the hosted database.

  Bodies carry the project and feature display context, what happened, and when.
  The branch, the commit, the question, the evidence, the preview, and the
  failure detail stay behind the feature link, which is authorized on its own
  every time it is opened. No participant email reaches this module.
  """

  require Logger

  alias Ecto.Multi
  alias SddOrchestrator.Delivery.{AgentRun, Assignment, Feature, ParticipantGuard}
  alias SddOrchestrator.Notifications
  alias SddOrchestrator.Notifications.AccountNotification
  alias SddOrchestrator.Projects.Project
  alias SddOrchestrator.Repo

  @type event :: :blocked | :ready_for_review | :failed
  @type role :: :initiator | :responsible | :owner

  @event_types %{
    blocked: "delivery.run_blocked",
    ready_for_review: "delivery.run_ready_for_review",
    failed: "delivery.run_failed"
  }

  # Listed in the order a person keeps when they hold more than one role, so the
  # result is one record per person rather than one per role.
  @recipient_roles %{
    blocked: [:responsible],
    ready_for_review: [:responsible, :owner],
    failed: [:initiator, :responsible, :owner]
  }

  # Display context is bounded before a body is built, so the longest title a
  # project may hold can never be the reason a notification fails to store.
  @max_label_bytes 120

  @spec events() :: [event()]
  def events, do: Map.keys(@event_types)

  @spec event_type(event()) :: String.t()
  def event_type(event), do: Map.fetch!(@event_types, event)

  @spec recipient_roles(event()) :: [role()]
  def recipient_roles(event), do: Map.fetch!(@recipient_roles, event)

  @doc """
  Projects one committed run event into notifications for its recipients.

  `run` must be the record the authoritative transition produced, because its
  state version is what distinguishes this event from the same event on the same
  run earlier. Every recipient's record commits in one transaction and the
  presentation hints are published only after it succeeds.

  Answers `{:ok, []}` when no role resolves to a current member: a project with
  nobody left to tell is not a failure, and a departed recipient is simply
  dropped. Answers `{:error, reason}` only when the store refuses the write,
  after logging it — the caller's lifecycle transition has already committed and
  must not be turned into an error by a notification nobody could store.
  """
  @spec deliver(Ecto.UUID.t(), AgentRun.t(), Feature.t(), event()) ::
          {:ok, [AccountNotification.t()]} | {:error, term()}
  def deliver(project_id, %AgentRun{} = run, %Feature{} = feature, event)
      when is_map_key(@event_types, event) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> projected(project, run, feature, event)
      nil -> {:ok, []}
    end
  rescue
    Ecto.Query.CastError -> {:ok, []}
  end

  defp projected(project, run, feature, event) do
    case recipients(project.id, run, feature, event) do
      [] -> {:ok, []}
      recipients -> store(project, run, feature, event, recipients)
    end
  end

  # One transaction for every recipient of one event, so a partially notified
  # event cannot exist. The event time is taken once and shared, because these
  # records describe the same moment.
  defp store(project, run, feature, event, recipients) do
    occurred_at = DateTime.truncate(DateTime.utc_now(), :second)

    steps =
      recipients
      |> Enum.with_index()
      |> Enum.map(fn {recipient, index} ->
        {{:notification, index}, attrs(project, run, feature, event, recipient, occurred_at)}
      end)

    steps
    |> Enum.reduce(Multi.new(), fn {name, attrs}, multi ->
      Notifications.deliver_multi(multi, name, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, changes} -> {:ok, published(steps, changes)}
      {:error, step, reason, _changes} -> {:error, logged(run, event, step, reason)}
    end
  end

  # The stored record is the delivery; the hint only tells a connected browser to
  # look again, and is published after the commit so a disconnected or restarted
  # reader still finds the same unread work.
  defp published(steps, changes) do
    notifications =
      steps
      |> Enum.map(fn {name, _attrs} -> Map.get(changes, name) end)
      |> Enum.reject(&is_nil/1)

    Notifications.publish_committed(notifications)

    notifications
  end

  defp recipients(project_id, run, feature, event) do
    members = current_members_by_account(project_id)

    event
    |> recipient_roles()
    |> Enum.map(&resolve(&1, project_id, run, feature, members))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.account_id)
  end

  # Responsibility is consumed, never re-derived: `Assignment` already resolves
  # assignee, then creator, then owner, and already refuses anyone who is no
  # longer a member.
  defp resolve(:responsible, project_id, _run, feature, _members) do
    case Assignment.responsible(project_id, feature) do
      {:ok, member} -> member
      {:error, :unavailable} -> nil
    end
  end

  defp resolve(:owner, project_id, _run, _feature, _members) do
    case ParticipantGuard.owner(project_id) do
      {:ok, owner} -> owner
      {:error, :unauthorized} -> nil
    end
  end

  # The initiator is a historical account reference on the run, so it is the one
  # role that has to be checked against current membership here. A run nobody
  # started and an initiator who has left both resolve to nobody.
  defp resolve(:initiator, _project_id, run, _feature, members),
    do: Map.get(members, run.initiator_account_id)

  # A project-level membership read, the same one `Assignment` uses: a projector
  # has no acting person, and membership has to resolve the same way for it as
  # for a signed-in participant.
  defp current_members_by_account(project_id) do
    case ParticipantGuard.owner(project_id) do
      {:ok, owner} ->
        project_id
        |> ParticipantGuard.current_members(%{
          account_id: owner.account_id,
          hosted_identity_id: owner.hosted_identity_id
        })
        |> Map.new(&{&1.account_id, &1})

      {:error, :unauthorized} ->
        %{}
    end
  end

  defp attrs(project, run, feature, event, recipient, occurred_at) do
    %{
      account_id: recipient.account_id,
      event_type: event_type(event),
      subject_ref: run.id,
      event_version: run.state_version,
      title: title(event),
      body: body(event, feature),
      project_label: bounded(project.name),
      # A run event has no human author. Naming one would invent an actor, and
      # the only labels this slice may present are project display names.
      actor_label: nil,
      link_path: "/projects/#{project.id}/features/#{feature.id}",
      occurred_at: occurred_at
    }
  end

  defp title(:blocked), do: "A run needs an answer"
  defp title(:ready_for_review), do: "Work is ready for review"
  defp title(:failed), do: "A run failed"

  # What happened and what the link is for. What the question asked, which branch
  # and commit were involved, what the evidence shows, and why the run failed all
  # stay behind that link.
  defp body(:blocked, feature),
    do: "#{label(feature)} is waiting on an answer before development continues."

  defp body(:ready_for_review, feature),
    do: "#{label(feature)} is ready for a review decision."

  defp body(:failed, feature),
    do: "#{label(feature)} stopped on a failed run and is waiting for a decision."

  defp label(%Feature{title: title}) when is_binary(title) and title != "", do: bounded(title)
  defp label(%Feature{}), do: "A feature"

  # Truncation is on a grapheme boundary, so a long display name is shortened
  # rather than cut into bytes no reader could render.
  defp bounded(nil), do: nil
  defp bounded(text) when byte_size(text) <= @max_label_bytes, do: text

  defp bounded(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, size} ->
      grown = size + byte_size(grapheme)

      if grown > @max_label_bytes do
        {:halt, {kept, size}}
      else
        {:cont, {[grapheme | kept], grown}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  # A committed lifecycle transition is not undone because nobody could be told
  # about it. The record names non-sensitive identifiers and which fields were
  # refused, never their content, and re-projecting the same event later is safe
  # because the key is idempotent.
  defp logged(run, event, step, reason) do
    Logger.warning(
      "[delivery_notification] event=#{event_type(event)} run_id=#{run.id} " <>
        "step=#{inspect(step)} detail=#{detail(reason)}"
    )

    reason
  end

  defp detail(%Ecto.Changeset{errors: errors}), do: errors |> Keyword.keys() |> inspect()
  defp detail(reason), do: inspect(reason)
end
