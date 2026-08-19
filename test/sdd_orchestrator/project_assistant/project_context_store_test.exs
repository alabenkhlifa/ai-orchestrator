defmodule SddOrchestrator.ProjectAssistant.ProjectContextStoreTest do
  @moduledoc """
  specs/12-project-assistant Task 3 focused proof: assembling and projecting
  current stored project context for both the hosted and device authorities.

  Covers AC-07 (context assembled only from current metadata, the current
  specification snapshot, current board state, and only the recent run
  status and evidence needed) and AC-17 (the stored projection stays inside
  the project's authoritative boundary with no repository source or derived
  source index).
  """
  use SddOrchestrator.DataCase, async: false

  alias SddOrchestrator.Accounts.DeviceWorkspace
  alias SddOrchestrator.Delivery.{DeliveryStore, Feature}
  alias SddOrchestrator.DeliveryFixtures
  alias SddOrchestrator.Devices
  alias SddOrchestrator.Devices.DeviceStore.Local
  alias SddOrchestrator.EvidencePresentationFixtures, as: EF
  alias SddOrchestrator.Participation.ProjectParticipant
  alias SddOrchestrator.ParticipationFixtures

  alias SddOrchestrator.ProjectAssistant.{
    DeviceProjectContextProjection,
    ProjectContextProjection
  }

  alias SddOrchestrator.ProjectAssistant.{ProjectContextAssembler, ProjectContextStore}
  alias SddOrchestrator.SpecificationFixtures
  alias SddOrchestrator.SpecificationStore

  describe "hosted authority" do
    setup do
      fixture = DeliveryFixtures.delivery_project_fixture()
      feature = DeliveryFixtures.feature_fixture(fixture.project, fixture.account)

      current =
        SpecificationFixtures.hosted_specification(fixture.workspace, fixture.project, %{
          title: "Read-only project assistant"
        })

      Map.merge(fixture, %{feature: feature, specification: current})
    end

    test "assembles current metadata, specification identity, board state, recent run status, and accepted evidence",
         %{
           project: project,
           workspace: workspace,
           owner_actor: owner_actor,
           feature: feature,
           specification: current
         } do
      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      start_run_activity(workspace, run, attempt)
      evidence = EF.evidence_fixture(workspace, %{run: run, attempt: attempt})

      assert {:ok, %ProjectContextProjection{} = projection} =
               ProjectContextStore.refresh(workspace, project.id, owner_actor)

      content = projection.content

      assert content["project"] == %{
               "id" => project.id,
               "name" => project.name,
               "storage_mode" => "hosted",
               "lifecycle_state" => project.lifecycle_state
             }

      assert content["specifications"] == [
               %{
                 "id" => current.specification.id,
                 "title" => "Read-only project assistant",
                 "revision_id" => current.revision.id
               }
             ]

      assert Map.keys(content["board"]) |> Enum.sort() == Enum.sort(Feature.columns())
      [board_entry] = content["board"]["draft"]
      assert board_entry["id"] == feature.id
      assert board_entry["title"] == feature.title
      assert board_entry["lifecycle_column"] == "draft"

      assert [run_entry] = content["recent_runs"]
      assert run_entry["run_id"] == run.id
      assert run_entry["feature_id"] == feature.id
      assert run_entry["state"] == run.state
      assert run_entry["branch"] == run.branch

      assert [evidence_entry] = content["accepted_evidence"]
      assert evidence_entry["id"] == evidence.id
      assert evidence_entry["outcome"] == "passed"
      assert evidence_entry["feature_id"] == feature.id

      assert {:ok, fetched} = ProjectContextStore.get(workspace, project.id, owner_actor)
      assert fetched.context_version == projection.context_version
    end

    test "excludes superseded evidence, keeping only the current accepted result", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      feature: feature
    } do
      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      original = EF.evidence_fixture(workspace, %{run: run, attempt: attempt})
      replacement = EF.evidence_fixture(workspace, %{run: run, attempt: attempt})
      :ok = EF.supersede_fixture(workspace, original, replacement)

      assert {:ok, projection} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      evidence_ids = Enum.map(projection.content["accepted_evidence"], & &1["id"])
      assert evidence_ids == [replacement.id]
      refute original.id in evidence_ids
    end

    test "excludes prior specification revisions, keeping only the current one", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      specification: current
    } do
      {:ok, updated} =
        SpecificationStore.append_revision(
          workspace,
          project.id,
          current.specification.id,
          current.revision.id,
          %{documents: SpecificationFixtures.documents(%{requirements: "# Requirements v2"})}
        )

      assert {:ok, projection} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      assert projection.content["specifications"] == [
               %{
                 "id" => current.specification.id,
                 "title" => current.specification.title,
                 "revision_id" => updated.revision.id
               }
             ]

      refute updated.revision.id == current.revision.id
    end

    test "rejects a stale (removed) participant, an absent identity, and a cross-project identity identically",
         %{
           project: project,
           workspace: workspace,
           participant_actor: participant_actor,
           identity: identity
         } do
      participant =
        Repo.get_by!(ProjectParticipant,
          project_id: project.id,
          hosted_identity_id: identity.hosted_identity.id
        )

      participant
      |> ProjectParticipant.departure_changeset(%{departure_reason: "removed"})
      |> Repo.update!()

      other = ParticipationFixtures.invited_identity_fixture()
      absent_actor = %{account_id: other.account.id, hosted_identity_id: other.hosted_identity.id}

      %{project: other_project, participant_actor: other_project_actor} =
        DeliveryFixtures.delivery_project_fixture()

      refute other_project.id == project.id

      removed = ProjectContextStore.refresh(workspace, project.id, participant_actor)
      absent = ProjectContextStore.refresh(workspace, project.id, absent_actor)
      cross_project = ProjectContextStore.refresh(workspace, project.id, other_project_actor)
      unknown_project = ProjectContextStore.refresh(workspace, Ecto.UUID.generate(), absent_actor)

      assert removed == {:error, :unauthorized}
      assert absent == {:error, :unauthorized}
      assert cross_project == {:error, :unauthorized}
      assert unknown_project == {:error, :unauthorized}

      assert ProjectContextStore.get(workspace, project.id, participant_actor) ==
               {:error, :unauthorized}

      assert ProjectContextStore.delete(workspace, project.id, participant_actor) ==
               {:error, :unauthorized}
    end

    test "rebuilds the projection idempotently when nothing changed", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      feature: feature
    } do
      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      start_run_activity(workspace, run, attempt)
      EF.evidence_fixture(workspace, %{run: run, attempt: attempt})

      assert {:ok, first} = ProjectContextStore.refresh(workspace, project.id, owner_actor)
      assert {:ok, second} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      assert first.context_version == second.context_version
      assert first.id == second.id
      assert Repo.aggregate(ProjectContextProjection, :count) == 1
    end

    test "changes context_version when the underlying data genuinely changes", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor,
      feature: feature
    } do
      assert {:ok, before_run} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      start_run_activity(workspace, run, attempt)

      assert {:ok, after_run} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      refute before_run.context_version == after_run.context_version
      assert Repo.aggregate(ProjectContextProjection, :count) == 1
    end

    test "deletes the projection immediately and idempotently", %{
      project: project,
      workspace: workspace,
      owner_actor: owner_actor
    } do
      {:ok, _projection} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      assert :ok = ProjectContextStore.delete(workspace, project.id, owner_actor)
      assert {:ok, nil} = ProjectContextStore.get(workspace, project.id, owner_actor)
      assert Repo.aggregate(ProjectContextProjection, :count) == 0

      # Idempotent: deleting an already-absent projection still succeeds.
      assert :ok = ProjectContextStore.delete(workspace, project.id, owner_actor)
    end

    test "finds no repository path, source, source index, raw log, or unrelated activity in the projection",
         %{project: project, workspace: workspace, owner_actor: owner_actor, feature: feature} do
      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      start_run_activity(workspace, run, attempt)
      EF.evidence_fixture(workspace, %{run: run, attempt: attempt})

      # Unrelated feature activity — a comment and a progress note — must
      # never surface in the assembled context, only the derived run status.
      DeliveryFixtures.activity_fixture(project, feature, %{
        type: "comment",
        payload: %{"body" => "please review the auth flow at /etc/ssh/id_rsa"}
      })

      assert {:ok, projection} = ProjectContextStore.refresh(workspace, project.id, owner_actor)

      refute_repository_content(projection.content)
    end

    test "the assembler and store own no delivery-mutation function" do
      refute_write_functions(ProjectContextAssembler)
      refute_write_functions(ProjectContextStore)
    end
  end

  describe "device authority" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "project_context_device_store_#{System.unique_integer([:positive])}/store.dets"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Local, path: path})

      {:ok, workspace} = Devices.establish_workspace()

      {:ok, project} =
        Devices.register_project(%{
          name: "Device context project",
          repository_fingerprint:
            "device-context-fingerprint-#{System.unique_integer([:positive])}",
          status: "connected",
          idempotency_key: Ecto.UUID.generate()
        })

      feature = plant_device_feature(project.id)

      {:ok, current} =
        SpecificationStore.create(
          workspace,
          project.id,
          SpecificationFixtures.specification_attrs(%{title: "Device assistant spec"}),
          actor_ref: "owner"
        )

      %{workspace: workspace, project: project, feature: feature, specification: current}
    end

    test "assembles current metadata, specification identity, board state, recent run status, and accepted evidence",
         %{
           project: project,
           workspace: workspace,
           feature: feature,
           specification: current
         } do
      %{run: run, attempt: attempt} = EF.run_fixture(workspace, project, feature)
      start_run_activity(workspace, run, attempt)
      evidence = EF.evidence_fixture(workspace, %{run: run, attempt: attempt})

      assert {:ok, %DeviceProjectContextProjection{} = projection} =
               ProjectContextStore.refresh(workspace, project.id, %{})

      content = projection.content

      assert content["project"] == %{
               "id" => project.id,
               "name" => project.name,
               "storage_mode" => "device",
               "lifecycle_state" => project.status
             }

      assert content["specifications"] == [
               %{
                 "id" => current.specification.id,
                 "title" => "Device assistant spec",
                 "revision_id" => current.revision.id
               }
             ]

      [board_entry] = content["board"]["draft"]
      assert board_entry["id"] == feature.id

      assert [run_entry] = content["recent_runs"]
      assert run_entry["run_id"] == run.id

      assert [evidence_entry] = content["accepted_evidence"]
      assert evidence_entry["id"] == evidence.id

      # Nothing reaches PostgreSQL for a device-authoritative project.
      assert Repo.aggregate(ProjectContextProjection, :count) == 0
    end

    test "rejects a stale device workspace and a cross-project identity identically", %{
      project: project
    } do
      other_workspace = %DeviceWorkspace{id: Ecto.UUID.generate()}

      assert ProjectContextStore.refresh(other_workspace, project.id, %{}) ==
               {:error, :unauthorized}

      assert ProjectContextStore.get(other_workspace, project.id, %{}) == {:error, :unauthorized}

      assert ProjectContextStore.delete(other_workspace, project.id, %{}) ==
               {:error, :unauthorized}
    end

    test "rebuilds the projection idempotently when nothing changed", %{
      project: project,
      workspace: workspace
    } do
      assert {:ok, first} = ProjectContextStore.refresh(workspace, project.id, %{})
      assert {:ok, second} = ProjectContextStore.refresh(workspace, project.id, %{})

      assert first.context_version == second.context_version
      assert first.id == second.id
    end

    test "deletes the projection immediately and idempotently, allowing a fresh rebuild", %{
      project: project,
      workspace: workspace
    } do
      {:ok, _projection} = ProjectContextStore.refresh(workspace, project.id, %{})

      assert :ok = ProjectContextStore.delete(workspace, project.id, %{})
      assert {:ok, nil} = ProjectContextStore.get(workspace, project.id, %{})

      # Idempotent.
      assert :ok = ProjectContextStore.delete(workspace, project.id, %{})

      assert {:ok, rebuilt} = ProjectContextStore.refresh(workspace, project.id, %{})
      assert rebuilt.state_version == 1
    end
  end

  # A device-authoritative project has no way to create a `Feature` today
  # (`Features.create/3` is hosted-only, gated by the hosted-only
  # participation boundary); this plants one directly through the same
  # generic device-delivery seam production code will eventually write
  # through, exercising the read side of the already-published
  # `capability:guided-delivery-data-surfaces` contract exactly as it is
  # defined (`Feature.to_value/1` plus `Devices.commit_delivery/2`).
  defp plant_device_feature(project_id) do
    feature = %Feature{
      id: Ecto.UUID.generate(),
      project_id: project_id,
      title: "Device feature",
      creator_account_id: nil,
      assigned_account_id: nil
    }

    {:ok, _applied} =
      Devices.commit_delivery(project_id, [
        {:put, :feature, feature.id, Feature.to_value(feature), nil}
      ])

    feature
  end

  # `EvidencePresentationFixtures.run_fixture/3` deliberately does not append
  # a "run_started" activity entry (it exists to prove evidence presentation,
  # not run discovery); this appends the one entry `ProjectContextAssembler`
  # reads to find one feature's current run, through the same
  # authority-dispatching `append_activity` step production code uses.
  defp start_run_activity(authority, run, attempt) do
    {:ok, %{activity: entry}} =
      DeliveryStore.commit(authority, run.project_id, [
        {:activity,
         {:append_activity,
          %{
            project_id: run.project_id,
            feature_id: run.feature_id,
            run_id: run.id,
            attempt_id: attempt.id,
            actor_kind: "system",
            type: "run_started",
            payload: %{}
          }}}
      ])

    entry
  end

  @forbidden_substrings ~w(
    /etc/ passwd id_rsa .git repository_source repository_path source_index
    stdout stderr transcript
  )

  defp refute_repository_content(content) do
    serialized = content |> canonical_string() |> String.downcase()

    for needle <- @forbidden_substrings do
      refute String.contains?(serialized, needle),
             "expected no #{inspect(needle)} in the assembled context, got: #{serialized}"
    end

    refute Map.has_key?(content, "repository")
    refute Map.has_key?(content, "source")
    refute Map.has_key?(content, "source_index")

    for feature <- Enum.flat_map(content["board"], fn {_column, entries} -> entries end) do
      refute Map.has_key?(feature, "repository_path")
    end

    for evidence <- content["accepted_evidence"] do
      refute Map.has_key?(evidence, "command")
      refute Map.has_key?(evidence, "exit_code")
      refute Map.has_key?(evidence, "artifact_ref")
    end
  end

  defp canonical_string(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp refute_write_functions(module) do
    forbidden = ~w(create insert update transition put_status delete_feature append_revision)a

    functions = module.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

    for name <- forbidden do
      refute name in functions, "#{inspect(module)} unexpectedly exposes #{name}/N"
    end
  end
end
