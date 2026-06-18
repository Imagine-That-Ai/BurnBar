#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

violations="$(
  python3 - <<'PY'
import re
import shlex
import subprocess

files = subprocess.check_output(
    ["git", "ls-files", ".github", "scripts"], text=True
).splitlines()

pipe_to_shell = re.compile(
    r"(curl|wget)[^|;&]*\|[ \t]*(sudo[ \t]+)?(?:(?:/usr/bin/env[ \t]+)?|(?:/[^ \t;&|]+/)?)"
    r"(bash|sh)|[ \t](bash|sh)[ \t]+<\(",
    re.IGNORECASE,
)
redirect_to_file = re.compile(r">[ \t]*(?P<target>[^ \t;&|]+)")
shell_control_tokens = {";", "&&", "||", "|"}


def clean_token(value: str) -> str:
    return value.strip().strip('"').strip("'")


def is_comment(line: str) -> bool:
    return line.lstrip().startswith("#")


def has_remote_url(tokens):
    return any(token.startswith(("http://", "https://")) for token in tokens)


def command_basename(token: str) -> str:
    token = clean_token(token)
    if "/" in token:
        token = token.rsplit("/", 1)[-1]
    return token


def normalize_workflow_run_prefix(line: str) -> str:
    stripped = line.lstrip()
    for prefix in ("- run:", "run:"):
        if stripped.startswith(prefix):
            return stripped[len(prefix) :].lstrip()
    return line


def logical_lines(lines):
    pending = ""
    pending_start = 0
    for index, raw_line in enumerate(lines, start=1):
        line = normalize_workflow_run_prefix(raw_line)

        if not pending:
            pending_start = index

        current = line.rstrip()
        if current.endswith("\\"):
            pending += current[:-1] + " "
            continue

        yield pending_start, pending + current
        pending = ""

    if pending:
        yield pending_start, pending


def option_attached_value(token: str, option: str):
    if not token.startswith("-") or token.startswith("--"):
        return None

    body = token[1:]
    if option not in body:
        return None

    attached = body.split(option, 1)[1]
    return attached or None


def shell_execution_target(tokens):
    for index, token in enumerate(tokens):
        if index != 0 and tokens[index - 1] not in shell_control_tokens:
            continue

        command_index = index
        command = command_basename(tokens[command_index])

        if command == "sudo" and command_index + 1 < len(tokens):
            command_index += 1
            command = command_basename(tokens[command_index])

        if (
            command == "env"
            and command_index + 1 < len(tokens)
            and command_basename(tokens[command_index + 1]) in {"bash", "sh"}
        ):
            command_index += 1
            command = command_basename(tokens[command_index])

        if command in {"bash", "sh"} and command_index + 1 < len(tokens):
            return clean_token(tokens[command_index + 1])

    return None


def script_download_target(tokens):
    if not tokens:
        return None
    command = command_basename(tokens[0])
    if command not in {"curl", "wget"} or not has_remote_url(tokens):
        return None

    for index, token in enumerate(tokens[1:], start=1):
        target = None

        if command == "curl":
            if token in {"-o", "--output"} and index + 1 < len(tokens):
                target = tokens[index + 1]
            elif token.startswith("--output="):
                target = token.split("=", 1)[1]
            elif option_attached_value(token, "o"):
                target = option_attached_value(token, "o")
            elif (
                token.startswith("-")
                and not token.startswith("--")
                and "o" in token[1:]
                and index + 1 < len(tokens)
            ):
                target = tokens[index + 1]
        elif command == "wget":
            if token in {"-O", "--output-document"} and index + 1 < len(tokens):
                target = tokens[index + 1]
            elif token.startswith("--output-document="):
                target = token.split("=", 1)[1]
            elif option_attached_value(token, "O"):
                target = option_attached_value(token, "O")
            elif (
                token.startswith("-")
                and not token.startswith("--")
                and "O" in token[1:]
                and index + 1 < len(tokens)
            ):
                target = tokens[index + 1]

        if target:
            return clean_token(target)

    redirect_match = redirect_to_file.search(" ".join(tokens))
    if redirect_match:
        return clean_token(redirect_match.group("target"))

    return None


failures = []
for file_path in files:
    if file_path == "scripts/ci/verify-no-remote-shell-installers.test.sh":
        continue

    try:
        lines = open(file_path, encoding="utf-8").read().splitlines()
    except UnicodeDecodeError:
        continue

    downloaded_shell_targets = {}
    for index, line in logical_lines(lines):
        if is_comment(line):
            continue

        if pipe_to_shell.search(line):
            failures.append(f"{file_path}:{index}: remote pipe-to-shell installer")

        try:
            tokens = shlex.split(line)
        except ValueError:
            tokens = []
        target = script_download_target(tokens)
        if target:
            downloaded_shell_targets[target] = index

        executed_target = shell_execution_target(tokens)
        if executed_target and executed_target in downloaded_shell_targets:
            failures.append(
                f"{file_path}:{index}: executes remote-downloaded shell script "
                f"{executed_target} from line {downloaded_shell_targets[executed_target]}"
            )

if failures:
    print("\n".join(failures))
PY
)"

if [[ -n "$violations" ]]; then
  echo "Remote shell installer pattern detected. Use pinned package releases, vendored installers, or version+checksum verification before execution." >&2
  echo "$violations" >&2
  exit 1
fi

echo "OK: no remote shell installer patterns in workflows or scripts."
