defmodule SddOrchestrator.Delivery.PreviewPresentation do
  @moduledoc """
  What one authorized reader is shown of a feature's branch previews.

  This module reads; it records nothing, requests nothing, and decides nothing.
  Every value it returns already exists on a `PreviewDeployment` row, so the
  screen cannot claim a preview state the lifecycle did not record.

  Four rules shape what comes out.

  Absence is a fact with two different causes, and they are reported apart. A
  project with no preconfigured and authorized preview path never had a preview
  to lose; a project that has one but has verified nothing yet is simply waiting.
  Collapsing them would answer "why is there no link?" with a shrug. Which case
  applies is read from `PreviewAdapter.authorize/2` — the same resolver
  `Previews.start/4` obeys — rather than derived a second time from a different
  configuration key, because two derivations of one judgement are two answers
  waiting to differ.

  Nothing is filtered. A superseded preview and an expired one stay in the list
  beside the current one, because "replaced by a newer commit", "reached the end
  of its lifetime", and "the provider refused" are three different answers and a
  reader deciding whether to retry, wait, or look elsewhere needs to know which
  one happened.

  A link is re-validated here even though it cannot be stored unsafely. The
  changeset, the device-value decode, and a database check constraint each
  refuse an unsafe link on the way in; this module refuses it again on the way
  out, and refuses it for any deployment that is not `ready`. Three write-side
  guards do nothing about a link that arrives by a fourth path, and the one
  promise this presentation exists to keep is that no reader is ever sent to a
  preview that does not exist.

  No provider handle reaches the caller. `provider_ref` addresses a deployment
  at the provider and is deliberately absent from everything returned here: a
  reader needs the state, the reason, and — when there genuinely is one — the
  link.
  """

  alias SddOrchestrator.Delivery.{
    DeliveryStore,
    EvidencePresentation,
    ParticipantGuard,
    PreviewAdapter,
    PreviewDeployment,
    Previews
  }

  @type authority :: DeliveryStore.authority()
  @type actor :: ParticipantGuard.actor()
  @type deployment :: map()
  @type summary :: map()

  # The two states no deployment can carry, because they describe the absence of
  # one. Everything else is a recorded deployment status.
  @absent_states ~w(not_configured none)

  @doc "Every state this presentation can report, absence included."
  @spec states() :: [String.t()]
  def states, do: @absent_states ++ PreviewDeployment.statuses()

  @doc """
  Summarizes one feature's previews for a current participant.

  A preview outcome is context for a run's evidence, so the read is guarded by
  `:read_evidence` rather than by an action of its own. Participation is
  re-checked on every call: a person removed from the project between one render
  and the next is refused on the next one.

  Order comes from the store, oldest first, so the sequence a reader sees is the
  sequence the deployments were requested in.
  """
  @spec summary(authority(), Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, summary()} | {:error, :unauthorized}
  def summary(authority, project_id, actor, feature_id) do
    with {:ok, _member} <- ParticipantGuard.authorize_action(project_id, actor, :read_evidence) do
      configuration = configuration(project_id)

      deployments =
        authority
        |> feature_deployments(project_id, feature_id)
        |> Enum.map(&present/1)

      {:ok,
       Map.merge(configuration, %{
         state: state(configuration, deployments),
         deployments: deployments
       })}
    end
  end

  @doc """
  What a reader who may not read this project's evidence is shown.

  The same answer a stranger, a former participant, and a project that has no
  preview path get, so no one learns from the preview section whether a project
  they cannot read has previews configured.
  """
  @spec unavailable() :: summary()
  def unavailable do
    %{configured?: false, provider: nil, path: nil, state: "not_configured", deployments: []}
  end

  # The authorized path is resolved exactly as the lifecycle resolves it. An
  # absent adapter, an unlisted project, and a project listed with no usable
  # path are one answer to a reader: this project has no preview path.
  defp configuration(project_id) do
    case PreviewAdapter.authorize(project_id) do
      {:ok, policy} -> %{configured?: true, provider: policy.provider, path: policy.path}
      {:error, _unavailable} -> %{configured?: false, provider: nil, path: nil}
    end
  end

  # `list_preview_deployments` narrows by run, attempt, or commit rather than by
  # feature, because that is what the lifecycle asks it. A feature's previews
  # span every run it has had, so the project's own ordered list is read and
  # narrowed here.
  defp feature_deployments(authority, project_id, feature_id) do
    authority
    |> Previews.list(project_id)
    |> Enum.filter(&(&1.feature_id == feature_id))
  end

  defp state(%{configured?: false}, _deployments), do: "not_configured"
  defp state(_configuration, []), do: "none"

  defp state(_configuration, deployments) do
    current = Enum.find(Enum.reverse(deployments), & &1.current?)

    (current || List.last(deployments)).status
  end

  @doc """
  Presents one recorded deployment as the values a screen renders.

  Public for one reason: the link re-check below cannot be reached through any
  write path. The changeset, the device decode, and a database check constraint
  each refuse an unsafe or missing link before it is stored, so the only way to
  prove this module refuses one too is to hand it a record no store can hold.
  """
  @spec present(PreviewDeployment.t()) :: deployment()
  def present(%PreviewDeployment{} = deployment) do
    link = usable_link(deployment)
    current? = PreviewDeployment.current?(deployment)

    %{
      id: deployment.id,
      status: deployment.status,
      branch: deployment.branch,
      commit_sha: deployment.commit_sha,
      run_id: deployment.run_id,
      run_ref: EvidencePresentation.short_reference(deployment.run_id),
      attempt_id: deployment.attempt_id,
      attempt_ref: EvidencePresentation.short_reference(deployment.attempt_id),
      provider: deployment.provider,
      path: deployment.path,
      link: link,
      link?: not is_nil(link),
      link_withheld?: deployment.status == "ready" and is_nil(link),
      failed?: PreviewDeployment.failed?(deployment),
      failure_reason: deployment.failure_reason,
      open?: PreviewDeployment.open?(deployment),
      current?: current?,
      superseded?: not current?,
      replaced_by_ref: EvidencePresentation.short_reference(deployment.superseded_by_id),
      requested_at: deployment.requested_at,
      ready_at: deployment.ready_at,
      timeout_at: deployment.timeout_at,
      expires_at: deployment.expires_at,
      cleanup_state: deployment.cleanup_state
    }
  end

  # The one place a link becomes something a reader may be sent to. A deployment
  # that is not `ready` has nowhere to send them however recently it did, and a
  # link that does not pass the safety predicate is dropped rather than shown
  # with a warning beside it.
  defp usable_link(%PreviewDeployment{status: "ready", link: link}) do
    if PreviewDeployment.safe_link?(link), do: link, else: nil
  end

  defp usable_link(_deployment), do: nil
end
