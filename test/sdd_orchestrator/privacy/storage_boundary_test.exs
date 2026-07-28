defmodule SddOrchestrator.Privacy.StorageBoundaryTest do
  @moduledoc """
  Task 6 enforcement proof that the hosted boundary of the storage-selection slice
  carries none of the prohibited device or source fields (AC-17).

  A recorded device-readiness receipt persists only its minimized binding — a
  digest plus attempt, device-workspace, nonce, and time fields — never the raw
  proof or a device label. A local repository crosses into the hosted onboarding
  attempt only as its non-reversible fingerprint and display name, never a path,
  remote URL, filename, Git history, or source content.
  """
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Projects
  alias SddOrchestrator.ProjectsFixtures

  # Fields that must never appear in hosted storage-selection records.
  @prohibited ~w(
    token device_label path location url remote_url html_url filename
    git_history os_username username hardware_id device_id source content
  )

  test "a recorded device-readiness receipt persists only its minimized binding" do
    device = ProjectsFixtures.device_workspace_fixture()
    attempt = ProjectsFixtures.device_attempt_with_repository(device)

    {:ok, updated} =
      Projects.record_device_receipt(device, attempt.id, ProjectsFixtures.device_receipt(attempt))

    setup = updated.device_setup

    assert Enum.sort(Map.keys(setup)) ==
             ~w(attempt_id device_workspace_id digest expires_at issued_at nonce)

    for key <- @prohibited, do: refute(Map.has_key?(setup, key), "receipt leaked #{key}")

    # Only the digest of the raw proof persists.
    assert is_binary(setup["digest"]) and byte_size(setup["digest"]) > 0
  end

  test "a local repository crosses into the hosted attempt only as a fingerprint and display name" do
    device = ProjectsFixtures.device_workspace_fixture()

    attempt =
      ProjectsFixtures.device_attempt_with_repository(device, %{
        fingerprint: "fp-boundary",
        name: "My Local Repo"
      })

    repo = attempt.selected_repository

    assert Enum.sort(Map.keys(repo)) == ~w(fingerprint name provider)
    assert repo["provider"] == "local"

    for key <- @prohibited,
        do: refute(Map.has_key?(repo, key), "repository metadata leaked #{key}")
  end
end
