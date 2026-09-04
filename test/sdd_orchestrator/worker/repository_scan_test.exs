defmodule SddOrchestrator.Worker.RepositoryScanTest do
  @moduledoc """
  Task 7 proof: the worker scans the folder it is already holding.

  Covers AC-09. A scan of a binding names the `selection_ref` the binding was
  verified under, so the folder is read from
  `SddOrchestrator.Worker.RepositoryMetadata` rather than asked for again. A
  hold that is gone is refused as expired with no panel opened, and a
  repository that has moved off the command's commit is refused by the
  scanner's own exact-commit check.

  `async: false` because it starts named GenServers and works on the real
  filesystem under a temporary storage root.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SddOrchestrator.Devices.PortableRepositoryIdentity
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessment
  alias SddOrchestrator.RepositoryAssessments.RepositoryAssessmentCommand
  alias SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentCache
  alias SddOrchestrator.Worker.RepositoryMetadata
  alias SddOrchestrator.Worker.RepositoryScan
  alias SddOrchestrator.Worker.RepositorySelection

  @poll_interval 25
  @digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "worker_repository_scan_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    start_supervised!(
      {RepositorySelection, home_override: home, poll_interval: @poll_interval},
      restart: :temporary
    )

    start_supervised!({RepositoryMetadata, home_override: home}, restart: :temporary)

    cache = start_supervised!({WorkerRepositoryAssessmentCache, []}, restart: :temporary)
    start_supervised!({RepositoryScan, cache: cache}, restart: :temporary)

    %{home: home, cache: cache}
  end

  describe "a scan of a folder the worker is holding" do
    test "answers with the scanner's own minimized evidence and proposal", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      payload = scan_payload(repository, selection_ref)
      :ok = RepositoryScan.open(payload, reply_to(self()))

      assert_receive {:scan_result, result}, 5_000
      assert result["request_id"] == payload["request_id"]
      assert result["outcome"] == "scanned"

      paths = Enum.map(result["findings"], & &1.path)
      assert "Makefile" in paths
      assert "AGENTS.md" in paths

      assert Enum.all?(result["findings"], fn finding ->
               Map.keys(finding) |> Enum.sort() ==
                 [:bytes, :category, :line_count, :path, :sha256]
             end)

      assert Map.keys(result["stats"]) |> Enum.sort() ==
               [:bytes_read, :discovered_paths, :inspected_files]

      assert Map.keys(result["proposal"]) |> Enum.sort() ==
               [
                 :allowed_scope,
                 :commands,
                 :conflicts,
                 :gaps,
                 :multi_root_blockers,
                 :required_checks
               ]
    end

    test "opens no folder panel, before or during the scan", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      assert RepositorySelection.pending() == nil

      :ok = RepositoryScan.open(scan_payload(repository, selection_ref), reply_to(self()))

      assert_receive {:scan_result, %{"outcome" => "scanned"}}, 5_000
      assert RepositorySelection.pending() == nil
    end

    test "carries no absolute path, remote url, or file content in the answer", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      :ok = RepositoryScan.open(scan_payload(repository, selection_ref), reply_to(self()))

      assert_receive {:scan_result, result}, 5_000

      for value <- string_values(result) do
        refute String.starts_with?(value, "/"), "#{value} is an absolute path"
        refute String.contains?(value, "://"), "#{value} is a url"
        refute String.contains?(value, repository), "#{value} leaks the held path"
      end
    end
  end

  describe "a scan the worker cannot serve" do
    test "a selection_ref the worker is not holding is refused as expired, with no panel",
         context do
      %{repository: repository} = held_repository(context)

      payload = scan_payload(repository, "never-held-selection-ref")
      :ok = RepositoryScan.open(payload, reply_to(self()))

      assert_receive {:scan_result, result}, 2_000

      assert result == %{
               "request_id" => payload["request_id"],
               "outcome" => "refused",
               "reason" => "selection_expired"
             }

      assert RepositorySelection.pending() == nil
    end

    test "a repository that moved off the command's commit is refused", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      payload = scan_payload(repository, selection_ref)

      File.write!(Path.join(repository, "Makefile"), "test:\n\t@echo moved\n")
      git!(repository, ["add", "Makefile"])
      git!(repository, ["commit", "-q", "-m", "moved"])

      :ok = RepositoryScan.open(payload, reply_to(self()))

      assert_receive {:scan_result, result}, 5_000
      assert result["outcome"] == "refused"
      assert result["reason"] == "stale_commit"
    end

    test "a request with no id, no selection, or an unreadable command is dropped", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      payload = scan_payload(repository, selection_ref)

      capture_log(fn ->
        for broken <- [
              Map.delete(payload, "request_id"),
              Map.delete(payload, "selection_ref"),
              Map.put(payload, "command", %{"version" => 1}),
              Map.put(payload, "command", "a command")
            ] do
          :ok = RepositoryScan.open(broken, reply_to(self()))
        end

        refute_receive {:scan_result, _result}, 300
      end)
    end
  end

  describe "cancelling" do
    test "a cancellation answers cancelled and stops the scan", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      payload = scan_payload(repository, selection_ref)
      :ok = RepositoryScan.open(payload, reply_to(self()))
      :ok = RepositoryScan.close(payload["request_id"])

      assert_receive {:scan_result, result}, 2_000
      assert result["outcome"] in ["cancelled", "scanned"]

      # Whichever won the race, exactly one answer is sent for the request.
      refute_receive {:scan_result, _second}, 300
    end

    test "cancelling an id no scan is running under changes nothing", context do
      %{repository: repository, selection_ref: selection_ref} = held_repository(context)

      :ok = RepositoryScan.close("not-a-running-request")
      :ok = RepositoryScan.open(scan_payload(repository, selection_ref), reply_to(self()))

      assert_receive {:scan_result, %{"outcome" => "scanned"}}, 5_000
    end
  end

  # Drives one metadata question end to end so the worker is holding a folder,
  # which is the state every scan below starts from.
  defp held_repository(context) do
    repository = init_repo!(Path.join(context.home, "held-repository"))
    identity = portable_identity!(repository)
    selection_ref = "selection-#{System.unique_integer([:positive])}"

    payload = %{
      "request_id" => "metadata-#{System.unique_integer([:positive])}",
      "selection_ref" => selection_ref,
      "repository_provider" => "local",
      "repository_id" => identity,
      "selected_root" => ".",
      "expires_at" => DateTime.utc_now() |> DateTime.add(120) |> DateTime.to_iso8601()
    }

    test_process = self()
    reply = fn result -> send(test_process, {:metadata_result, result}) end

    :ok = RepositoryMetadata.open(payload, reply, context.home)
    wait_until(fn -> RepositorySelection.pending() == selection_ref end)
    assert :ok = RepositorySelection.answer(selection_ref, repository)

    assert_receive {:metadata_result, %{"outcome" => "metadata"}}, 2_000

    %{repository: repository, identity: identity, selection_ref: selection_ref}
  end

  defp scan_payload(repository, selection_ref) do
    %{
      "request_id" => "scan-#{System.unique_integer([:positive])}",
      "selection_ref" => selection_ref,
      "command" => RepositoryAssessmentCommand.to_value(command(repository)),
      "expires_at" => DateTime.utc_now() |> DateTime.add(120) |> DateTime.to_iso8601()
    }
  end

  defp command(repository) do
    assessment =
      struct!(RepositoryAssessment, %{
        id: Ecto.UUID.generate(),
        project_id: Ecto.UUID.generate(),
        repository_provider: "local",
        repository_id: portable_identity!(repository),
        root: ".",
        commit: head(repository),
        scanner_contract_digest: @digest,
        disclosure_digest: @disclosure_digest,
        worker_ref: Ecto.UUID.generate(),
        state: RepositoryAssessment.pending_state()
      })

    {:ok, command} =
      RepositoryAssessmentCommand.new(assessment, RepositoryAssessmentCommand.default_limits())

    command
  end

  defp reply_to(pid), do: fn payload -> send(pid, {:scan_result, payload}) end

  defp init_repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "t@example.test"])
    git!(dir, ["config", "user.name", "Tester"])
    File.write!(Path.join(dir, "README.md"), "seed-#{Path.basename(dir)}")
    File.write!(Path.join(dir, "AGENTS.md"), "Run the documented checks.\n")
    File.write!(Path.join(dir, "Makefile"), "test:\n\t@echo test\n")
    git!(dir, ["add", "."])
    git!(dir, ["commit", "-q", "-m", "root"])
    dir
  end

  defp head(dir) do
    {commit, 0} = System.cmd("git", ["-C", dir, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(commit)
  end

  defp portable_identity!(path) do
    {:ok, identity} = PortableRepositoryIdentity.generate(path)
    identity
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp string_values(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&string_values/1)

  defp string_values(value) when is_list(value), do: Enum.flat_map(value, &string_values/1)
  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(_value), do: []

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
end
