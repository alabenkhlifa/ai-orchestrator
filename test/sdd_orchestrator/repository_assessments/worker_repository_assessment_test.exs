defmodule SddOrchestrator.RepositoryAssessments.WorkerRepositoryAssessmentTest do
  use ExUnit.Case, async: true

  alias SddOrchestrator.RepositoryAssessments.{
    RepositoryAssessment,
    RepositoryAssessmentCommand,
    RepositoryExecutionProfileProposalPayload,
    WorkerRepositoryAssessment
  }

  @digest String.duplicate("a", 64)
  @disclosure_digest String.duplicate("b", 64)

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "repository-assessment-#{System.unique_integer([:positive])}"
      )

    repository = Path.join(base, "repository")
    outside = Path.join(base, "outside")
    File.mkdir_p!(repository)
    File.mkdir_p!(outside)

    git!(repository, ["init", "-q"])
    git!(repository, ["config", "user.email", "task2@example.invalid"])
    git!(repository, ["config", "user.name", "Task 2"])

    File.mkdir_p!(Path.join(repository, ".github/workflows"))
    File.mkdir_p!(Path.join(repository, "apps/api"))
    File.mkdir_p!(Path.join(repository, "binary"))
    File.mkdir_p!(Path.join(repository, "node_modules/dependency"))

    malicious_marker = Path.join(base, "repository-content-was-executed")

    write!(repository, "AGENTS.md", "Never execute: touch #{malicious_marker}\n")
    write!(repository, "CONTRIBUTING.md", "Run the documented checks.\n")
    write!(repository, "package.json", ~s({"scripts":{"test":"touch #{malicious_marker}"}}\n))
    write!(repository, ".github/workflows/ci.yml", "steps:\n  - run: mix test\n")
    write!(repository, "Makefile", "test:\n\t@echo test\n")
    write!(repository, "README.md", "not an allowlisted content surface\n")
    write!(repository, "apps/api/mix.exs", "defmodule Fixture.MixProject do\nend\n")
    write!(repository, ".env", "SECRET=tracked-but-prohibited\n")
    write!(repository, "node_modules/dependency/package.json", "{\"secret\":true}\n")
    write!(repository, "binary/package.json", <<0, 1, 2, 3>>)
    write!(repository, ".gitignore", "ignored.env\n")
    write!(repository, "ignored.env", "UNTRACKED_SECRET=never-read\n")
    File.ln_s!(outside, Path.join(repository, "linked-root"))
    File.ln_s!(Path.join(outside, "AGENTS.md"), Path.join(repository, "linked-agents.md"))

    git!(repository, ["add", "."])
    git!(repository, ["commit", "-q", "-m", "fixture"])
    commit = git!(repository, ["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf!(base) end)

    %{
      base: base,
      repository: repository,
      commit: commit,
      malicious_marker: malicious_marker
    }
  end

  describe "command protocol" do
    test "round trips only the strict minimized value", context do
      command = command!(context)
      value = RepositoryAssessmentCommand.to_value(command)

      assert Map.keys(value) |> Enum.sort() ==
               ~w(assessment_id commit disclosure_digest limits project_id repository root scanner_contract_digest version worker_ref)

      assert Map.keys(value["repository"]) |> Enum.sort() == ~w(id provider)
      assert {:ok, ^command} = RepositoryAssessmentCommand.from_value(value)
      refute inspect(value) =~ context.repository
      refute inspect(value) =~ "SECRET"

      assert {:error, :invalid_command} =
               value
               |> Map.put("unexpected", true)
               |> RepositoryAssessmentCommand.from_value()

      assert {:error, :invalid_command} =
               value
               |> put_in(["limits", "max_files"], 0)
               |> RepositoryAssessmentCommand.from_value()

      refute RepositoryAssessmentCommand.valid?(%{command | limits: %{}})

      assert {:error, :invalid_command} =
               WorkerRepositoryAssessment.scan(context.repository, %{command | limits: %{}})
    end

    test "rejects a non-pending assessment, unsafe root, and widened limits", context do
      assert {:error, :invalid_command} =
               context
               |> assessment(%{state: "completed"})
               |> RepositoryAssessmentCommand.new()

      assert {:error, :invalid_command} =
               context
               |> assessment(%{root: "../escape"})
               |> RepositoryAssessmentCommand.new()

      limits =
        Map.put(
          RepositoryAssessmentCommand.default_limits(),
          :max_total_bytes,
          2 * 1_024 * 1_024 + 1
        )

      assert {:error, :invalid_command} =
               context
               |> assessment()
               |> RepositoryAssessmentCommand.new(limits)
    end
  end

  describe "bounded worker-local scan" do
    test "returns deterministic minimized high-signal findings without executing content",
         context do
      command = command!(context)

      assert {:ok, first} = WorkerRepositoryAssessment.scan(context.repository, command)
      assert {:ok, ^first} = WorkerRepositoryAssessment.scan(context.repository, command)

      assert first.status == "completed"
      assert first.commit == context.commit
      assert first.root == "."
      assert first.scanner_contract_digest == @digest
      assert first.repository == %{provider: "github", id: "repository-42"}

      assert Enum.map(first.findings, & &1.path) == [
               ".github/workflows/ci.yml",
               "AGENTS.md",
               "CONTRIBUTING.md",
               "Makefile",
               "apps/api/mix.exs",
               "package.json"
             ]

      assert Enum.all?(first.findings, fn finding ->
               Map.keys(finding) |> Enum.sort() ==
                 [:bytes, :category, :line_count, :path, :sha256] and
                 Regex.match?(~r/\A[0-9a-f]{64}\z/, finding.sha256)
             end)

      serialized = inspect(first)
      refute serialized =~ context.repository
      refute serialized =~ context.base
      refute serialized =~ "Never execute"
      refute serialized =~ "touch "
      refute File.exists?(context.malicious_marker)
    end

    test "derives only minimized explicit proposal evidence while source content stays local",
         context do
      command = command!(context)
      before = repository_snapshot(context.repository)

      assert {:ok, result, %RepositoryExecutionProfileProposalPayload{} = payload} =
               WorkerRepositoryAssessment.scan_with_proposal(context.repository, command)

      assert payload.commands == ["make test", "mix test"]
      assert payload.required_checks == ["make test", "mix test"]
      assert payload.allowed_scope == ["."]
      assert payload.gaps == []
      assert payload.conflicts == ["ambiguous_command_evidence"]
      assert payload.multi_root_blockers == ["apps/api"]
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, payload.cache_key_sha256)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, payload.evidence_sha256)
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, payload.payload_digest)

      assert RepositoryExecutionProfileProposalPayload.valid_for?(
               payload,
               command,
               completed_result!(command, result)
             )

      serialized = inspect(payload)
      refute serialized =~ context.repository
      refute serialized =~ context.base
      refute serialized =~ context.malicious_marker
      refute serialized =~ "touch"
      refute serialized =~ "Never execute"
      refute Map.has_key?(payload, :assessment_id)
      refute Map.has_key?(payload, :disclosure_digest)
      refute Map.has_key?(payload, :worker_ref)
      refute File.exists?(context.malicious_marker)
      assert repository_snapshot(context.repository) == before
    end

    test "returns stable missing-evidence blockers instead of inventing commands", context do
      root = "apps/empty"
      write!(context.repository, "#{root}/README.md", "No approved command evidence.\n")
      git!(context.repository, ["add", "#{root}/README.md"])
      git!(context.repository, ["commit", "-q", "-m", "empty root"])
      commit = git!(context.repository, ["rev-parse", "HEAD"])

      command =
        command!(%{context | commit: commit}, %{root: root})

      assert {:ok, _result, payload} =
               WorkerRepositoryAssessment.scan_with_proposal(context.repository, command)

      assert payload.commands == []
      assert payload.required_checks == []
      assert payload.allowed_scope == [root]

      assert payload.gaps == [
               "missing_project_commands",
               "missing_repository_instructions",
               "missing_required_checks"
             ]

      assert payload.conflicts == []
      assert payload.multi_root_blockers == []
    end

    test "scans an exact contained sub-root and returns paths relative to it", context do
      command = command!(context, %{root: "apps/api"})

      assert {:ok, result} = WorkerRepositoryAssessment.scan(context.repository, command)
      assert result.root == "apps/api"
      assert Enum.map(result.findings, & &1.path) == ["mix.exs"]
      assert result.structure == [%{kind: "file", path: "mix.exs"}]
    end

    test "reads the authorized commit instead of modified working-tree content", context do
      command = command!(context)
      committed_content = "Never execute: touch #{context.malicious_marker}\n"
      write!(context.repository, "AGENTS.md", "WORKING_TREE_SECRET\n")

      assert {:ok, result} = WorkerRepositoryAssessment.scan(context.repository, command)
      finding = Enum.find(result.findings, &(&1.path == "AGENTS.md"))

      assert finding.sha256 ==
               committed_content
               |> then(&:crypto.hash(:sha256, &1))
               |> Base.encode16(case: :lower)

      refute inspect(result) =~ "WORKING_TREE_SECRET"
    end

    test "excludes tracked secrets, ignored and untracked content, generated stores, symlinks, and binaries",
         context do
      assert {:ok, result} =
               WorkerRepositoryAssessment.scan(context.repository, command!(context))

      exposed = inspect(%{findings: result.findings, structure: result.structure})

      for prohibited <- [
            ".env",
            "ignored.env",
            "node_modules",
            "linked-root",
            "linked-agents",
            "binary/package.json",
            "UNTRACKED_SECRET",
            "tracked-but-prohibited"
          ] do
        refute exposed =~ prohibited
      end
    end

    test "rejects a root that is a symlink instead of following it", context do
      command = command!(context, %{root: "linked-root"})

      assert {:error, :root_escape} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "fails closed when HEAD no longer matches the authorized exact commit", context do
      command = command!(context)
      write!(context.repository, "new.txt", "new commit\n")
      git!(context.repository, ["add", "new.txt"])
      git!(context.repository, ["commit", "-q", "-m", "changed"])

      assert {:error, :stale_commit} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "enforces the discovered-path limit", context do
      command = command!(context, %{}, %{max_paths: 2})

      assert {:error, :path_limit_exceeded} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "enforces the allowlisted-file limit", context do
      command = command!(context, %{}, %{max_files: 2})

      assert {:error, :file_limit_exceeded} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "enforces the per-file byte limit before reading content", context do
      command = command!(context, %{}, %{max_file_bytes: 8})

      assert {:error, :file_size_limit_exceeded} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "enforces the total byte limit across otherwise valid files", context do
      command =
        command!(context, %{}, %{
          max_file_bytes: 256,
          max_total_bytes: 256
        })

      assert {:error, :total_byte_limit_exceeded} =
               WorkerRepositoryAssessment.scan(context.repository, command)
    end

    test "enforces the time limit with an injected monotonic clock", context do
      clock = :atomics.new(1, [])
      now_ms = fn -> :atomics.add_get(clock, 1, 1) end
      command = command!(context, %{}, %{timeout_ms: 1})

      assert {:error, :time_limit_exceeded} =
               WorkerRepositoryAssessment.scan(context.repository, command, now_ms: now_ms)
    end

    test "reports bounded progress without paths or content", context do
      parent = self()

      on_progress = fn progress ->
        send(parent, {:progress, progress})
        :ok
      end

      assert {:ok, _result} =
               WorkerRepositoryAssessment.scan(context.repository, command!(context),
                 on_progress: on_progress
               )

      progress = drain_progress([])
      assert List.first(progress).phase == "enumerating"
      assert List.last(progress).phase == "completed"
      assert Enum.any?(progress, &(&1.phase == "scanning"))

      assert Enum.all?(progress, fn event ->
               Map.keys(event) |> Enum.sort() ==
                 [:bytes_read, :discovered_paths, :inspected_files, :phase] and
                 not (inspect(event) =~ context.repository)
             end)
    end

    test "cancellation stops processing without a successful result", context do
      checks = :atomics.new(1, [])
      cancelled? = fn -> :atomics.add_get(checks, 1, 1) >= 3 end
      before = repository_snapshot(context.repository)

      assert {:error, :canceled} =
               WorkerRepositoryAssessment.scan(context.repository, command!(context),
                 cancelled?: cancelled?
               )

      assert repository_snapshot(context.repository) == before
    end

    test "does not change working tree, index, refs, config, hooks, or committed content",
         context do
      before = repository_snapshot(context.repository)

      assert {:ok, _result} =
               WorkerRepositoryAssessment.scan(context.repository, command!(context))

      assert repository_snapshot(context.repository) == before
    end
  end

  defp command!(context, assessment_overrides \\ %{}, limit_overrides \\ %{}) do
    limits = Map.merge(RepositoryAssessmentCommand.default_limits(), limit_overrides)

    assert {:ok, command} =
             RepositoryAssessmentCommand.new(assessment(context, assessment_overrides), limits)

    command
  end

  defp completed_result!(command, worker_result) do
    assert {:ok, result} =
             SddOrchestrator.RepositoryAssessments.RepositoryAssessmentResult.completed(
               command,
               worker_result
             )

    result
  end

  defp assessment(context, overrides \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      repository_provider: "github",
      repository_id: "repository-42",
      root: ".",
      commit: context.commit,
      scanner_contract_digest: @digest,
      disclosure_digest: @disclosure_digest,
      worker_ref: Ecto.UUID.generate(),
      state: RepositoryAssessment.pending_state()
    }

    struct!(RepositoryAssessment, Map.merge(defaults, overrides))
  end

  defp repository_snapshot(repository) do
    %{
      head: git!(repository, ["rev-parse", "HEAD"]),
      tree: git!(repository, ["rev-parse", "HEAD^{tree}"]),
      status: git!(repository, ["status", "--porcelain=v2", "--untracked-files=all"]),
      index: file_digest(Path.join(repository, ".git/index")),
      config: file_digest(Path.join(repository, ".git/config")),
      refs: git!(repository, ["for-each-ref", "--format=%(refname):%(objectname)"]),
      hooks: Path.join(repository, ".git/hooks") |> File.ls!() |> Enum.sort()
    }
  end

  defp file_digest(path), do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1))

  defp drain_progress(events) do
    receive do
      {:progress, event} -> drain_progress([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp write!(repository, relative_path, content) do
    path = Path.join(repository, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp git!(repository, args) do
    {output, 0} = System.cmd("git", ["-C", repository | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
