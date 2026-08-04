#!/usr/bin/env python3
"""Run a focused task proof or a broad slice proof and emit a receipt."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shlex
import subprocess
import sys
from collections.abc import Sequence


ENV_ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=.*$", re.DOTALL)
MIX_TEST_PARTITION = "MIX_TEST_PARTITION"
PARTITION_FLOOR = 100_000
PARTITION_SPAN = 900_000
FOCUSED_MIX_TEST_FLAGS = {"--failed", "--stale"}
FOCUSED_MIX_TEST_PREFIXES = ("--only=",)
FOCUSED_MIX_TEST_PATH_RE = re.compile(r"\.exs(?::\d+)?$")
BROAD_MIX_TASKS = {"check", "credo", "dialyzer", "deps.audit", "sobelow"}
PACKAGE_MANAGERS = {"npm", "pnpm", "yarn"}
PACKAGE_OPTIONS_WITH_VALUES = {"--cwd", "--dir", "--prefix", "--workspace", "-C", "-w"}
COMMAND_WRAPPERS = {"bash", "env", "fish", "sh", "zsh"}
E2E_FILE_SELECTOR_RE = re.compile(
    r"(?:^|/)(?:[^/]+[._-])?(?:spec|test)\.[A-Za-z0-9]+(?::\d+)?$",
    re.IGNORECASE,
)


class ProofCommandError(ValueError):
    """Raised when a proof command is missing or too broad for task scope."""


def positive_task_number(value: str) -> int:
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("task number must be an integer") from error
    if number < 1:
        raise argparse.ArgumentTypeError("task number must be positive")
    return number


def split_environment(arguments: Sequence[str]) -> tuple[dict[str, str], list[str]]:
    """Split leading KEY=VALUE assignments from the executable command."""
    environment: dict[str, str] = {}
    command_start = 0
    for command_start, argument in enumerate(arguments):
        if not ENV_ASSIGNMENT_RE.fullmatch(argument):
            break
        key, value = argument.split("=", 1)
        environment[key] = value
    else:
        command_start = len(arguments)

    command = list(arguments[command_start:])
    if not command:
        raise ProofCommandError("a command is required after environment assignments")
    return environment, command


def mix_test_is_focused(arguments: Sequence[str]) -> bool:
    """Return whether `mix test` has a path or a supported focused selector."""
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in FOCUSED_MIX_TEST_FLAGS:
            return True
        if argument.startswith(FOCUSED_MIX_TEST_PREFIXES):
            return len(argument.partition("=")[2]) > 0
        if argument == "--only":
            return index + 1 < len(arguments) and not arguments[index + 1].startswith("-")
        if not argument.startswith("-") and FOCUSED_MIX_TEST_PATH_RE.search(argument):
            return True
        index += 1
    return False


def e2e_is_focused(command: Sequence[str]) -> bool:
    """Return whether a test:e2e invocation has a concrete test selector."""
    try:
        script_index = command.index("test:e2e")
    except ValueError:
        return True
    selectors = list(command[script_index + 1 :])
    if selectors and selectors[0] == "--":
        selectors = selectors[1:]
    index = 0
    while index < len(selectors):
        selector = selectors[index]
        if selector == "--last-failed":
            return True
        if selector == "--grep":
            return (
                index + 1 < len(selectors)
                and bool(selectors[index + 1])
                and not selectors[index + 1].startswith("-")
            )
        if selector.startswith("--grep="):
            return bool(selector.partition("=")[2])
        if not selector.startswith("-") and E2E_FILE_SELECTOR_RE.search(selector):
            return True
        index += 1
    return False


def package_manager_action(arguments: Sequence[str]) -> str | None:
    """Return the package-manager action after its global options."""
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in PACKAGE_OPTIONS_WITH_VALUES:
            index += 2
            continue
        if argument.startswith("-"):
            index += 1
            continue
        return argument
    return None


def validate_task_command(command: Sequence[str], environment: dict[str, str]) -> None:
    """Reject full-suite and other broad gates from a task proof."""
    executable = os.path.basename(command[0])
    arguments = list(command[1:])

    if executable in COMMAND_WRAPPERS:
        raise ProofCommandError(f"task proof rejects command wrapper: {executable}")

    if executable == "mix" and arguments:
        mix_task = arguments[0]
        if mix_task == "do":
            raise ProofCommandError("task proof rejects command wrapper: mix do")
        if mix_task in BROAD_MIX_TASKS:
            raise ProofCommandError(f"task proof rejects broad gate: mix {mix_task}")
        if mix_task == "test" and not mix_test_is_focused(arguments[1:]):
            raise ProofCommandError(
                "task proof rejects unscoped mix test; provide a test path or "
                "--only, --failed, or --stale"
            )
        if environment.get("MIX_ENV") == "prod" and mix_task in {"assets.deploy", "release"}:
            raise ProofCommandError(f"task proof rejects production gate: mix {mix_task}")

    if executable in PACKAGE_MANAGERS:
        package_action = package_manager_action(arguments)
        if package_action in {"install", "ci"}:
            raise ProofCommandError(f"task proof rejects package installation: {executable}")
        if "test:e2e" in arguments and not e2e_is_focused(command):
            raise ProofCommandError(
                "task proof rejects unscoped test:e2e; provide a spec/test file, "
                "--grep, or --last-failed"
            )


def worktree_root(start: str | None = None) -> str:
    """Return the absolute root of the git worktree the proof runs in."""
    directory = os.path.realpath(start if start is not None else os.getcwd())
    try:
        completed = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=directory,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return directory
    root = completed.stdout.strip()
    if completed.returncode != 0 or not root:
        return directory
    return os.path.realpath(root)


def worktree_partition(root: str) -> int:
    """Derive one stable `mix test` partition from a worktree root path."""
    digest = hashlib.blake2b(root.encode("utf-8"), digest_size=8).digest()
    return PARTITION_FLOOR + int.from_bytes(digest, "big") % PARTITION_SPAN


def is_mix_test(command: Sequence[str]) -> bool:
    """Return whether the command invokes `mix test`."""
    return len(command) >= 2 and os.path.basename(command[0]) == "mix" and command[1] == "test"


def apply_test_partition(
    command: Sequence[str],
    environment: dict[str, str],
    root: str | None = None,
) -> tuple[int, str] | None:
    """Give `mix test` one stable database per worktree unless the caller set one.

    The partition is injected into the child environment only, so the receipt
    keeps rendering the caller's original command.
    """
    if not is_mix_test(command) or MIX_TEST_PARTITION in environment:
        return None
    resolved = worktree_root() if root is None else os.path.realpath(root)
    partition = worktree_partition(resolved)
    environment[MIX_TEST_PARTITION] = str(partition)
    return partition, resolved


def receipt(
    scope: str,
    task: int | None,
    original_command: Sequence[str],
    broad_task: bool = False,
) -> str:
    rendered_command = shlex.join(original_command).replace("`", r"\`")
    if scope == "task":
        subject = f"`Task {task}`"
        proof_scope = "`Broad`" if broad_task else "`Focused`"
    else:
        subject = "slice"
        proof_scope = "`Broad`"
    return (
        f"- Proof receipt: {subject} — scope {proof_scope} — "
        f"command `{rendered_command}` — exit `0`."
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="scope", required=True)

    task_parser = subparsers.add_parser("task", help="run a focused task proof")
    task_parser.add_argument("--task", required=True, type=positive_task_number)
    task_parser.add_argument(
        "--broad",
        action="store_true",
        help="run a broad task proof allowed by an explicit specification exception",
    )
    task_parser.add_argument("command", nargs=argparse.REMAINDER)

    slice_parser = subparsers.add_parser("slice", help="run a broad slice proof")
    slice_parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    original_command = list(arguments.command)
    if original_command and original_command[0] == "--":
        original_command = original_command[1:]

    try:
        additions, command = split_environment(original_command)
        environment = os.environ.copy()
        environment.update(additions)
        if arguments.scope == "task" and not arguments.broad:
            validate_task_command(command, environment)
    except ProofCommandError as error:
        parser.error(str(error))

    if arguments.scope == "task":
        injected = apply_test_partition(command, environment)
        if injected is not None:
            partition, root = injected
            print(
                f"proof: {MIX_TEST_PARTITION}={partition} derived for worktree {root}",
                file=sys.stderr,
            )

    try:
        completed = subprocess.run(command, env=environment, check=False)
    except FileNotFoundError:
        print(f"proof command not found: {command[0]}", file=sys.stderr)
        return 127

    if completed.returncode == 0:
        print(
            receipt(
                arguments.scope,
                getattr(arguments, "task", None),
                original_command,
                getattr(arguments, "broad", False),
            )
        )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
