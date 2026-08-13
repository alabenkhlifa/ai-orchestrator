defmodule SddOrchestrator.ProjectAssistant.RepositoryObservationTest do
  @moduledoc """
  specs/12-project-assistant Task 4 focused proof: `entity:RepositoryObservation`
  derives its stability result from a before/after digest comparison (AC-09),
  and the default `RepositoryObservationAdapter` is the deterministic,
  worker-unavailable `Unavailable` fallback until a real adapter is
  configured, matching `RepositoryMetadataAdapter`'s established pattern.
  """
  use ExUnit.Case, async: true

  alias SddOrchestrator.ProjectAssistant.RepositoryObservation
  alias SddOrchestrator.ProjectAssistant.RepositoryObservationAdapter

  @target %{
    project_id: "11111111-1111-1111-1111-111111111111",
    repository_provider: "github",
    repository_ref: "101",
    actor_ref: "22222222-2222-2222-2222-222222222222"
  }

  @raw %{
    branch: "main",
    commit: "abc123",
    dirty: false,
    scan_started_at: ~U[2026-01-01 00:00:00Z],
    scan_completed_at: ~U[2026-01-01 00:00:04Z],
    exclusions: [],
    before_digest: "same",
    after_digest: "same"
  }

  describe "build/2" do
    test "carries through provenance and content fields" do
      observation = RepositoryObservation.build(@target, @raw)

      assert observation.project_id == @target.project_id
      assert observation.actor_ref == @target.actor_ref
      assert observation.repository_provider == "github"
      assert observation.repository_ref == "101"
      assert observation.branch == "main"
      assert observation.commit == "abc123"
      assert observation.dirty == false
      assert observation.scan_started_at == @raw.scan_started_at
      assert observation.scan_completed_at == @raw.scan_completed_at
    end

    test "is stable when the before and after digests match" do
      observation = RepositoryObservation.build(@target, @raw)

      assert observation.stable? == true
    end

    test "is unstable when the before and after digests differ" do
      raw = %{@raw | after_digest: "different"}
      observation = RepositoryObservation.build(@target, raw)

      assert observation.stable? == false
    end

    test "reports no commit for an unborn branch without treating it as an error" do
      raw = %{@raw | commit: nil}
      observation = RepositoryObservation.build(@target, raw)

      assert observation.commit == nil
      assert observation.branch == "main"
    end

    test "defaults exclusions to an empty list when the adapter omits them" do
      raw = Map.delete(@raw, :exclusions)
      observation = RepositoryObservation.build(@target, raw)

      assert observation.exclusions == []
    end
  end

  describe "RepositoryObservationAdapter.configured/0" do
    test "defaults to the deterministic Unavailable fallback" do
      assert RepositoryObservationAdapter.configured() == RepositoryObservationAdapter.Unavailable
    end

    test "the Unavailable fallback reports worker_unavailable" do
      assert RepositoryObservationAdapter.Unavailable.observe(%{
               project_id: "11111111-1111-1111-1111-111111111111",
               repository_provider: nil,
               repository_ref: nil,
               exclusions: []
             }) == {:error, :worker_unavailable}
    end
  end
end
