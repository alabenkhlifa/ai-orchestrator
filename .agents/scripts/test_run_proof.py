#!/usr/bin/env python3
"""Tests for the focused and slice proof command runner."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("run_proof.py")

sys.path.insert(0, str(SCRIPT.parent))

import run_proof  # noqa: E402
import validate_spec  # noqa: E402


REPORT_PARTITION = """
import os
print(os.environ.get("MIX_TEST_PARTITION", "<unset>"))
"""


class ProofRunnerHarness(unittest.TestCase):
    """Shared fixtures for driving `run_proof.py` as a real subprocess."""

    def run_proof(
        self,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

    def make_executable(self, directory: Path, body: str, name: str = "fixture-command") -> Path:
        executable = directory / name
        executable.write_text(
            "#!/usr/bin/env python3\n" + textwrap.dedent(body),
            encoding="utf-8",
        )
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        return executable

    def environment_without_partition(self, *path_entries: str) -> dict[str, str]:
        environment = os.environ.copy()
        environment.pop("MIX_TEST_PARTITION", None)
        if path_entries:
            environment["PATH"] = os.pathsep.join(
                [*path_entries, os.environ.get("PATH", "")]
            )
        return environment

    def derived_partition(self) -> str:
        return str(run_proof.worktree_partition(run_proof.worktree_root()))

    def assert_rejected(self, *command: str) -> None:
        result = self.run_proof("task", "--task", "35", "--", *command)
        self.assertEqual(2, result.returncode, result)
        self.assertIn("task proof rejects", result.stderr)
        self.assertNotIn("Proof receipt", result.stdout)


class RunProofTests(ProofRunnerHarness):
    def test_task_scope_allows_focused_mix_test_paths_and_selectors(self) -> None:
        allowed_commands = (
            ("mix", "test", "test/example_test.exs"),
            ("mix", "test", "test/example_test.exs:42"),
            ("mix", "test", "--only", "integration"),
            ("mix", "test", "--only=integration"),
            ("mix", "test", "--failed"),
            ("mix", "test", "--stale"),
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            self.make_executable(temporary_path, "raise SystemExit(0)\n", name="mix")
            environment_path = f"PATH={temporary_directory}{os.pathsep}{os.environ.get('PATH', '')}"
            for command in allowed_commands:
                with self.subTest(command=command):
                    result = self.run_proof(
                        "task",
                        "--task",
                        "35",
                        "--",
                        environment_path,
                        *command,
                    )
                    self.assertEqual(0, result.returncode, result)
                    self.assertIn("scope `Focused`", result.stdout)

    def test_task_scope_rejects_unscoped_mix_test(self) -> None:
        self.assert_rejected("mix", "test")
        self.assert_rejected("/usr/local/bin/mix", "test")
        self.assert_rejected("mix", "test", "--warnings-as-errors")
        self.assert_rejected("mix", "test", "--seed", "0")
        self.assert_rejected("mix", "test", "--only")

    def test_task_scope_rejects_broad_mix_gates(self) -> None:
        for mix_task in ("check", "credo", "dialyzer", "deps.audit", "sobelow"):
            with self.subTest(mix_task=mix_task):
                self.assert_rejected("mix", mix_task)

    def test_task_scope_rejects_shell_env_and_mix_do_wrappers(self) -> None:
        for command in (
            ("/bin/sh", "-c", "mix test"),
            ("bash", "-c", "mix check"),
            ("zsh", "-c", "mix dialyzer"),
            ("fish", "-c", "mix deps.audit"),
            ("env", "MIX_ENV=prod", "mix", "release"),
            ("mix", "do", "test", ",", "dialyzer"),
        ):
            with self.subTest(command=command):
                self.assert_rejected(*command)

    def test_task_scope_rejects_package_installation_commands(self) -> None:
        for command in (
            ("npm", "ci"),
            ("npm", "install"),
            ("pnpm", "install"),
            ("pnpm", "ci"),
            ("yarn", "install"),
            ("npm", "--prefix", "assets", "ci"),
        ):
            with self.subTest(command=command):
                self.assert_rejected(*command)

    def test_task_scope_rejects_unscoped_e2e_and_allows_selector_arguments(self) -> None:
        self.assert_rejected("npm", "--prefix", "assets", "run", "test:e2e")
        self.assert_rejected("pnpm", "run", "test:e2e", "--")
        for operational_arguments in (
            ("--project", "chromium"),
            ("--headed",),
            ("--workers", "1"),
            ("--reporter=list",),
            ("--grep",),
            ("--grep", "--headed"),
            ("--grep=",),
        ):
            with self.subTest(operational_arguments=operational_arguments):
                self.assert_rejected(
                    "npm",
                    "--prefix",
                    "assets",
                    "run",
                    "test:e2e",
                    "--",
                    *operational_arguments,
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), "raise SystemExit(0)\n", name="npm")
            environment_path = f"PATH={temporary_directory}{os.pathsep}{os.environ.get('PATH', '')}"
            focused_selectors = (
                ("--grep", "@task-35"),
                ("--grep=@task-35",),
                ("--last-failed",),
                ("test/e2e/task_35.spec.ts",),
            )
            for selectors in focused_selectors:
                with self.subTest(selectors=selectors):
                    result = self.run_proof(
                        "task",
                        "--task",
                        "35",
                        "--",
                        environment_path,
                        "npm",
                        "--prefix",
                        "assets",
                        "run",
                        "test:e2e",
                        "--",
                        *selectors,
                    )
                    self.assertEqual(0, result.returncode, result)
                    self.assertIn("scope `Focused`", result.stdout)

    def test_task_scope_rejects_production_asset_and_release_gates(self) -> None:
        self.assert_rejected("MIX_ENV=prod", "mix", "assets.deploy")
        self.assert_rejected("MIX_ENV=prod", "mix", "release")

        inherited_environment = os.environ.copy()
        inherited_environment["MIX_ENV"] = "prod"
        result = self.run_proof(
            "task",
            "--task",
            "35",
            "--",
            "mix",
            "release",
            environment=inherited_environment,
        )
        self.assertEqual(2, result.returncode, result)
        self.assertIn("task proof rejects", result.stderr)

    def test_environment_assignments_are_passed_without_a_shell(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = self.make_executable(
                Path(temporary_directory),
                """
                import os
                import sys
                print(os.environ["PROOF_VALUE"])
                print(sys.argv[1])
                """,
            )
            result = self.run_proof(
                "task",
                "--task",
                "7",
                "--",
                "PROOF_VALUE=kept verbatim",
                str(executable),
                "$(printf not-a-shell)",
            )

        self.assertEqual(0, result.returncode, result)
        lines = result.stdout.splitlines()
        self.assertEqual("kept verbatim", lines[0])
        self.assertEqual("$(printf not-a-shell)", lines[1])
        self.assertEqual(
            "- Proof receipt: `Task 7` — scope `Focused` — "
            f"command `'PROOF_VALUE=kept verbatim' {executable} '$(printf not-a-shell)'` — exit `0`.",
            lines[2],
        )

    def test_success_prints_exact_task_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = self.make_executable(Path(temporary_directory), "raise SystemExit(0)\n")
            result = self.run_proof("task", "--task", "35", "--", str(executable), "proof arg")

        self.assertEqual(0, result.returncode, result)
        self.assertEqual(
            "- Proof receipt: `Task 35` — scope `Focused` — "
            f"command `{executable} 'proof arg'` — exit `0`.\n",
            result.stdout,
        )
        self.assertEqual("", result.stderr)

    def test_explicit_broad_task_scope_permits_full_gate_and_marks_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), "raise SystemExit(0)\n", name="mix")
            environment_path = f"PATH={temporary_directory}{os.pathsep}{os.environ.get('PATH', '')}"
            result = self.run_proof(
                "task",
                "--task",
                "35",
                "--broad",
                "--",
                environment_path,
                "mix",
                "test",
            )

        self.assertEqual(0, result.returncode, result)
        self.assertEqual(
            "- Proof receipt: `Task 35` — scope `Broad` — "
            f"command `'{environment_path}' mix test` — exit `0`.\n",
            result.stdout,
        )

    def test_slice_scope_permits_broad_commands_and_prints_exact_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), "raise SystemExit(0)\n", name="mix")
            environment_path = f"PATH={temporary_directory}{os.pathsep}{os.environ.get('PATH', '')}"
            result = self.run_proof("slice", "--", environment_path, "mix", "test")

        self.assertEqual(0, result.returncode, result)
        self.assertEqual(
            "- Proof receipt: slice — scope `Broad` — "
            f"command `'{environment_path}' mix test` — exit `0`.\n",
            result.stdout,
        )

    def test_failure_preserves_exit_status_and_prints_no_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            executable = self.make_executable(
                Path(temporary_directory),
                """
                import sys
                print("fixture failed")
                raise SystemExit(23)
                """,
            )
            result = self.run_proof("task", "--task", "9", "--", str(executable))

        self.assertEqual(23, result.returncode, result)
        self.assertEqual("fixture failed\n", result.stdout)
        self.assertNotIn("Proof receipt", result.stdout)

    def test_missing_executable_returns_127_without_receipt(self) -> None:
        result = self.run_proof("slice", "--", "definitely-not-a-proof-command")
        self.assertEqual(127, result.returncode, result)
        self.assertIn("proof command not found", result.stderr)
        self.assertNotIn("Proof receipt", result.stdout)

    def test_missing_command_and_invalid_task_number_are_usage_errors(self) -> None:
        missing = self.run_proof("task", "--task", "3", "--", "ONLY_ENV=value")
        invalid = self.run_proof("task", "--task", "0", "--", "true")
        self.assertEqual(2, missing.returncode, missing)
        self.assertEqual(2, invalid.returncode, invalid)
        self.assertNotIn("Proof receipt", missing.stdout)
        self.assertNotIn("Proof receipt", invalid.stdout)


class WorktreePartitionTests(unittest.TestCase):
    WORKTREE_ROOTS = (
        "/Users/example/IdeaProjects/sdd-orchestrator",
        "/Users/example/IdeaProjects/sdd-orchestrator-s08",
        "/Users/example/IdeaProjects/sdd-orchestrator-s11",
        "/Users/example/IdeaProjects/sdd-orchestrator-s14",
        "/Users/example/IdeaProjects/sdd-orchestrator-s25",
        "/Users/other/IdeaProjects/sdd-orchestrator",
    )

    def test_derivation_repeats_for_the_same_worktree_root(self) -> None:
        for root in self.WORKTREE_ROOTS:
            with self.subTest(root=root):
                self.assertEqual(
                    run_proof.worktree_partition(root),
                    run_proof.worktree_partition(root),
                )

    def test_derivation_differs_across_worktree_roots_and_stays_in_range(self) -> None:
        derived = [run_proof.worktree_partition(root) for root in self.WORKTREE_ROOTS]
        self.assertEqual(len(set(derived)), len(derived), derived)
        for partition in derived:
            with self.subTest(partition=partition):
                self.assertGreaterEqual(partition, 100_000)
                self.assertLess(partition, 1_000_000)

    def test_derivation_is_stable_across_interpreter_processes(self) -> None:
        root = self.WORKTREE_ROOTS[0]
        program = (
            "import sys; sys.path.insert(0, sys.argv[1]); "
            "import run_proof; print(run_proof.worktree_partition(sys.argv[2]))"
        )
        seeds = ("0", "1", "random")
        outputs = set()
        for seed in seeds:
            environment = os.environ.copy()
            environment["PYTHONHASHSEED"] = seed
            completed = subprocess.run(
                [sys.executable, "-c", program, str(SCRIPT.parent), root],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(0, completed.returncode, completed)
            outputs.add(completed.stdout.strip())
        self.assertEqual({str(run_proof.worktree_partition(root))}, outputs)

    def test_worktree_root_resolves_the_current_git_worktree(self) -> None:
        completed = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(SCRIPT.parent),
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            self.skipTest("not inside a git worktree")
        self.assertEqual(
            os.path.realpath(completed.stdout.strip()),
            run_proof.worktree_root(str(SCRIPT.parent)),
        )

    def test_worktree_root_falls_back_to_the_directory_outside_git(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = os.environ.copy()
            environment["PATH"] = temporary_directory
            program = (
                "import sys; sys.path.insert(0, sys.argv[1]); "
                "import run_proof; print(run_proof.worktree_root(sys.argv[2]))"
            )
            completed = subprocess.run(
                [sys.executable, "-c", program, str(SCRIPT.parent), temporary_directory],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(0, completed.returncode, completed)
            self.assertEqual(
                os.path.realpath(temporary_directory),
                completed.stdout.strip(),
            )


class TestPartitionInjectionTests(ProofRunnerHarness):
    def test_focused_mix_test_receives_a_stable_worktree_partition(self) -> None:
        expected = self.derived_partition()
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), REPORT_PARTITION, name="mix")
            environment = self.environment_without_partition(temporary_directory)
            first = self.run_proof(
                "task", "--task", "35", "--",
                "mix", "test", "test/example_test.exs",
                environment=environment,
            )
            second = self.run_proof(
                "task", "--task", "35", "--",
                "mix", "test", "test/example_test.exs",
                environment=environment,
            )

        self.assertEqual(0, first.returncode, first)
        self.assertEqual(expected, first.stdout.splitlines()[0])
        self.assertEqual(first.stdout, second.stdout)
        self.assertIn(f"MIX_TEST_PARTITION={expected}", first.stderr)

    def test_derived_partition_never_reaches_the_rendered_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), REPORT_PARTITION, name="mix")
            environment = self.environment_without_partition(temporary_directory)
            result = self.run_proof(
                "task", "--task", "35", "--",
                "mix", "test", "test/example_test.exs",
                environment=environment,
            )

        self.assertEqual(0, result.returncode, result)
        receipt_line = result.stdout.splitlines()[-1]
        self.assertEqual(
            "- Proof receipt: `Task 35` — scope `Focused` — "
            "command `mix test test/example_test.exs` — exit `0`.",
            receipt_line,
        )
        match = validate_spec.PROOF_RECEIPT_RE.match(receipt_line)
        self.assertIsNotNone(match, receipt_line)
        self.assertEqual("Task 35", match.group("task"))
        self.assertEqual("Focused", match.group("scope"))
        self.assertEqual("mix test test/example_test.exs", match.group("command"))
        self.assertNotIn("MIX_TEST_PARTITION", match.group("command"))

    def test_caller_supplied_partition_wins_over_derivation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), REPORT_PARTITION, name="mix")
            environment = self.environment_without_partition(temporary_directory)
            assigned = self.run_proof(
                "task", "--task", "35", "--",
                "MIX_TEST_PARTITION=110",
                "mix", "test", "test/example_test.exs",
                environment=environment,
            )
            inherited = self.run_proof(
                "task", "--task", "35", "--",
                "mix", "test", "test/example_test.exs",
                environment=dict(environment, MIX_TEST_PARTITION="207"),
            )

        self.assertEqual(0, assigned.returncode, assigned)
        self.assertEqual("110", assigned.stdout.splitlines()[0])
        self.assertEqual("", assigned.stderr)
        self.assertEqual(
            "- Proof receipt: `Task 35` — scope `Focused` — "
            "command `MIX_TEST_PARTITION=110 mix test test/example_test.exs` — exit `0`.",
            assigned.stdout.splitlines()[-1],
        )
        self.assertEqual(0, inherited.returncode, inherited)
        self.assertEqual("207", inherited.stdout.splitlines()[0])
        self.assertEqual("", inherited.stderr)

    def test_non_mix_test_commands_receive_no_partition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            self.make_executable(temporary_path, REPORT_PARTITION, name="mix")
            self.make_executable(temporary_path, REPORT_PARTITION, name="npm")
            environment = self.environment_without_partition(temporary_directory)
            for command in (
                ("mix", "format", "--check-formatted"),
                ("npm", "--prefix", "assets", "run", "test:e2e", "--", "--last-failed"),
            ):
                with self.subTest(command=command):
                    result = self.run_proof(
                        "task", "--task", "35", "--", *command, environment=environment
                    )
                    self.assertEqual(0, result.returncode, result)
                    self.assertEqual("<unset>", result.stdout.splitlines()[0])
                    self.assertEqual("", result.stderr)

    def test_slice_scope_receives_no_partition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), REPORT_PARTITION, name="mix")
            environment = self.environment_without_partition(temporary_directory)
            result = self.run_proof("slice", "--", "mix", "test", environment=environment)

        self.assertEqual(0, result.returncode, result)
        self.assertEqual("<unset>", result.stdout.splitlines()[0])
        self.assertEqual("", result.stderr)

    def test_broad_task_scope_still_receives_the_worktree_partition(self) -> None:
        expected = self.derived_partition()
        with tempfile.TemporaryDirectory() as temporary_directory:
            self.make_executable(Path(temporary_directory), REPORT_PARTITION, name="mix")
            environment = self.environment_without_partition(temporary_directory)
            result = self.run_proof(
                "task", "--task", "35", "--broad", "--", "mix", "test",
                environment=environment,
            )

        self.assertEqual(0, result.returncode, result)
        self.assertEqual(expected, result.stdout.splitlines()[0])
        self.assertEqual(
            "- Proof receipt: `Task 35` — scope `Broad` — command `mix test` — exit `0`.",
            result.stdout.splitlines()[-1],
        )


if __name__ == "__main__":
    unittest.main()
