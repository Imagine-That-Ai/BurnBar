"""Memory Pro provider layer: policy from the signed courier, a keyless loopback-gateway
client, the official-CLI client, and the router that picks one per purpose.

The engine never holds a provider key. The daemon's loopback gateway resolves credentials
and enforces Pro, consent, retention, and budget; this module only carries the short-lived
purpose-scoped bearer the courier handed it. The one environment seam,
``OPENBURNBAR_MEMORY_MODEL_POLICY_JSON``, is honored only under pytest so tests can run
without a daemon; production always asks the courier.
"""

from __future__ import annotations

import json
import os
import random
import shutil
import subprocess
import tempfile
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from .constants import (
    CLI_PATH_ENV,
    CLI_PROVIDER_IDS,
    GATEWAY_MAX_ATTEMPTS,
    GATEWAY_RETRY_STATUSES,
    MODEL_POLICY_JSON_ENV,
    POLICY_ERROR_CODES,
    POLICY_TTL_SECONDS,
    PURPOSE_TIMEOUTS,
    PURPOSES,
)


class ModelUnavailable(RuntimeError):
    """A typed refusal: the code is one of the six contract strings."""

    def __init__(self, code: str, reason: str) -> None:
        super().__init__(f"{code}: {reason}")
        self.code = code if code in POLICY_ERROR_CODES else "MODEL_UNAVAILABLE"
        self.reason = reason


# ---------------------------------------------------------------------------
# Policy


@dataclass(frozen=True)
class ProviderPolicy:
    id: str
    consented: bool
    retention: str
    purposes: dict[str, list[str]]


@dataclass
class MemoryModelPolicy:
    pro_active: bool
    enabled: bool
    gateway_url: str | None
    gateway_token: str | None
    token_expires_at: str | None
    providers: list[ProviderPolicy]
    cli: dict[str, bool]
    fetched_at: float = field(default_factory=time.time)
    code: str | None = None

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> MemoryModelPolicy:
        providers = []
        for raw in payload.get("providers") or []:
            if not isinstance(raw, dict) or not raw.get("id"):
                continue
            purposes = {
                str(purpose): [str(model) for model in models if str(model).strip()]
                for purpose, models in (raw.get("purposes") or {}).items()
                if isinstance(models, list)
            }
            providers.append(
                ProviderPolicy(
                    id=str(raw["id"]).strip().lower(),
                    consented=bool(raw.get("consented")),
                    retention=str(raw.get("retention") or "unknown"),
                    purposes=purposes,
                )
            )
        cli_raw = payload.get("cli") or {}
        cli = {name: bool(cli_raw.get(name)) for name in CLI_PROVIDER_IDS}
        return cls(
            pro_active=bool(payload.get("proActive")),
            enabled=bool(payload.get("enabled")),
            gateway_url=(str(payload["gatewayURL"]).rstrip("/") if payload.get("gatewayURL") else None),
            gateway_token=(str(payload["gatewayToken"]) if payload.get("gatewayToken") else None),
            token_expires_at=(str(payload["tokenExpiresAt"]) if payload.get("tokenExpiresAt") else None),
            providers=providers,
            cli=cli,
            code=(str(payload["code"]) if payload.get("code") else None),
        )

    def provider(self, provider_id: str) -> ProviderPolicy | None:
        wanted = provider_id.strip().lower()
        return next((item for item in self.providers if item.id == wanted), None)

    def models_for(self, purpose: str) -> list[str]:
        """`<providerID>/<modelID>` in policy order; consented gateway providers first, then CLIs."""
        candidates: list[str] = []
        for item in self.providers:
            if not item.consented:
                continue
            candidates.extend(f"{item.id}/{model}" for model in item.purposes.get(purpose, []))
        if purpose != "memory-embed":
            candidates.extend(f"{name}/default" for name in CLI_PROVIDER_IDS if self.cli.get(name))
        return candidates

    def usable(self, purpose: str) -> bool:
        return self.pro_active and self.enabled and bool(self.models_for(purpose))

    def token_expired(self, *, now: float | None = None, margin_seconds: float = 60.0) -> bool:
        if not self.token_expires_at:
            return False
        try:
            expires = datetime.fromisoformat(self.token_expires_at.replace("Z", "+00:00"))
        except ValueError:
            return True
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=UTC)
        current = now if now is not None else time.time()
        return expires.timestamp() - margin_seconds <= current


_POLICY_CACHE: dict[int, tuple[MemoryModelPolicy, float]] = {}


# The app bundles the CLI under Contents/Helpers (scripts/build-macos-website-release.sh);
# the MacOS/ path is the pre-release layout.
CLI_CANDIDATE_ROOTS = ["/Applications/OpenBurnBar.app", os.path.expanduser("~/Applications/OpenBurnBar.app")]
CLI_BUNDLE_RELATIVE_PATHS = ("Contents/Helpers/OpenBurnBarCLI", "Contents/MacOS/openburnbar-cli")
# Pinned from OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift
# (`teamID`, `daemonRPCPeerDesignatedRequirement`): the daemon admits the CLI peer only
# under this designated requirement, so the engine holds the courier to the same bar.
COURIER_TEAM_ID = "4Y367DF25B"
COURIER_IDENTIFIER = "com.openburnbar.cli"
COURIER_LINUX_ROOT = "/opt/openburnbar/bin/"


def verify_courier(path: str, *, platform: str = sys.platform, run: Callable[..., Any] = subprocess.run) -> bool:
    """Only a first-party signed CLI may be executed as the policy courier.

    A replacement binary named like the CLI could print a policy whose gateway
    points anywhere, so the engine checks the code signature (macOS: strict
    `codesign --verify` plus the designated requirement's identifier and team)
    or the root-owned package path (Linux) before running it. Fails closed."""
    try:
        if platform == "darwin":
            verified = run(
                ["codesign", "--verify", "--strict", path], capture_output=True, text=True, timeout=10, check=False
            )
            if verified.returncode != 0:
                return False
            shown = run(
                ["codesign", "-d", "--requirements", "-", path], capture_output=True, text=True, timeout=10, check=False
            )
            text = f"{shown.stdout}\n{shown.stderr}"
            return (
                f'identifier "{COURIER_IDENTIFIER}"' in text
                and f'certificate leaf[subject.OU] = "{COURIER_TEAM_ID}"' in text
            )
        if platform.startswith("linux"):
            if not path.startswith(COURIER_LINUX_ROOT):
                return False
            info = os.stat(path)
            return info.st_uid == 0 and not info.st_mode & 0o022
        return False
    except (OSError, subprocess.SubprocessError, ValueError):
        return False


def signed_cli_path() -> str | None:
    """The first-party signed CLI, the only courier the daemon trusts on signed installs."""
    override = os.environ.get(CLI_PATH_ENV, "").strip()
    if override:
        if os.path.isfile(override) and os.access(override, os.X_OK):
            # Under pytest the override is a test seam; in production it is verified like any candidate.
            if os.environ.get("PYTEST_CURRENT_TEST") or verify_courier(override):
                return override
        return None
    candidates = [
        os.path.join(root, relative) for relative in CLI_BUNDLE_RELATIVE_PATHS for root in CLI_CANDIDATE_ROOTS
    ]
    candidates.append(shutil.which("openburnbar-cli") or "")
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK) and verify_courier(candidate):
            return candidate
    return None


def default_courier() -> dict[str, Any] | None:
    """Run `openburnbar-cli memory-model-policy`; None when the CLI is absent or fails.

    Skipped under pytest so a test host never spawns the real CLI; tests use the env seam.
    """
    if os.environ.get("PYTEST_CURRENT_TEST"):
        return None
    cli = signed_cli_path()
    if not cli:
        return None
    try:
        completed = subprocess.run(
            [cli, "memory-model-policy"], capture_output=True, timeout=20, check=False, stdin=subprocess.DEVNULL
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    try:
        decoded = json.loads(completed.stdout.decode("utf-8", "replace"))
    except ValueError:
        return None
    return decoded if isinstance(decoded, dict) else None


def _env_policy() -> MemoryModelPolicy | None:
    if not os.environ.get("PYTEST_CURRENT_TEST"):
        return None
    raw = os.environ.get(MODEL_POLICY_JSON_ENV, "").strip()
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except ValueError:
        return None
    return MemoryModelPolicy.from_payload(payload) if isinstance(payload, dict) else None


def load_policy(
    *,
    courier: Callable[[], dict[str, Any] | None] | None = None,
    ttl_seconds: float = POLICY_TTL_SECONDS,
) -> MemoryModelPolicy | None:
    """The current policy, cached per courier for `ttl_seconds` or until its token nears expiry."""
    env_policy = _env_policy()
    if env_policy is not None:
        return env_policy
    fetch = courier or default_courier
    key = id(fetch)
    cached = _POLICY_CACHE.get(key)
    now = time.time()
    if cached is not None:
        policy, fetched_at = cached
        if now - fetched_at < ttl_seconds and not policy.token_expired(now=now):
            return policy
    payload = fetch()
    if not isinstance(payload, dict):
        _POLICY_CACHE.pop(key, None)
        return None
    policy = MemoryModelPolicy.from_payload(payload)
    _POLICY_CACHE[key] = (policy, now)
    return policy


def reset_policy_cache_for_tests() -> None:
    _POLICY_CACHE.clear()


# ---------------------------------------------------------------------------
# Clients


def _strip_fence(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("```"):
        stripped = stripped.split("\n", 1)[1] if "\n" in stripped else ""
        if stripped.rstrip().endswith("```"):
            stripped = stripped.rstrip()[:-3]
    return stripped.strip()


def _parse_json_object(text: str) -> dict[str, Any]:
    candidate = _strip_fence(text)
    try:
        parsed = json.loads(candidate)
    except ValueError:
        start, end = candidate.find("{"), candidate.rfind("}")
        if start < 0 or end <= start:
            raise ModelUnavailable("MODEL_UNAVAILABLE", "model returned no JSON object") from None
        try:
            parsed = json.loads(candidate[start : end + 1])
        except ValueError as exc:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"model returned invalid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise ModelUnavailable("MODEL_UNAVAILABLE", "model returned a non-object JSON answer")
    return parsed


class GatewayClient:
    """OpenAI-compatible chat and embeddings over the daemon's loopback gateway."""

    def __init__(self, base_url: str, token: str, *, timeouts: dict[str, float] | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeouts = dict(PURPOSE_TIMEOUTS)
        if timeouts:
            self.timeouts.update(timeouts)

    def _post(self, path: str, *, purpose: str, payload: dict[str, Any]) -> dict[str, Any]:
        data = json.dumps(payload).encode("utf-8")
        timeout = self.timeouts.get(purpose, 30.0)
        last_reason = "gateway unreachable"
        for attempt in range(1, GATEWAY_MAX_ATTEMPTS + 1):
            request = urllib.request.Request(
                self.base_url + path,
                data=data,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {self.token}",
                    "X-OpenBurnBar-Purpose": purpose,
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 — loopback gateway
                    body = json.loads(response.read().decode("utf-8"))
                if not isinstance(body, dict):
                    raise ModelUnavailable("MODEL_UNAVAILABLE", "gateway returned a non-object body")
                return body
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", "replace") if exc.fp else ""
                code, message = _gateway_error(detail)
                if code in POLICY_ERROR_CODES and code != "MODEL_UNAVAILABLE":
                    raise ModelUnavailable(code, message) from exc
                last_reason = message or f"gateway status {exc.code}"
                if exc.code not in GATEWAY_RETRY_STATUSES or attempt == GATEWAY_MAX_ATTEMPTS:
                    raise ModelUnavailable("MODEL_UNAVAILABLE", last_reason) from exc
            except (urllib.error.URLError, OSError, ValueError) as exc:
                last_reason = f"gateway request failed: {exc}"
                if attempt == GATEWAY_MAX_ATTEMPTS:
                    raise ModelUnavailable("MODEL_UNAVAILABLE", last_reason) from exc
            time.sleep(random.uniform(0.2, 0.8))  # noqa: S311 — jitter, not security
        raise ModelUnavailable("MODEL_UNAVAILABLE", last_reason)

    def chat_json(
        self,
        *,
        purpose: str,
        model: str,
        system: str,
        user: str,
        max_tokens: int = 1024,
        temperature: float = 0.0,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        body = self._post(
            "/v1/chat/completions",
            purpose=purpose,
            payload={
                "model": model,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                "temperature": temperature,
                "max_tokens": max_tokens,
                "response_format": {"type": "json_object"},
                "stream": False,
            },
        )
        choices = body.get("choices") or []
        content = ""
        if choices and isinstance(choices[0], dict):
            message = choices[0].get("message") or {}
            content = str(message.get("content") or "")
        parsed = _parse_json_object(content)
        usage = body.get("usage") if isinstance(body.get("usage"), dict) else {}
        return parsed, dict(usage)

    def embed(self, *, purpose: str, model: str, texts: Sequence[str]) -> list[list[float]]:
        body = self._post("/v1/embeddings", purpose=purpose, payload={"model": model, "input": list(texts)})
        rows = body.get("data") or []
        ordered = sorted((row for row in rows if isinstance(row, dict)), key=lambda row: int(row.get("index", 0)))
        vectors = [[float(value) for value in row.get("embedding") or []] for row in ordered]
        if len(vectors) != len(texts):
            raise ModelUnavailable(
                "MODEL_UNAVAILABLE", f"gateway returned {len(vectors)} vectors for {len(texts)} inputs"
            )
        return vectors


def _gateway_error(detail: str) -> tuple[str, str]:
    try:
        payload = json.loads(detail) if detail else {}
    except ValueError:
        return "MODEL_UNAVAILABLE", detail[:200]
    error = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(error, dict):
        return str(error.get("code") or "MODEL_UNAVAILABLE"), str(error.get("message") or "")
    if isinstance(error, str):
        return "MODEL_UNAVAILABLE", error
    return "MODEL_UNAVAILABLE", detail[:200]


CLAUDE_DISALLOWED_TOOLS = (
    "Bash,Write,Edit,MultiEdit,NotebookEdit,Read,Grep,Glob,LS,WebFetch,WebSearch,Agent,Task,TodoWrite,TodoRead"
)
_CLI_ENV_KEEP = ("PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "TMPDIR", "TZ")
_CLI_ENV_KEEP_PREFIXES = ("LC_", "XDG_", "ANTHROPIC_", "OPENAI_", "CLAUDE_", "CODEX_")


def sanitized_cli_environment(source: dict[str, str] | None = None) -> dict[str, str]:
    """Only what a subscription CLI needs: locale, paths, and its own auth/config.

    Daemon tokens, cloud credentials, SSH/git material and every OpenBurnBar
    variable stay out of a process whose prompt is untrusted memory text."""
    env = dict(os.environ if source is None else source)
    return {key: value for key, value in env.items() if key in _CLI_ENV_KEEP or key.startswith(_CLI_ENV_KEEP_PREFIXES)}


class CLIClient:
    """The official CLIs on the user's own subscription quota, read-only and sandboxed."""

    @staticmethod
    def claude_argv(prompt: str, model: str | None) -> list[str]:
        argv = [
            "claude",
            "-p",
            prompt,
            "--output-format",
            "json",
            "--permission-mode",
            "plan",
            # Every tool off: the prompt is untrusted memory text, so the CLI must
            # neither read this Mac nor reach the network on its behalf.
            "--disallowedTools",
            CLAUDE_DISALLOWED_TOOLS,
        ]
        if model:
            argv += ["--model", model]
        return argv

    @staticmethod
    def codex_argv(prompt: str, model: str | None) -> list[str]:
        # Same posture as BurnBarCodexProviderExecutor: read-only sandbox, no user
        # automation or rules, throwaway cwd (see chat_json).
        argv = [
            "codex",
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--ignore-user-config",
            "--ignore-rules",
        ]
        if model:
            argv += ["-m", model]
        return argv + [prompt]

    def chat_json(self, *, provider: str, model: str | None, prompt: str, timeout: float) -> dict[str, Any]:
        if provider == "claude_cli":
            argv = self.claude_argv(prompt, model)
        elif provider == "codex_cli":
            argv = self.codex_argv(prompt, model)
        else:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"unknown CLI provider {provider}")
        try:
            with tempfile.TemporaryDirectory(prefix="openburnbar-memory-cli-") as scratch:
                os.chmod(scratch, 0o700)
                completed = subprocess.run(
                    argv,
                    capture_output=True,
                    text=True,
                    timeout=timeout,
                    check=False,
                    cwd=scratch,
                    env=sanitized_cli_environment(),
                )
        except subprocess.TimeoutExpired as exc:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"{provider} timed out after {timeout:.0f}s") from exc
        except (OSError, subprocess.SubprocessError) as exc:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"{provider} unavailable: {exc}") from exc
        if completed.returncode != 0:
            raise ModelUnavailable(
                "MODEL_UNAVAILABLE", f"{provider} exited {completed.returncode}: {completed.stderr[:200]}"
            )
        return self._parse_output(provider, completed.stdout)

    @staticmethod
    def _parse_output(provider: str, stdout: str) -> dict[str, Any]:
        text = stdout.strip()
        if provider == "claude_cli":
            try:
                wrapper = json.loads(text)
            except ValueError:
                wrapper = None
            if isinstance(wrapper, dict) and "result" in wrapper:
                text = str(wrapper.get("result") or "")
            return _parse_json_object(text)
        last_message = ""
        for line in text.splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            item = event.get("item") if isinstance(event, dict) else None
            if isinstance(item, dict) and item.get("type") == "agent_message":
                last_message = str(item.get("text") or "")
        return _parse_json_object(last_message or text)


# ---------------------------------------------------------------------------
# Router


@dataclass
class ModelCall:
    provider: str
    model: str
    purpose: str
    client: GatewayClient | CLIClient

    @property
    def is_cli(self) -> bool:
        return self.provider in CLI_PROVIDER_IDS

    @property
    def label(self) -> str:
        return f"{self.provider}/{self.model}"

    def json(self, system: str, user: str, *, max_tokens: int = 1024) -> tuple[dict[str, Any], dict[str, Any]]:
        if isinstance(self.client, CLIClient):
            model = None if self.model == "default" else self.model
            parsed = self.client.chat_json(
                provider=self.provider,
                model=model,
                prompt=f"{system}\n\n{user}",
                timeout=PURPOSE_TIMEOUTS.get(self.purpose, 60.0),
            )
            return parsed, {}
        return self.client.chat_json(
            purpose=self.purpose, model=self.label, system=system, user=user, max_tokens=max_tokens
        )

    def embed(self, texts: Sequence[str]) -> list[list[float]]:
        if isinstance(self.client, CLIClient):
            raise ModelUnavailable("MODEL_UNAVAILABLE", "CLI providers cannot embed")
        return self.client.embed(purpose=self.purpose, model=self.label, texts=texts)


class ModelRouter:
    """Picks the client for a purpose from the policy, or raises a typed refusal."""

    def __init__(
        self,
        policy: MemoryModelPolicy | None,
        *,
        gateway: GatewayClient | None = None,
        cli: CLIClient | None = None,
    ) -> None:
        self.policy = policy
        self._gateway = gateway
        self._cli = cli or CLIClient()

    @property
    def available(self) -> bool:
        return self.policy is not None and self.policy.pro_active and self.policy.enabled

    def serves(self, purpose: str) -> bool:
        return self.policy is not None and self.policy.usable(purpose)

    def _gateway_client(self) -> GatewayClient:
        if self._gateway is not None:
            return self._gateway
        policy = self.policy
        if policy is None or not policy.gateway_url or not policy.gateway_token:
            raise ModelUnavailable("MODEL_UNAVAILABLE", "the daemon gateway is not available for memory purposes")
        self._gateway = GatewayClient(policy.gateway_url, policy.gateway_token)
        return self._gateway

    def call(self, purpose: str, provider_hint: str | None = None) -> ModelCall:
        if purpose not in PURPOSES:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"unknown purpose {purpose}")
        policy = self.policy
        if policy is None:
            raise ModelUnavailable(
                "CLOUD_CONSENT_REQUIRED", "no memory model policy (daemon courier unavailable or cloud models off)"
            )
        if not policy.pro_active:
            raise ModelUnavailable("PRO_REQUIRED", "BurnBar Pro is not active on this Mac")
        if not policy.enabled:
            raise ModelUnavailable("CLOUD_CONSENT_REQUIRED", "cloud models for memory are turned off")
        candidates = policy.models_for(purpose)
        hint = (provider_hint or "").strip().lower() or None
        if hint:
            matching = [item for item in candidates if item.split("/", 1)[0] == hint]
            if not matching:
                raise ModelUnavailable("PROVIDER_NOT_CONSENTED", f"provider {hint} is not enabled for {purpose}")
            candidates = matching
        if not candidates:
            raise ModelUnavailable("MODEL_UNAVAILABLE", f"no consented model for {purpose}")
        provider, model = candidates[0].split("/", 1)
        client: GatewayClient | CLIClient = self._cli if provider in CLI_PROVIDER_IDS else self._gateway_client()
        return ModelCall(provider=provider, model=model, purpose=purpose, client=client)

    @staticmethod
    def outcome(purpose: str, *, applied: bool, code: str | None = None, model: str | None = None) -> dict[str, Any]:
        return {"purpose": purpose, "applied": applied, "code": code, "model": model}
