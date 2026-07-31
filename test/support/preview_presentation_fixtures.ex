defmodule SddOrchestrator.PreviewPresentationFixtures do
  @moduledoc """
  Preview deployments in each presented state, for the presentation proof (Task 33).

  Every scenario here goes through `Previews.start/4` rather than inserting a
  row, because the states this presentation has to tell apart are produced by
  the lifecycle and not by a caller. A timeout is a request the provider never
  answered, an expiry is a ready deployment whose configured lifetime had
  already run out, and a supersession is a later attempt verifying another
  commit — each reached the way the product reaches it, so a presented state
  cannot drift from a state the domain can actually record.

  Each scenario also gets a run of its own, since one run holds exactly one
  unsuperseded deployment. A feature with a ready preview and a failed one is a
  feature that was worked on twice, which is what the store would hold.
  """

  alias SddOrchestrator.Delivery.{DeliveryStore, Previews}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.PreviewAdapterDouble

  @path "web"
  @link "https://preview.example.test/branch-1"
  @contract ["mix test"]
  @commit "a1b2c3d4e5f6a7b8c9d0"
  @later_commit "b2b2b2b2b2b2b2b2b2b2"

  @doc "The preview path these fixtures authorize."
  def path, do: @path

  @doc "The participant-safe link a ready deployment carries."
  def link, do: @link

  @doc "The commit the first verified attempt proves."
  def commit, do: @commit

  @doc "The commit a later attempt proves, which supersedes the first preview."
  def later_commit, do: @later_commit

  @doc """
  Installs the configured preview adapter, authorizing one project on one path.

  Returns the restoring function `on_exit/1` expects, so a test that configures
  a preview never leaks that configuration into the next one.
  """
  def configure(project, opts \\ []) do
    PreviewAdapterDouble.install(Keyword.merge([projects: %{project.id => [@path]}], opts))
  end

  @doc "Removes the configured preview path entirely, adapter included."
  def unconfigure, do: PreviewAdapterDouble.uninstall()

  @doc """
  Creates one run and its first attempt through the project's own store.

  The attempt carries a required-check contract, because a verified completion
  is only recorded against one.
  """
  def run_fixture(authority, project, feature) do
    unique = System.unique_integer([:positive])
    digest = DeliveryFixtures.digest("rev-#{unique}")

    {:ok, %{run: run, attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:run,
         {:insert_run,
          %{
            project_id: project.id,
            feature_id: feature.id,
            starting_revision_id: "rev-#{unique}",
            starting_revision_digest: digest,
            approved_slice: "slice-07",
            branch: "sdd/preview-#{unique}"
          }}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: {:ref, :run, :id},
            attempt_number: 1,
            continuation_reason: "initial",
            effective_revision_id: "rev-#{unique}",
            effective_revision_digest: digest,
            manifest_digest: DeliveryFixtures.digest("manifest-#{unique}"),
            required_checks: DeliveryFixtures.required_check_contract(@contract),
            fence_token: 1
          }}}
      ])

    %{run: run, attempt: attempt}
  end

  @doc """
  Starts one preview for this feature in the named state, on a run of its own.

  `state` is one of `:pending`, `:ready`, `:failed`, `:timed_out`, or
  `:expired`. Use `supersede_fixture/3` for the sixth.
  """
  def preview_fixture(authority, project, feature, state, opts \\ []) do
    context = run_fixture(authority, project, feature)
    verify(authority, project, context, Keyword.get(opts, :commit_sha, @commit))
    script(state, opts)

    {:ok, %{deployment: deployment}} =
      Previews.start(authority, project.id, context.run, path: @path)

    Map.put(context, :deployment, deployment)
  end

  @doc """
  Verifies another commit on the same run, replacing the preview it already had.

  Returns the replacement together with the earlier deployment re-read from the
  store, which is the one now carrying `superseded`.
  """
  def supersede_fixture(authority, project, %{run: run, deployment: replaced}, state \\ :ready) do
    context = continue(authority, project, run)
    verify(authority, project, context, @later_commit)
    script(state, [])

    {:ok, %{deployment: deployment}} = Previews.start(authority, project.id, run, path: @path)

    superseded =
      authority
      |> Previews.list(project.id)
      |> Enum.find(&(&1.id == replaced.id))

    %{run: run, attempt: context.attempt, deployment: deployment, superseded: superseded}
  end

  defp verify(authority, project, %{run: run, attempt: attempt}, commit) do
    DeliveryFixtures.verified_completion_fixture(authority, project, run, attempt, %{
      commit_sha: commit
    })
  end

  defp script(:pending, _opts), do: PreviewAdapterDouble.script(:pending)
  defp script(:ready, _opts), do: PreviewAdapterDouble.script(:ready)
  defp script(:failed, _opts), do: PreviewAdapterDouble.script(:failed)

  # A provider that never answered. The control plane records the timeout itself
  # rather than believing a provider that claims one.
  defp script(:timed_out, _opts), do: PreviewAdapterDouble.script({:error, :timeout})

  # A deployment the provider reports ready with a lifetime that has already run
  # out. Expiry is settled by the control plane, so this is how an expired
  # deployment genuinely arises — and it is also what drops the link.
  defp script(:expired, opts) do
    expires_at =
      Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), -60, :second))

    PreviewAdapterDouble.script(fn _request ->
      PreviewAdapterDouble.ready(expires_at: expires_at)
    end)
  end

  # Ends the current attempt and opens its successor in one commit, which is the
  # only way a run gets a second attempt in either authority.
  defp continue(authority, project, run) do
    {:ok, previous} = DeliveryStore.current_attempt(authority, project.id, run.id)

    {:ok, %{attempt: attempt}} =
      DeliveryStore.commit(authority, project.id, [
        {:previous, {:transition_attempt, previous, "superseded"}},
        {:attempt,
         {:insert_attempt,
          %{
            run_id: run.id,
            attempt_number: previous.attempt_number + 1,
            continuation_reason: "manual_retry",
            effective_revision_id: run.effective_revision_id,
            effective_revision_digest: run.effective_revision_digest,
            manifest_digest: DeliveryFixtures.digest("manifest-2-#{run.id}"),
            required_checks: DeliveryFixtures.required_check_contract(@contract),
            fence_token: previous.fence_token + 1
          }}}
      ])

    %{run: run, attempt: attempt}
  end
end
