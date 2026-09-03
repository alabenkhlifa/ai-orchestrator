defmodule SddOrchestrator.Worker.RepositoryMetadataTest do
  @moduledoc """
  Task 5 proof: the worker release turns a folder the person points at into
  the four fields the control plane's adapter contract allows, holds it in
  memory for the life of one binding attempt, and answers a second question
  for the same `selection_ref` without opening a second panel.

  Covers AC-03, AC-07, AC-08: a matching folder answers the four fields, a
  non-matching folder is refused and holds nothing, a held folder answers a
  revalidate with no panel, and a held folder is dropped at its expiry.

  `async: false` because it starts two named GenServers and works on the
  real filesystem under a temporary storage root.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.Worker.RepositoryMetadata
  alias SddOrchestrator.Worker.RepositorySelection

  # Short enough that a test waiting for the answer file to be picked up does
  # not wait on the production half-second, and still a real timer tick.
  @poll_interval 25

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "worker_repository_metadata_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    start_supervised!(
      {RepositorySelection, home_override: home, poll_interval: @poll_interval},
      restart: :temporary
    )

    start_supervised!({RepositoryMetadata, home_override: home}, restart: :temporary)

    %{home: home}
  end

  # The answer payload comes back through the same one-argument function the
  # gateway connection gives the request, so a test reads it as a message.
  defp reply_to(pid), do: fn payload -> send(pid, {:metadata_result, payload}) end

  defp request_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "request_id" => "request-#{System.unique_integer([:positive])}",
        "selection_ref" => "selection-#{System.unique_integer([:positive])}",
        "repository_provider" => "github",
        "repository_id" => nil,
        "selected_root" => ".",
        "expires_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  # The same fixture shape `RepositorySelectionTest` builds: a real
  # repository whose distinct first blob gives it a root commit unrelated to
  # any other fixture's.
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

  defp portable_identity!(path) do
    {:ok, identity} = PortableRepositoryIdentity.generate(path)
    identity
  end

  # Written the way the Mac app writes it, by renaming a complete neighbour
  # over the target, exactly as `RepositorySelectionTest` does.
  defp write_answer!(home, contents) do
    path = RepositorySelection.answer_path(home)
    temporary = path <> ".partial"

    File.write!(temporary, Jason.encode!(contents))
    File.rename!(temporary, path)
  end

  # `RepositoryMetadata`'s prepare path hands `RepositorySelection` a payload
  # whose own internal request id is the `selection_ref`, so a test answers
  # the underlying panel by that name, not by the wire `request_id`.
  defp answer_panel!(selection_ref, choice) do
    assert :ok = RepositorySelection.answer(selection_ref, choice)
  end

  # `RepositoryMetadata.open/3` is a cast, and reaching `RepositorySelection`
  # from it crosses a second process boundary (`RepositoryMetadata` ->
  # `RepositorySelection`), so a bare read of `RepositorySelection.pending()`
  # right after `open/3` can race ahead of the cast being processed. Every
  # place that depends on the panel already being open waits for it here
  # first.
  defp wait_for_pending!(expected) do
    wait_until(fn -> RepositorySelection.pending() == expected end)
  end

  defp wait_until(fun, attempts \\ 80)
  defp wait_until(_fun, 0), do: flunk("condition was never met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  describe "a first question for a selection_ref" do
    test "answered with a matching real repository replies metadata with the four fields", %{
      home: home
    } do
      repo = init_repo!(Path.join(home, "matching-repository"))
      identity = portable_identity!(repo)

      payload = request_payload(%{"repository_id" => identity})

      :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
      wait_for_pending!(payload["selection_ref"])

      answer_panel!(payload["selection_ref"], repo)

      assert_receive {:metadata_result, result}, 2_000
      assert result["request_id"] == payload["request_id"]
      assert result["outcome"] == "metadata"
      assert result["repository_provider"] == "github"
      assert result["repository_id"] == identity
      assert result["root"] == "."
      assert is_binary(result["commit"])
      assert String.length(result["commit"]) == 40
    end

    test "a second question with the same selection_ref resolves with no panel opened", %{
      home: home
    } do
      repo = init_repo!(Path.join(home, "revalidated-repository"))
      identity = portable_identity!(repo)
      selection_ref = "shared-selection-ref"

      first = request_payload(%{"selection_ref" => selection_ref, "repository_id" => identity})

      :ok = RepositoryMetadata.open(first, reply_to(self()), home)
      wait_for_pending!(selection_ref)
      answer_panel!(selection_ref, repo)

      assert_receive {:metadata_result, first_result}, 2_000
      assert first_result["outcome"] == "metadata"
      assert RepositorySelection.pending() == nil

      second = request_payload(%{"selection_ref" => selection_ref, "repository_id" => identity})
      :ok = RepositoryMetadata.open(second, reply_to(self()), home)

      # The revalidate path never touches `RepositorySelection`: nothing was
      # pending before this call, and nothing becomes pending because of it.
      assert_receive {:metadata_result, second_result}, 500
      assert RepositorySelection.pending() == nil

      assert second_result["request_id"] == second["request_id"]
      assert second_result["outcome"] == "metadata"
      assert second_result["repository_id"] == identity
      assert second_result["commit"] == first_result["commit"]
    end
  end

  describe "a folder that does not match the expected identity" do
    test "replies refused with repository_mismatch and holds nothing", %{home: home} do
      repo = init_repo!(Path.join(home, "mismatched-repository"))
      other = init_repo!(Path.join(home, "other-repository"))
      other_identity = portable_identity!(other)
      selection_ref = "mismatch-selection-ref"

      payload =
        request_payload(%{"selection_ref" => selection_ref, "repository_id" => other_identity})

      :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
      wait_for_pending!(selection_ref)
      answer_panel!(selection_ref, repo)

      assert_receive {:metadata_result, result}, 2_000

      assert result == %{
               "request_id" => payload["request_id"],
               "outcome" => "refused",
               "reason" => "repository_mismatch"
             }

      # Nothing was held, so a second question for the same reference opens a
      # brand new panel rather than reusing anything.
      second =
        request_payload(%{"selection_ref" => selection_ref, "repository_id" => other_identity})

      :ok = RepositoryMetadata.open(second, reply_to(self()), home)
      wait_for_pending!(selection_ref)
    end
  end

  describe "an expired held entry" do
    test "is treated as not held, and a new panel opens", %{home: home} do
      repo = init_repo!(Path.join(home, "expiring-repository"))
      identity = portable_identity!(repo)
      selection_ref = "expiring-selection-ref"

      short_expiry = DateTime.utc_now() |> DateTime.add(1) |> DateTime.to_iso8601()

      first =
        request_payload(%{
          "selection_ref" => selection_ref,
          "repository_id" => identity,
          "expires_at" => short_expiry
        })

      :ok = RepositoryMetadata.open(first, reply_to(self()), home)
      wait_for_pending!(selection_ref)
      answer_panel!(selection_ref, repo)

      assert_receive {:metadata_result, first_result}, 2_000
      assert first_result["outcome"] == "metadata"

      # Let the held entry's own expiry pass.
      Process.sleep(1_100)

      second = request_payload(%{"selection_ref" => selection_ref, "repository_id" => identity})
      :ok = RepositoryMetadata.open(second, reply_to(self()), home)
      wait_for_pending!(selection_ref)

      answer_panel!(selection_ref, repo)
      assert_receive {:metadata_result, second_result}, 2_000
      assert second_result["outcome"] == "metadata"
    end
  end

  describe "close/1" do
    test "cancels the in-flight, awaiting-a-panel question and replies cancelled", %{home: home} do
      payload = request_payload()

      :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
      wait_for_pending!(payload["selection_ref"])

      :ok = RepositoryMetadata.close(payload["request_id"])

      # `RepositorySelection.close/1` removes the pending file directly and
      # sends no further path answer, so nothing here ever answers
      # `open/3`'s own `reply` for this question.
      wait_until(fn -> RepositorySelection.pending() == nil end)
      refute_receive {:metadata_result, _payload}, 100
    end

    test "an unrelated request_id changes nothing", %{home: home} do
      payload = request_payload()

      :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
      wait_for_pending!(payload["selection_ref"])

      :ok = RepositoryMetadata.close("some-other-request-id")

      assert RepositorySelection.pending() == payload["selection_ref"]

      repo = init_repo!(Path.join(home, "still-open-after-unrelated-close"))
      answer_panel!(payload["selection_ref"], repo)

      assert_receive {:metadata_result, result}, 2_000
      assert result["request_id"] == payload["request_id"]
    end
  end

  describe "the person dismissing the panel" do
    test "replies cancelled and holds nothing", %{home: home} do
      payload = request_payload()

      :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
      wait_for_pending!(payload["selection_ref"])

      write_answer!(home, %{"request_id" => payload["selection_ref"], "cancelled" => true})

      assert_receive {:metadata_result, result}, 2_000
      assert result == %{"request_id" => payload["request_id"], "outcome" => "cancelled"}

      # Nothing was held, so the next question for the same reference opens a
      # new panel.
      second = request_payload(%{"selection_ref" => payload["selection_ref"]})
      :ok = RepositoryMetadata.open(second, reply_to(self()), home)
      wait_for_pending!(payload["selection_ref"])
    end
  end

  test "no log line holds the real repository path across a full successful flow", %{home: home} do
    repo = init_repo!(Path.join(home, "never-logged-metadata-repository"))
    identity = portable_identity!(repo)
    payload = request_payload(%{"repository_id" => identity})

    log =
      capture_log(fn ->
        :ok = RepositoryMetadata.open(payload, reply_to(self()), home)
        wait_for_pending!(payload["selection_ref"])

        answer_panel!(payload["selection_ref"], repo)

        assert_receive {:metadata_result, result}, 2_000
        assert result["outcome"] == "metadata"
      end)

    refute log =~ repo
    refute log =~ "never-logged-metadata-repository"
    refute log =~ home
  end
end
