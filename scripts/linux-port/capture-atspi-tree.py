#!/usr/bin/env python3
"""Capture a bounded AT-SPI tree and fail when the app is not meaningfully exposed."""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import Counter, deque
from collections.abc import Callable
from pathlib import Path
from typing import Any


ACTIONABLE_ROLES = {
    "button",
    "check box",
    "combo box",
    "entry",
    "link",
    "menu item",
    "page tab",
    "radio button",
    "slider",
    "spin button",
    "toggle button",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--application", default="OpenBurnBar")
    parser.add_argument("--output")
    parser.add_argument("--tree-text")
    parser.add_argument("--expected-name")
    parser.add_argument("--route")
    parser.add_argument(
        "--mode",
        choices=("tree", "summary", "focus", "grab-focus", "activate"),
        default="tree",
    )
    parser.add_argument("--within-role")
    parser.add_argument("--timeout-seconds", type=float, default=20.0)
    parser.add_argument("--max-depth", type=int, default=48)
    parser.add_argument("--max-nodes", type=int, default=5000)
    parser.add_argument("--min-nodes", type=int, default=20)
    parser.add_argument("--min-named", type=int, default=8)
    parser.add_argument("--min-actionable", type=int, default=5)
    parser.add_argument(
        "--wait-for-meaningful-seconds",
        type=float,
        default=0.0,
        help="retry a discovered application until it meets the accessibility minimums",
    )
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args()


def safe_text(value: Any) -> str:
    try:
        return str(value or "").replace("\n", " ").strip()
    except Exception:
        return ""


def node_name(node: Any) -> str:
    try:
        return safe_text(getattr(node, "name", ""))
    except Exception:
        return ""


def node_description(node: Any) -> str:
    try:
        return safe_text(getattr(node, "description", ""))
    except Exception:
        return ""


def child_count(node: Any) -> int:
    try:
        return int(node.childCount)
    except Exception:
        try:
            return int(node.getChildCount())
        except Exception:
            return 0


def child_at(node: Any, index: int) -> Any | None:
    try:
        return node.getChildAtIndex(index)
    except Exception:
        try:
            return node[index]
        except Exception:
            return None


def role_name(node: Any) -> str:
    try:
        return safe_text(node.getRoleName()).lower()
    except Exception:
        return "unknown"


def state_names(node: Any, pyatspi: Any) -> list[str]:
    try:
        return sorted(safe_text(pyatspi.stateToString(state)).lower() for state in node.getState().getStates())
    except Exception:
        return []


def action_names(node: Any) -> list[str]:
    try:
        action = node.queryAction()
        return [safe_text(action.getName(index)) for index in range(action.nActions)]
    except Exception:
        return []


def collect_nodes(root: Any, pyatspi: Any, max_depth: int, max_nodes: int) -> tuple[list[dict[str, Any]], bool]:
    rows: list[dict[str, Any]] = []
    queue: deque[tuple[Any, int, str]] = deque([(root, 0, "0")])
    truncated = False
    while queue:
        node, depth, node_path = queue.popleft()
        if len(rows) >= max_nodes:
            truncated = True
            break
        role = role_name(node)
        name = node_name(node)
        description = node_description(node)
        states = state_names(node, pyatspi)
        actions = [name for name in action_names(node) if name]
        rows.append(
            {
                "path": node_path,
                "depth": depth,
                "role": role,
                "name": name,
                "description": description,
                "states": states,
                "actions": actions,
                "childCount": child_count(node),
            }
        )
        if depth >= max_depth:
            if child_count(node) > 0:
                truncated = True
            continue
        for index in range(child_count(node)):
            child = child_at(node, index)
            if child is not None:
                queue.append((child, depth + 1, f"{node_path}.{index}"))
    return rows, truncated


def contains_name(root: Any, expected: str, limit: int = 500) -> bool:
    needle = expected.casefold()
    queue: deque[Any] = deque([root])
    seen = 0
    while queue and seen < limit:
        node = queue.popleft()
        seen += 1
        if needle in node_name(node).casefold():
            return True
        for index in range(child_count(node)):
            child = child_at(node, index)
            if child is not None:
                queue.append(child)
    return False


def application_candidates(pyatspi: Any, application_name: str) -> list[Any]:
    desktop = pyatspi.Registry.getDesktop(0)
    applications = [child_at(desktop, index) for index in range(child_count(desktop))]
    needle = application_name.casefold()
    direct = [
        application
        for application in applications
        if application is not None and needle in node_name(application).casefold() and child_count(application) > 0
    ]
    if direct:
        return direct
    # The nested scan walks every desktop application tree over synchronous
    # cross-process AT-SPI calls, so it only runs when no direct root exists.
    return [
        application
        for application in applications
        if application is not None and child_count(application) > 0 and contains_name(application, application_name)
    ]


def find_application(
    pyatspi: Any,
    application_name: str,
    timeout_seconds: float,
    expected_name: str | None = None,
) -> Any:
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            applications = application_candidates(pyatspi, application_name)
        except Exception as error:
            last_error = error
            time.sleep(0.25)
            continue
        if expected_name:
            for application in applications:
                if contains_name(application, expected_name):
                    return application
        if applications:
            return applications[0]
        time.sleep(0.25)
    suffix = f" ({last_error})" if last_error else ""
    raise RuntimeError(f"AT-SPI application not found: {application_name}{suffix}")


def find_actionable_node(root: Any, expected_name: str, within_role: str | None) -> Any:
    search_root = root
    if within_role:
        queue: deque[Any] = deque([root])
        while queue:
            node = queue.popleft()
            if role_name(node) == within_role.casefold():
                search_root = node
                break
            for index in range(child_count(node)):
                child = child_at(node, index)
                if child is not None:
                    queue.append(child)
        else:
            raise RuntimeError(f"AT-SPI ancestor role not found: {within_role}")

    needle = expected_name.casefold()
    candidates: list[tuple[int, Any]] = []
    queue = deque([search_root])
    while queue:
        node = queue.popleft()
        name = node_name(node)
        actions = [value for value in action_names(node) if value]
        folded = name.casefold()
        if actions and needle in folded:
            score = 0 if folded == needle else 1 if folded.startswith(needle) else 2
            candidates.append((score, node))
        for index in range(child_count(node)):
            child = child_at(node, index)
            if child is not None:
                queue.append(child)
    if not candidates:
        raise RuntimeError(f"AT-SPI actionable node not found: {expected_name}")
    candidates.sort(key=lambda item: item[0])
    return candidates[0][1]


def activate_node(node: Any) -> dict[str, Any]:
    action = node.queryAction()
    names = [safe_text(action.getName(index)).lower() for index in range(action.nActions)]
    preferred = ("press", "click", "activate", "jump", "select")
    action_index = next(
        (index for preferred_name in preferred for index, name in enumerate(names) if name == preferred_name),
        0,
    )
    activated = bool(action.doAction(action_index))
    return {
        "role": role_name(node),
        "name": node_name(node),
        "availableActions": names,
        "performedAction": names[action_index] if names else None,
        "activated": activated,
    }


def grab_focus(node: Any) -> dict[str, Any]:
    """Put keyboard focus on a real AT-SPI component before traversal."""
    component = node.queryComponent()
    grabbed = bool(component.grabFocus())
    return {
        "role": role_name(node),
        "name": node_name(node),
        "grabbed": grabbed,
    }


def probe_with_retry(
    pyatspi: Any,
    application_name: str,
    expected_name: str,
    within_role: str | None,
    timeout_seconds: float,
    probe: Callable[[Any], dict[str, Any]],
    succeeded: Callable[[dict[str, Any]], bool],
    label: str,
) -> dict[str, Any]:
    """Try every live registration until one succeeds, retrying transient AT-SPI errors.

    A stale registration can fail at any stage (enumeration, lookup, or the probe
    itself returning an unsuccessful receipt), so every stage stays inside the retry
    boundary and only a successful probe leaves the candidate loop early.
    """
    deadline = time.monotonic() + timeout_seconds
    last_error: Exception | None = None
    last_result: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        try:
            applications = application_candidates(pyatspi, application_name)
        except Exception as error:
            last_error = error
            time.sleep(0.25)
            continue
        if not applications:
            last_error = RuntimeError(f"AT-SPI application not found: {application_name}")
        for application in applications:
            try:
                node = find_actionable_node(application, expected_name, within_role)
                result = probe(node)
            except Exception as error:
                last_error = error
                continue
            if succeeded(result):
                return result
            last_result = result
            last_error = RuntimeError(f"AT-SPI {label} was rejected by a candidate root for {expected_name}")
        time.sleep(0.25)
    if last_result is not None:
        return last_result
    raise RuntimeError(f"AT-SPI {label} timed out for {expected_name}: {last_error}")


def activate_with_retry(
    pyatspi: Any,
    application_name: str,
    expected_name: str,
    within_role: str | None,
    timeout_seconds: float,
) -> dict[str, Any]:
    return probe_with_retry(
        pyatspi,
        application_name,
        expected_name,
        within_role,
        timeout_seconds,
        activate_node,
        lambda result: bool(result["activated"]),
        "action",
    )


def grab_focus_with_retry(
    pyatspi: Any,
    application_name: str,
    expected_name: str,
    within_role: str | None,
    timeout_seconds: float,
) -> dict[str, Any]:
    return probe_with_retry(
        pyatspi,
        application_name,
        expected_name,
        within_role,
        timeout_seconds,
        grab_focus,
        lambda result: bool(result["grabbed"]),
        "focus",
    )


def summarize(
    rows: list[dict[str, Any]],
    application_name: str,
    route: str | None,
    expected_name: str | None,
    truncated: bool,
    minimums: tuple[int, int, int],
) -> dict[str, Any]:
    named = [row for row in rows if row["name"]]
    actionable = [row for row in rows if row["actions"] or row["role"] in ACTIONABLE_ROLES]
    focusable = [row for row in rows if "focusable" in row["states"]]
    focused = [row for row in rows if "focused" in row["states"]]
    role_counts = dict(sorted(Counter(row["role"] for row in rows).items()))
    expected_present = (
        True if not expected_name else any(expected_name.casefold() in row["name"].casefold() for row in named)
    )
    min_nodes, min_named, min_actionable = minimums
    failures = []
    if len(rows) < min_nodes:
        failures.append(f"node_count_below_{min_nodes}")
    if len(named) < min_named:
        failures.append(f"named_node_count_below_{min_named}")
    if len(actionable) < min_actionable:
        failures.append(f"actionable_node_count_below_{min_actionable}")
    if truncated:
        failures.append("tree_truncated")
    if not expected_present:
        failures.append("expected_name_missing")
    return {
        "schemaVersion": 1,
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "application": application_name,
        "route": route,
        "expectedName": expected_name,
        "expectedNamePresent": expected_present,
        "nodeCount": len(rows),
        "namedNodeCount": len(named),
        "actionableNodeCount": len(actionable),
        "focusableNodeCount": len(focusable),
        "focusedNodes": focused[:8],
        "roleCounts": role_counts,
        "namedSamples": named[:40],
        "actionableSamples": actionable[:30],
        "truncated": truncated,
        "minimums": {
            "nodes": min_nodes,
            "named": min_named,
            "actionable": min_actionable,
        },
        "pass": not failures,
        "failures": failures,
    }


def capture_tree_with_retry(
    pyatspi: Any,
    initial_application: Any,
    application_name: str,
    route: str | None,
    expected_name: str | None,
    max_depth: int,
    max_nodes: int,
    minimums: tuple[int, int, int],
    wait_for_meaningful_seconds: float,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Capture the best live registration, preferring the first meaningful tree.

    Desktop AT-SPI can briefly retain a defunct application root after a prior
    process exits. Re-enumerating every matching root on each readiness attempt
    prevents that stale registration from masking a healthy replacement.
    """
    deadline = time.monotonic() + max(0.0, wait_for_meaningful_seconds)
    attempts = 0
    best_result: dict[str, Any] | None = None
    best_rows: list[dict[str, Any]] = []
    last_error: Exception | None = None

    while True:
        try:
            applications = application_candidates(pyatspi, application_name)
        except Exception as error:
            applications = [initial_application]
            last_error = error

        if expected_name:
            expected_applications = [
                application for application in applications if contains_name(application, expected_name)
            ]
            if expected_applications:
                applications = expected_applications
        if not applications:
            applications = [initial_application]

        for application in applications:
            try:
                rows, truncated = collect_nodes(application, pyatspi, max_depth, max_nodes)
                result = summarize(
                    rows,
                    application_name,
                    route,
                    expected_name,
                    truncated,
                    minimums,
                )
            except Exception as error:
                last_error = error
                continue

            attempts += 1
            quality = (
                int(result["expectedNamePresent"]),
                result["nodeCount"],
                result["namedNodeCount"],
                result["actionableNodeCount"],
                -len(result["failures"]),
            )
            best_quality = (
                int(best_result["expectedNamePresent"]),
                best_result["nodeCount"],
                best_result["namedNodeCount"],
                best_result["actionableNodeCount"],
                -len(best_result["failures"]),
            ) if best_result is not None else None
            if best_quality is None or quality > best_quality:
                best_result = result
                best_rows = rows
            if result["pass"]:
                result["readinessAttempts"] = attempts
                return result, rows

        if time.monotonic() >= deadline:
            break
        time.sleep(0.25)

    if best_result is None:
        raise RuntimeError(f"AT-SPI tree capture failed for every live registration: {last_error}")
    best_result["readinessAttempts"] = attempts
    return best_result, best_rows


def write_tree_text(path: str, rows: list[dict[str, Any]]) -> None:
    lines = []
    for row in rows:
        indent = "  " * row["depth"]
        details = [row["role"]]
        if row["name"]:
            details.append(f'name="{row["name"]}"')
        if row["states"]:
            details.append(f"states={','.join(row['states'])}")
        if row["actions"]:
            details.append(f"actions={','.join(row['actions'])}")
        lines.append(f"{indent}{row['path']} " + " ".join(details))
    Path(path).write_text("\n".join(lines) + "\n", encoding="utf-8")


def self_test() -> int:
    rows = [
        {"role": "application", "name": "OpenBurnBar", "states": [], "actions": []},
        {"role": "heading", "name": "Overview", "states": [], "actions": []},
    ]
    rows.extend(
        {"role": "button", "name": f"Action {index}", "states": ["focusable"], "actions": ["click"]}
        for index in range(6)
    )
    rows.extend({"role": "text", "name": f"Label {index}", "states": [], "actions": []} for index in range(12))
    result = summarize(rows, "OpenBurnBar", "overview", "Overview", False, (20, 8, 5))
    if not result["pass"] or result["actionableNodeCount"] != 6:
        print(json.dumps(result, indent=2), file=sys.stderr)
        return 1

    class FakeAction:
        def __init__(self, result: bool = True) -> None:
            self.nActions = 1
            self.activated = False
            self.result = result

        def getName(self, _index: int) -> str:
            return "press"

        def doAction(self, _index: int) -> bool:
            self.activated = True
            return self.result

    class FakeComponent:
        def __init__(self, result: bool) -> None:
            self.attempted = False
            self.result = result

        def grabFocus(self) -> bool:
            self.attempted = True
            return self.result

    class FakeNode:
        def __init__(
            self,
            name: str,
            children: list[Any] | None = None,
            action: Any | None = None,
            component: Any | None = None,
        ) -> None:
            self.name = name
            self.children = children or []
            self.action = action
            self.component = component

        @property
        def childCount(self) -> int:
            return len(self.children)

        def getChildAtIndex(self, index: int) -> Any:
            return self.children[index]

        def getRoleName(self) -> str:
            return "push button" if self.action else "application"

        def queryAction(self) -> Any:
            if self.action is None:
                raise RuntimeError("not actionable")
            return self.action

        def queryComponent(self) -> Any:
            if self.component is None:
                raise RuntimeError("no component")
            return self.component

    def fake_pyatspi(desktop: Any) -> Any:
        class FakeRegistry:
            @staticmethod
            def getDesktop(_index: int) -> Any:
                return desktop

        class FakePyAtSpi:
            Registry = FakeRegistry

        return FakePyAtSpi()

    rejecting_action = FakeAction(result=False)
    healthy_action = FakeAction()
    stale_application = FakeNode("openburnbar-linux-desktop", [FakeNode("Memory")])
    rejecting_application = FakeNode(
        "openburnbar-linux-desktop",
        [FakeNode("Open command palette", action=rejecting_action)],
    )
    healthy_application = FakeNode(
        "openburnbar-linux-desktop",
        [FakeNode("Open command palette", action=healthy_action)],
    )
    desktop = FakeNode("desktop", [stale_application, rejecting_application, healthy_application])

    activation = activate_with_retry(
        fake_pyatspi(desktop),
        "OpenBurnBar",
        "Open command palette",
        None,
        0.1,
    )
    if not activation["activated"] or not healthy_action.activated or not rejecting_action.activated:
        print(json.dumps({"staleRegistrationRecovery": activation}, indent=2), file=sys.stderr)
        return 1

    stale_component = FakeComponent(result=False)
    healthy_component = FakeComponent(result=True)
    focus_desktop = FakeNode(
        "desktop",
        [
            FakeNode(
                "openburnbar-linux-desktop",
                [FakeNode("Skip to content", action=FakeAction(), component=stale_component)],
            ),
            FakeNode(
                "openburnbar-linux-desktop",
                [FakeNode("Skip to content", action=FakeAction(), component=healthy_component)],
            ),
        ],
    )
    focus = grab_focus_with_retry(
        fake_pyatspi(focus_desktop),
        "OpenBurnBar",
        "Skip to content",
        None,
        0.1,
    )
    if not focus["grabbed"] or not stale_component.attempted or not healthy_component.attempted:
        print(json.dumps({"staleFocusRecovery": focus}, indent=2), file=sys.stderr)
        return 1

    healthy_tree_application = FakeNode(
        "OpenBurnBar",
        [
            *[FakeNode(f"Action {index}", action=FakeAction()) for index in range(6)],
            *[FakeNode(f"Label {index}") for index in range(14)],
        ],
    )
    tree_desktop = FakeNode("desktop", [stale_application, healthy_tree_application])
    tree_result, _ = capture_tree_with_retry(
        fake_pyatspi(tree_desktop),
        stale_application,
        "OpenBurnBar",
        "overview",
        "OpenBurnBar",
        48,
        5000,
        (20, 8, 5),
        0.0,
    )
    if not tree_result["pass"] or tree_result["readinessAttempts"] < 2:
        print(json.dumps({"staleTreeRecovery": tree_result}, indent=2), file=sys.stderr)
        return 1

    print(
        json.dumps(
            {
                "selfTest": "pass",
                "summary": result,
                "staleRegistrationRecovery": activation,
                "staleFocusRecovery": focus,
                "staleTreeRecovery": tree_result,
            },
            indent=2,
        )
    )
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    if not args.output:
        raise SystemExit("--output is required")

    try:
        import pyatspi  # type: ignore

        if args.mode in ("activate", "grab-focus"):
            if not args.expected_name:
                raise RuntimeError(f"--expected-name is required in {args.mode} mode")
            if args.mode == "activate":
                activation = activate_with_retry(
                    pyatspi,
                    args.application,
                    args.expected_name,
                    args.within_role,
                    args.timeout_seconds,
                )
                result = {
                    "schemaVersion": 1,
                    "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "application": args.application,
                    "expectedName": args.expected_name,
                    "withinRole": args.within_role,
                    "activation": activation,
                    "pass": activation["activated"],
                    "failures": [] if activation["activated"] else ["action_returned_false"],
                }
            else:
                focus = grab_focus_with_retry(
                    pyatspi,
                    args.application,
                    args.expected_name,
                    args.within_role,
                    args.timeout_seconds,
                )
                result = {
                    "schemaVersion": 1,
                    "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "application": args.application,
                    "expectedName": args.expected_name,
                    "withinRole": args.within_role,
                    "focus": focus,
                    "pass": focus["grabbed"],
                    "failures": [] if focus["grabbed"] else ["focus_grab_returned_false"],
                }
            Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
            print(json.dumps(result, separators=(",", ":")))
            return 0 if result["pass"] else 1
        application = find_application(
            pyatspi,
            args.application,
            args.timeout_seconds,
            args.expected_name,
        )
        minimums = (
            0 if args.mode == "focus" else args.min_nodes,
            0 if args.mode == "focus" else args.min_named,
            0 if args.mode == "focus" else args.min_actionable,
        )
        result, rows = capture_tree_with_retry(
            pyatspi,
            application,
            args.application,
            args.route,
            args.expected_name,
            args.max_depth,
            args.max_nodes,
            minimums,
            0.0 if args.mode == "focus" else args.wait_for_meaningful_seconds,
        )
        if args.mode == "tree":
            result["nodes"] = rows
        if args.mode == "focus":
            result = {
                "capturedAt": result["capturedAt"],
                "route": args.route,
                "focusedNodes": result["focusedNodes"],
                "pass": len(result["focusedNodes"]) > 0,
                "failures": [] if result["focusedNodes"] else ["no_focused_node"],
            }
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        if args.tree_text:
            write_tree_text(args.tree_text, rows)
        print(json.dumps(result, separators=(",", ":")))
        return 0 if result["pass"] else 1
    except Exception as error:
        failure = {
            "schemaVersion": 1,
            "application": args.application,
            "route": args.route,
            "pass": False,
            "failures": [f"capture_failed:{type(error).__name__}:{error}"],
        }
        Path(args.output).write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(failure), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
