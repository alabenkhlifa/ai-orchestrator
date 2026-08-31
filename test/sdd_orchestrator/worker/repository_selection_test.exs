defmodule SddOrchestrator.Worker.RepositorySelectionTest do
  @moduledoc """
  Task 3 proof: the worker release holds one folder-picker request, publishes it
  to an owner-only file for the Mac app, takes the app's answer back off disk,
  and answers with identities and a folder name only.

  Covers [AC-04] (the worker answers with the repository's identity, the folder
  name, and which candidates matched, and nothing else) and [AC-11] (the answer
  file is deleted as soon as it is read, a stale one is deleted unread at start,
  and no path reaches a log line).

  `async: false` because it starts a named GenServer and works on the real
  filesystem under a temporary storage root.
  """

  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Devices.RepositoryValidation
  alias SddOrchestrator.RepositorySelection.AttachmentCodec
  alias SddOrchestrator.Worker.Configuration
  alias SddOrchestrator.Worker.RepositorySelection

  # Short enough that a test waiting for the answer file to be picked up does
  # not wait on the production half-second, and still a real timer tick.
  @poll_interval 25

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "worker_repository_selection_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    %{home: home}
  end

  defp start_selection(home) do
    start_supervised!(
      {RepositorySelection, home_override: home, poll_interval: @poll_interval},
      restart: :temporary
    )
  end

  # The result payload comes back through the same one-argument function the
  # gateway connection gives the request, so a test reads it as a message.
  defp reply_to(pid), do: fn payload -> send(pid, {:selection_result, payload}) end

  defp request_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "request-#{System.unique_integer([:positive])}",
        "candidates" => [],
        "generate" => false,
        "expires_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # The same fixture shape `SddOrchestrator.Devices.RepositoryValidationTest`
  # builds: a real repository whose distinct first blob gives it a root commit
  # unrelated to any other fixture's.
  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "t@example.test"])
    git!(dir, ["config", "user.name", "Tester"])
    File.write!(Path.join(dir, "README.md"), "seed-#{Path.basename(dir)}")
    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "-q", "-m", "root"])
    dir
  end

  # Written the way the Mac app writes it, by renaming a complete neighbour over
  # the target. The release deletes the answer before decoding it, so a
  # half-written file would be lost rather than retried; a plain `File.write!`
  # here is a flake waiting for a slow machine.
  defp write_answer!(home, contents) do
    path = RepositorySelection.answer_path(home)
    temporary = path <> ".partial"

    File.write!(temporary, Jason.encode!(contents))
    File.rename!(temporary, path)
  end

  # A paired worker, stored the way pairing stores it, so the release reads its
  # own device workspace from disk exactly as it does in production. That
  # workspace is the salt every legacy fingerprint was computed with.
  defp pair!(home, device_workspace_id) do
    Configuration.store(
      %Configuration{
        control_plane_address: "http://localhost:4000",
        device_workspace_id: device_workspace_id,
        worker_credential: "credential-#{System.unique_integer([:positive])}",
        agent_adapter: "claude_code",
        agent_executable: "/usr/bin/true",
        worker_id: Ecto.UUID.generate()
      },
      home
    )

    device_workspace_id
  end

  defp legacy_identity!(path, workspace_id) do
    {:ok, %{fingerprint: fingerprint}} = RepositoryValidation.validate(path, workspace_id)

    fingerprint
  end

  defp portable_identity!(path) do
    {:ok, identity} = PortableRepositoryIdentity.generate(path)

    identity
  end

  describe "the pending request file" do
    test "publishes the request id and expiry only, owner-only, and removes it when the request ends",
         %{home: home} do
      start_selection(home)

      payload =
        request_payload(%{"candidates" => [%{"ref" => "a", "identity" => "local-repo:v1"}]})

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert RepositorySelection.pending() == payload["request_id"]

      file = RepositorySelection.pending_path(home)

      assert Jason.decode!(File.read!(file)) == %{
               "request_id" => payload["request_id"],
               "expires_at" => payload["expires_at"]
             }

      assert (File.stat!(file).mode &&& 0o777) == 0o600

      :ok = RepositorySelection.close(payload["request_id"])

      assert RepositorySelection.pending() == nil
      refute File.exists?(file)
      refute_receive {:selection_result, _payload}, 100
    end

    test "a stale pending file left on disk is deleted at start", %{home: home} do
      file = RepositorySelection.pending_path(home)

      File.write!(
        file,
        Jason.encode!(%{
          "request_id" => "a-request-that-is-gone",
          "expires_at" => "2020-01-01T00:00:00Z"
        })
      )

      start_selection(home)

      refute File.exists?(file)
      assert RepositorySelection.pending() == nil
    end

    test "replaces a request that is still open", %{home: home} do
      start_selection(home)
      first = request_payload()
      second = request_payload()

      :ok = RepositorySelection.open(first, reply_to(self()), home)
      :ok = RepositorySelection.open(second, reply_to(self()), home)

      assert RepositorySelection.pending() == second["request_id"]

      assert Jason.decode!(File.read!(RepositorySelection.pending_path(home)))["request_id"] ==
               second["request_id"]

      assert {:error, :unknown_request} =
               RepositorySelection.answer(first["request_id"], :cancelled)
    end
  end

  describe "answering with a chosen folder" do
    test "reports the matching candidates, the folder name, and a fresh identity", %{home: home} do
      start_selection(home)

      chosen = init_repo!(Path.join(home, "chosen-repository"))
      other = init_repo!(Path.join(home, "other-repository"))

      {:ok, chosen_identity} = PortableRepositoryIdentity.generate(chosen)
      {:ok, other_identity} = PortableRepositoryIdentity.generate(other)

      payload =
        request_payload(%{
          "generate" => true,
          "candidates" => [
            %{"ref" => "same", "identity" => chosen_identity},
            %{"ref" => "different", "identity" => other_identity},
            %{"ref" => "malformed", "identity" => "not-an-identity"}
          ]
        })

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert :ok = RepositorySelection.answer(payload["request_id"], chosen)

      assert_receive {:selection_result, result}

      assert result["request_id"] == payload["request_id"]
      assert result["outcome"] == "selected"
      assert result["folder_name"] == "chosen-repository"
      assert result["matches"] == ["same"]
      assert {:ok, true} = PortableRepositoryIdentity.match(chosen, result["identity"])

      # The answer carries nothing the control plane's own codec would refuse,
      # and in particular nothing that could name a location.
      assert Enum.all?(Map.keys(result), &(&1 in AttachmentCodec.result_keys()))
      assert {:ok, _accepted} = AttachmentCodec.decode_result(result)

      assert RepositorySelection.pending() == nil
      refute File.exists?(RepositorySelection.pending_path(home))
    end

    test "omits the identity when none was asked for", %{home: home} do
      start_selection(home)
      chosen = init_repo!(Path.join(home, "no-identity-wanted"))
      payload = request_payload()

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert :ok = RepositorySelection.answer(payload["request_id"], chosen)

      assert_receive {:selection_result, result}
      refute Map.has_key?(result, "identity")
      assert result["matches"] == []
    end

    test "answers not_a_git_repository for a folder that is not a repository", %{home: home} do
      start_selection(home)
      plain = Path.join(home, "plain-folder")
      File.mkdir_p!(plain)
      payload = request_payload()

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert :ok = RepositorySelection.answer(payload["request_id"], plain)

      assert_receive {:selection_result, result}

      assert result == %{
               "request_id" => payload["request_id"],
               "outcome" => "not_a_git_repository"
             }
    end

    test "answers inaccessible for a folder that is not there", %{home: home} do
      start_selection(home)
      payload = request_payload()

      :ok = RepositorySelection.open(payload, reply_to(self()), home)

      assert :ok =
               RepositorySelection.answer(
                 payload["request_id"],
                 Path.join(home, "never-created-#{System.unique_integer([:positive])}")
               )

      assert_receive {:selection_result, result}
      assert result == %{"request_id" => payload["request_id"], "outcome" => "inaccessible"}
    end
  end

  describe "a candidate that still carries a legacy identity" do
    test "matches its own repository, and only that repository", %{home: home} do
      workspace_id = pair!(home, Ecto.UUID.generate())
      start_selection(home)

      chosen = init_repo!(Path.join(home, "legacy-chosen"))
      other = init_repo!(Path.join(home, "legacy-other"))

      payload =
        request_payload(%{
          "candidates" => [
            %{"ref" => "legacy-same", "identity" => legacy_identity!(chosen, workspace_id)},
            %{"ref" => "legacy-other", "identity" => legacy_identity!(other, workspace_id)},
            # The same repository, salted for a workspace this worker was never
            # paired for. A legacy identity is only ever valid for its own
            # workspace, so this must not match either.
            %{
              "ref" => "legacy-foreign",
              "identity" => legacy_identity!(chosen, Ecto.UUID.generate())
            },
            %{"ref" => "portable-same", "identity" => portable_identity!(chosen)},
            %{"ref" => "portable-other", "identity" => portable_identity!(other)}
          ]
        })

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert :ok = RepositorySelection.answer(payload["request_id"], chosen)

      assert_receive {:selection_result, result}
      assert result["outcome"] == "selected"
      assert result["matches"] == ["legacy-same", "portable-same"]
    end

    test "cannot be matched by a worker that has no stored workspace", %{home: home} do
      workspace_id = Ecto.UUID.generate()
      start_selection(home)

      chosen = init_repo!(Path.join(home, "legacy-unpaired"))

      payload =
        request_payload(%{
          "candidates" => [
            %{"ref" => "legacy", "identity" => legacy_identity!(chosen, workspace_id)},
            %{"ref" => "portable", "identity" => portable_identity!(chosen)}
          ]
        })

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert :ok = RepositorySelection.answer(payload["request_id"], chosen)

      # No configuration on disk means no salt, so a legacy candidate is
      # reported as no match rather than guessed at. A portable identity needs
      # no workspace and still matches.
      assert_receive {:selection_result, result}
      assert result["matches"] == ["portable"]
    end
  end

  describe "the answer file" do
    test "is deleted as soon as the answer is read", %{home: home} do
      start_selection(home)
      chosen = init_repo!(Path.join(home, "answered-by-file"))
      payload = request_payload()

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      # The request must be held before the answer is written: opening discards
      # a leftover answer, so a file written first would be the one it discards.
      assert RepositorySelection.pending() == payload["request_id"]

      write_answer!(home, %{"request_id" => payload["request_id"], "path" => chosen})

      assert_receive {:selection_result, result}, 2_000
      assert result["outcome"] == "selected"
      assert result["folder_name"] == "answered-by-file"

      refute File.exists?(RepositorySelection.answer_path(home))
      refute File.exists?(RepositorySelection.pending_path(home))
      assert RepositorySelection.pending() == nil
    end

    test "answers cancelled when the person dismissed the panel", %{home: home} do
      start_selection(home)
      payload = request_payload()

      :ok = RepositorySelection.open(payload, reply_to(self()), home)
      assert RepositorySelection.pending() == payload["request_id"]

      write_answer!(home, %{"request_id" => payload["request_id"], "cancelled" => true})

      assert_receive {:selection_result, result}, 2_000
      assert result == %{"request_id" => payload["request_id"], "outcome" => "cancelled"}

      refute File.exists?(RepositorySelection.answer_path(home))
      assert RepositorySelection.pending() == nil
    end

    test "a stale answer left on disk is deleted at start and never answered", %{home: home} do
      stale = init_repo!(Path.join(home, "stale-repository"))
      write_answer!(home, %{"request_id" => "a-request-that-is-gone", "path" => stale})

      start_selection(home)

      refute File.exists?(RepositorySelection.answer_path(home))
      assert RepositorySelection.pending() == nil

      # Nothing was read from it, so a request opened afterwards is not answered
      # by what it held.
      payload = request_payload()
      :ok = RepositorySelection.open(payload, reply_to(self()), home)

      refute_receive {:selection_result, _result}, 200
      assert RepositorySelection.pending() == payload["request_id"]
    end
  end

  test "no log line holds the chosen path", %{home: home} do
    chosen = init_repo!(Path.join(home, "never-logged-repository"))
    payload = request_payload(%{"generate" => true})

    log =
      capture_log(fn ->
        start_selection(home)
        :ok = RepositorySelection.open(payload, reply_to(self()), home)
        assert RepositorySelection.pending() == payload["request_id"]

        write_answer!(home, %{"request_id" => payload["request_id"], "path" => chosen})

        assert_receive {:selection_result, result}, 2_000
        assert result["outcome"] == "selected"
      end)

    refute log =~ chosen
    refute log =~ "never-logged-repository"
    refute log =~ home
  end
end
