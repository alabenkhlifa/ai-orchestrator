#!/usr/bin/env python3
"""Report live slice task and capability readiness without running project checks."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


TASK_RE = re.compile(r"^-\s+\[([ xX])\]\s+Task\s+(\d+)\s+[-—]\s+(.+?)\s*$")
DEPENDS_RE = re.compile(r"^\s+-\s+Depends on:\s*(.+?)\s*$", re.IGNORECASE)
TASK_STATUS_RE = re.compile(r"^\s+-\s+Status:\s*(.+?)\s*$", re.IGNORECASE)
TASK_REF_RE = re.compile(r"Task\s+(\d+)", re.IGNORECASE)
REQUIRES_RE = re.compile(
    r"^-\s+`(capability:[^`]+)`\s+—\s+provider\s+"
    r"`specs/([^#`]+)#Task\s+(\d+)`\s+—\s+required before\s+`Task\s+(\d+)`\.\s*$"
)
PROVIDES_RE = re.compile(
    r"^-\s+`(capability:[^`]+)`\s+—\s+ready after\s+`Task\s+(\d+)`\.\s*$"
)
SLICE_RE = re.compile(r"^(\d+)-")


@dataclass(frozen=True)
class Requirement:
    capability: str
    provider_slug: str
    provider_task: int
    consumer_task: int


@dataclass(frozen=True)
class Provision:
    capability: str
    provider_task: int


@dataclass
class Task:
    number: int
    title: str
    done: bool
    depends_on: list[int] = field(default_factory=list)
    explicit_status: str | None = None


@dataclass
class Spec:
    number: int
    slug: str
    title: str
    status: str
    tasks: dict[int, Task]
    task_order: list[int]
    requires: list[Requirement]
    provides: list[Provision]
    source: Path
    branch: str


@dataclass(frozen=True)
class Worktree:
    path: Path
    branch: str


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip() or "git command failed"
        raise RuntimeError(message)
    return result.stdout


def discover_worktrees(repo: Path) -> list[Worktree]:
    records: list[Worktree] = []
    path: Path | None = None
    branch = "detached"

    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            if path is not None:
                records.append(Worktree(path, branch))
            path = Path(line.removeprefix("worktree ")).resolve()
            branch = "detached"
        elif line.startswith("branch refs/heads/"):
            branch = line.removeprefix("branch refs/heads/")
        elif not line and path is not None:
            records.append(Worktree(path, branch))
            path = None
            branch = "detached"

    return records


def source_paths(worktrees: list[Worktree]) -> dict[str, tuple[Path, str]]:
    main = next((worktree for worktree in worktrees if worktree.branch == "main"), worktrees[0])
    selected: dict[str, tuple[Path, str]] = {}

    for tasks_path in sorted((main.path / "specs").glob("*/tasks.md")):
        selected[tasks_path.parent.name] = (tasks_path, main.branch)

    for worktree in worktrees:
        if not worktree.branch.startswith("slice/"):
            continue
        slug = worktree.branch.removeprefix("slice/")
        tasks_path = worktree.path / "specs" / slug / "tasks.md"
        if tasks_path.is_file():
            selected[slug] = (tasks_path, worktree.branch)

    return selected


def section_value(lines: list[str], heading: str, fallback: str) -> str:
    try:
        start = lines.index(heading) + 1
    except ValueError:
        return fallback

    for line in lines[start:]:
        stripped = line.strip()
        if stripped.startswith("## "):
            break
        if stripped:
            return stripped
    return fallback


def parse_spec(slug: str, source: Path, branch: str) -> Spec:
    match = SLICE_RE.match(slug)
    if not match:
        raise ValueError(f"spec directory has no numeric prefix: {slug}")

    lines = source.read_text(encoding="utf-8").splitlines()
    title = next((line[2:].strip() for line in lines if line.startswith("# ")), slug)
    if title.endswith(" Tasks"):
        title = title[: -len(" Tasks")]

    tasks: dict[int, Task] = {}
    order: list[int] = []
    current: Task | None = None
    task_section = False

    for line in lines:
        if line == "## Tasks":
            task_section = True
            current = None
            continue
        if task_section and line.startswith("## "):
            task_section = False
            current = None
        if not task_section:
            continue
        task_match = TASK_RE.match(line)
        if task_match:
            number = int(task_match.group(2))
            current = Task(number, task_match.group(3), task_match.group(1).lower() == "x")
            tasks[number] = current
            order.append(number)
            continue
        if current is None:
            continue
        depends_match = DEPENDS_RE.match(line)
        if depends_match:
            current.depends_on = [int(value) for value in TASK_REF_RE.findall(depends_match.group(1))]
            continue
        status_match = TASK_STATUS_RE.match(line)
        if status_match:
            current.explicit_status = status_match.group(1)

    requires: list[Requirement] = []
    provides: list[Provision] = []
    dependency_section = False
    mode: str | None = None

    for line in lines:
        if line == "## Cross-Specification Dependencies":
            dependency_section = True
            mode = None
            continue
        if dependency_section and line.startswith("## "):
            break
        if not dependency_section:
            continue
        if line.strip() == "Requires:":
            mode = "requires"
            continue
        if line.strip() == "Provides:":
            mode = "provides"
            continue
        if mode == "requires":
            item = REQUIRES_RE.match(line)
            if item:
                requires.append(
                    Requirement(item.group(1), item.group(2), int(item.group(3)), int(item.group(4)))
                )
        elif mode == "provides":
            item = PROVIDES_RE.match(line)
            if item:
                provides.append(Provision(item.group(1), int(item.group(2))))

    return Spec(
        number=int(match.group(1)),
        slug=slug,
        title=title,
        status=section_value(lines, "## Status", "Unknown"),
        tasks=tasks,
        task_order=order,
        requires=requires,
        provides=provides,
        source=source,
        branch=branch,
    )


def task_done(specs: dict[str, Spec], slug: str, number: int) -> bool:
    spec = specs.get(slug)
    task = spec.tasks.get(number) if spec else None
    return bool(task and task.done)


def missing_for_task(specs: dict[str, Spec], spec: Spec, task: Task) -> tuple[list[int], list[Requirement]]:
    missing_tasks = [number for number in task.depends_on if not (spec.tasks.get(number) and spec.tasks[number].done)]
    missing_capabilities = [
        requirement
        for requirement in spec.requires
        if requirement.consumer_task == task.number
        and not task_done(specs, requirement.provider_slug, requirement.provider_task)
    ]
    return missing_tasks, missing_capabilities


def explicit_blocker_reason(task: Task) -> str | None:
    if not task.explicit_status or not task.explicit_status.lower().startswith("blocked"):
        return None

    normalized = task.explicit_status.lower()
    capability_condition = "capability:" in normalized or "every capability" in normalized
    if capability_condition:
        return None
    return task.explicit_status.removeprefix("Blocked ").removeprefix("blocked ")


def task_state(specs: dict[str, Spec], spec: Spec, task: Task) -> tuple[str, list[int], list[Requirement]]:
    missing_tasks, missing_capabilities = missing_for_task(specs, spec, task)
    explicit_blocker = explicit_blocker_reason(task)
    if task.done:
        state = "Done"
    elif explicit_blocker:
        state = "Blocked: " + explicit_blocker
    elif missing_tasks or missing_capabilities:
        state = "Waiting"
    else:
        state = "Start now"
    return state, missing_tasks, missing_capabilities


def capability_consumers(specs: dict[str, Spec]) -> dict[str, list[tuple[Spec, Requirement]]]:
    consumers: dict[str, list[tuple[Spec, Requirement]]] = {}
    for spec in specs.values():
        for requirement in spec.requires:
            consumers.setdefault(requirement.capability, []).append((spec, requirement))
    return consumers


def short_capability(value: str) -> str:
    return value.removeprefix("capability:")


def md(value: object) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def task_label(task: Task) -> str:
    return f"T{task.number} {task.title.rstrip('.')}"


def startable_tasks(specs: dict[str, Spec], spec: Spec) -> list[Task]:
    return [
        task
        for number in spec.task_order
        if not (task := spec.tasks[number]).done and task_state(specs, spec, task)[0] == "Start now"
    ]


def frontier_blockers(specs: dict[str, Spec], spec: Spec) -> list[str]:
    blockers: list[str] = []
    for number in spec.task_order:
        task = spec.tasks[number]
        if task.done:
            continue
        state, missing_tasks, missing_capabilities = task_state(specs, spec, task)
        if missing_tasks:
            continue
        if state.startswith("Blocked:"):
            blockers.append(f"T{number}: {state.removeprefix('Blocked: ')}")
        elif missing_capabilities:
            caps = ", ".join(short_capability(item.capability) for item in missing_capabilities)
            blockers.append(f"T{number} ← {caps}")
    return blockers


def provision_effect(
    specs: dict[str, Spec],
    spec: Spec,
    consumers: dict[str, list[tuple[Spec, Requirement]]],
) -> str:
    effects: list[str] = []
    for provision in spec.provides:
        ready = task_done(specs, spec.slug, provision.provider_task)
        targets = sorted(
            {
                f"S{consumer.number:02d}/T{requirement.consumer_task}"
                for consumer, requirement in consumers.get(provision.capability, [])
                if not task_done(specs, consumer.slug, requirement.consumer_task)
            }
        )
        effect = f"{short_capability(provision.capability)} {'ready' if ready else 'pending'}"
        if targets:
            effect += " → " + ", ".join(targets)
        effects.append(effect)
    return "; ".join(effects) if effects else "—"


def render_summary(specs: dict[str, Spec], from_slice: int) -> None:
    consumers = capability_consumers(specs)
    selected = sorted((spec for spec in specs.values() if spec.number >= from_slice), key=lambda item: item.number)
    if not selected:
        raise ValueError(f"no slices found from {from_slice}")

    print(f"# Slice status — {from_slice:02d} to {selected[-1].number:02d}")
    print()
    print("Live sources: `main` plus each matching active `slice/<spec-directory>` worktree.")
    print()
    print("| Slice | Specification | Status | Done | Left | Start now | Immediate blocker | Provides / blocks |")
    print("|---:|---|---|---:|---:|---|---|---|")

    for spec in selected:
        done = sum(task.done for task in spec.tasks.values())
        left = len(spec.tasks) - done
        start = startable_tasks(specs, spec)
        start_text = ", ".join(f"T{task.number}" for task in start) or "—"
        blocker_text = "; ".join(frontier_blockers(specs, spec)) or "—"
        effect = provision_effect(specs, spec, consumers)
        print(
            "| "
            + " | ".join(
                md(value)
                for value in (
                    f"{spec.number:02d}",
                    spec.title,
                    spec.status,
                    done,
                    left,
                    start_text,
                    blocker_text,
                    effect,
                )
            )
            + " |"
        )

    print()
    print("## Cross-slice capability blockers")
    print()
    blocked_edges: list[str] = []
    seen: set[tuple[str, str, int]] = set()
    for consumer in selected:
        for requirement in consumer.requires:
            if task_done(specs, requirement.provider_slug, requirement.provider_task):
                continue
            key = (requirement.capability, requirement.provider_slug, requirement.provider_task)
            if key in seen:
                continue
            seen.add(key)
            provider = specs.get(requirement.provider_slug)
            provider_label = (
                f"Slice {provider.number:02d} Task {requirement.provider_task}"
                if provider
                else f"{requirement.provider_slug} Task {requirement.provider_task}"
            )
            targets = sorted(
                {
                    f"Slice {target.number:02d} Task {item.consumer_task}"
                    for target, item in consumers.get(requirement.capability, [])
                    if target.number >= from_slice and not task_done(specs, target.slug, item.consumer_task)
                }
            )
            if targets:
                blocked_edges.append(
                    f"- {provider_label} must provide `{requirement.capability}` before "
                    + ", ".join(targets)
                    + "."
                )
    print("\n".join(blocked_edges) if blocked_edges else "- None.")


def render_focus(specs: dict[str, Spec], focus_number: int) -> None:
    matches = [spec for spec in specs.values() if spec.number == focus_number]
    if not matches:
        raise ValueError(f"Slice {focus_number:02d} was not found")
    spec = matches[0]
    consumers = capability_consumers(specs)
    reverse_dependencies: dict[int, list[int]] = {}
    for task in spec.tasks.values():
        for dependency in task.depends_on:
            reverse_dependencies.setdefault(dependency, []).append(task.number)

    done = sum(task.done for task in spec.tasks.values())
    left = len(spec.tasks) - done
    start = startable_tasks(specs, spec)

    print()
    print(f"## Slice {spec.number:02d} focus — {spec.title}")
    print()
    print(f"- Source: `{spec.branch}` — `{spec.source}`")
    print(f"- Status: {spec.status}; {done} done, {left} left.")
    print(
        "- Start now: "
        + ("; ".join(task_label(task) for task in start) if start else "None.")
    )
    print()
    print("| Task | State | Waiting on | What this task unblocks |")
    print("|---|---|---|---|")

    for number in spec.task_order:
        task = spec.tasks[number]
        if task.done:
            continue
        state, missing_tasks, missing_capabilities = task_state(specs, spec, task)
        waiting: list[str] = [f"T{value}" for value in missing_tasks]
        waiting.extend(
            f"{short_capability(item.capability)} (S{specs[item.provider_slug].number:02d}/T{item.provider_task})"
            if item.provider_slug in specs
            else f"{short_capability(item.capability)} ({item.provider_slug}/T{item.provider_task})"
            for item in missing_capabilities
        )
        explicit_blocker = explicit_blocker_reason(task)
        if explicit_blocker:
            waiting.append(explicit_blocker)

        unblocks: list[str] = [
            f"T{value}" for value in sorted(reverse_dependencies.get(number, [])) if not spec.tasks[value].done
        ]
        for provision in spec.provides:
            if provision.provider_task != number:
                continue
            targets = sorted(
                {
                    f"S{consumer.number:02d}/T{requirement.consumer_task}"
                    for consumer, requirement in consumers.get(provision.capability, [])
                    if not task_done(specs, consumer.slug, requirement.consumer_task)
                }
            )
            text = short_capability(provision.capability)
            if targets:
                text += " → " + ", ".join(targets)
            unblocks.append(text)

        print(
            "| "
            + " | ".join(
                md(value)
                for value in (
                    task_label(task),
                    state,
                    ", ".join(waiting) or "—",
                    ", ".join(unblocks) or "—",
                )
            )
            + " |"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="from_slice", type=int, default=7, help="first slice to report")
    parser.add_argument("--focus", type=int, default=11, help="slice to expand after the summary")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())
        worktrees = discover_worktrees(repo)
        specs = {
            slug: parse_spec(slug, source, branch)
            for slug, (source, branch) in source_paths(worktrees).items()
            if SLICE_RE.match(slug)
        }
        render_summary(specs, args.from_slice)
        render_focus(specs, args.focus)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"slice_status.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
