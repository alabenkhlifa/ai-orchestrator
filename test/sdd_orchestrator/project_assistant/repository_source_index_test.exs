defmodule SddOrchestrator.ProjectAssistant.RepositorySourceIndexTest do
  @moduledoc """
  specs/12-project-assistant Task 5 focused proof: `entity:RepositorySourceIndex`
  is a plain, non-persisted identity/version key (AC-18) that invalidates
  whenever project, repository authority, branch, commit, or working-tree
  state drifts, and never treats two different projects or repository
  authorities as interchangeable.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.RepositoryObservation
  alias SddOrchestrator.ProjectAssistant.RepositorySourceIndex

  @project_a "11111111-1111-1111-1111-111111111111"
  @project_b "22222222-2222-2222-2222-222222222222"

  defp observation(overrides \\ %{}) do
    base = %{
      project_id: @project_a,
      actor_ref: "actor-1",
      repository_provider: "github",
      repository_ref: "101",
      branch: "main",
      commit: "abc123",
      dirty: false,
      scan_started_at: ~U[2026-01-01 00:00:00Z],
      scan_completed_at: ~U[2026-01-01 00:00:04Z],
      exclusions: [],
      before_digest: "digest-1",
      after_digest: "digest-1",
      stable?: true
    }

    struct(RepositoryObservation, Map.merge(base, overrides))
  end

  test "is not a persisted Ecto schema" do
    refute function_exported?(RepositorySourceIndex, :__schema__, 1)
  end

  describe "build/1" do
    test "carries identity and version fields from the observation" do
      index = RepositorySourceIndex.build(observation())

      assert index.project_id == @project_a
      assert index.repository_provider == "github"
      assert index.repository_ref == "101"
      assert index.branch == "main"
      assert index.commit == "abc123"
      assert index.index_version == RepositorySourceIndex.index_version()
      assert is_binary(index.working_tree_state_key)
    end

    test "the working-tree-state key changes when dirty state changes" do
      clean = RepositorySourceIndex.build(observation())
      dirty = RepositorySourceIndex.build(observation(%{dirty: true}))

      refute clean.working_tree_state_key == dirty.working_tree_state_key
    end

    test "the working-tree-state key changes when the after-scan digest changes" do
      before_change = RepositorySourceIndex.build(observation())
      after_change = RepositorySourceIndex.build(observation(%{after_digest: "digest-2"}))

      refute before_change.working_tree_state_key == after_change.working_tree_state_key
    end
  end

  describe "current?/2 — invalidation and refresh" do
    test "an index stays current against the unchanged observation it was built from" do
      obs = observation()
      index = RepositorySourceIndex.build(obs)

      assert RepositorySourceIndex.current?(index, obs)
    end

    test "a source change (new commit) invalidates the prior index" do
      index = RepositorySourceIndex.build(observation())
      changed = observation(%{commit: "def456", after_digest: "digest-2"})

      refute RepositorySourceIndex.current?(index, changed)
    end

    test "a working-tree change on the same commit (uncommitted edit) invalidates the prior index" do
      index = RepositorySourceIndex.build(observation())
      changed = observation(%{dirty: true, after_digest: "digest-2"})

      refute RepositorySourceIndex.current?(index, changed)
    end

    test "a branch change invalidates the prior index" do
      index = RepositorySourceIndex.build(observation())
      changed = observation(%{branch: "feature/x"})

      refute RepositorySourceIndex.current?(index, changed)
    end

    test "an index for one project is never current against another project's observation" do
      index = RepositorySourceIndex.build(observation())
      other_project = observation(%{project_id: @project_b})

      refute RepositorySourceIndex.current?(index, other_project)
    end
  end

  describe "scope/1 — project and source-authority scoping" do
    test "two indexes built for the same project and repository authority share a scope" do
      index_1 = RepositorySourceIndex.build(observation())
      index_2 = RepositorySourceIndex.build(observation(%{commit: "def456", after_digest: "d2"}))

      assert RepositorySourceIndex.scope(index_1) == RepositorySourceIndex.scope(index_2)
    end

    test "indexes for different projects never share a scope" do
      index_a = RepositorySourceIndex.build(observation())
      index_b = RepositorySourceIndex.build(observation(%{project_id: @project_b}))

      refute RepositorySourceIndex.scope(index_a) == RepositorySourceIndex.scope(index_b)
    end

    test "indexes for different repository authorities on the same project never share a scope" do
      index_a = RepositorySourceIndex.build(observation())
      index_b = RepositorySourceIndex.build(observation(%{repository_ref: "202"}))

      refute RepositorySourceIndex.scope(index_a) == RepositorySourceIndex.scope(index_b)
    end
  end
end
