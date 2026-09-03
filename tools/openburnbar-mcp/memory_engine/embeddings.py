"""Embedding providers, the float32 vector codec, and the process-local
provider cache."""

from __future__ import annotations

import hashlib
import json
import math
import os
import struct
import urllib.error
import urllib.request
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any

from ._util import sha256_hex
from .constants import (
    DEFAULT_EMBEDDING_MODEL,
    DEFAULT_OLLAMA_BASE_URL,
    EMBEDDING_MODEL_ENV,
    EMBEDDING_PROVIDER_ENV,
    OLLAMA_BASE_URL_ENV,
)
from .text import tokenize


class EmbeddingProvider:
    version_id: str = "none"
    dimension: int = 0

    @property
    def available(self) -> bool:
        return self.dimension > 0

    def embed(self, texts: Sequence[str]) -> list[list[float] | None]:
        return [None for _ in texts]

    def describe(self) -> dict[str, Any]:
        return {"provider": "none", "model": None, "dimension": 0, "versionID": self.version_id, "available": False}


class NullEmbeddingProvider(EmbeddingProvider):
    def __init__(self, reason: str = "no embedding provider configured") -> None:
        self.reason = reason

    def describe(self) -> dict[str, Any]:
        payload = super().describe()
        payload["reason"] = self.reason
        return payload


class OllamaEmbeddingProvider(EmbeddingProvider):
    def __init__(self, model: str, base_url: str, timeout: float = 30.0) -> None:
        self.model = model
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.dimension = 0
        self.version_id = f"ollama:{model}:unavailable"
        self.error: str | None = None
        self._probe()

    def _get(self, path: str) -> dict[str, Any]:
        request = urllib.request.Request(self.base_url + path, method="GET")
        with urllib.request.urlopen(request, timeout=self.timeout) as response:  # noqa: S310 — loopback URL from config
            return json.loads(response.read().decode("utf-8"))

    def _post(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        request = urllib.request.Request(
            self.base_url + path,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=self.timeout) as response:  # noqa: S310 — loopback URL from config
            return json.loads(response.read().decode("utf-8"))

    def _probe(self) -> None:
        try:
            tags = self._get("/api/tags")
            models = tags.get("models") or []
            names = (self.model, f"{self.model}:latest") if ":" not in self.model else (self.model,)
            candidates = [
                item
                for item in models
                if isinstance(item, dict) and any(str(item.get(key) or "") in names for key in ("name", "model"))
            ]
            if not candidates and ":" not in self.model:
                candidates = [
                    item
                    for item in models
                    if isinstance(item, dict)
                    and any(str(item.get(key) or "").split(":", 1)[0] == self.model for key in ("name", "model"))
                ]
            if len(candidates) != 1 or not str(candidates[0].get("digest") or "").strip():
                raise ValueError(f"cannot resolve one served digest for Ollama model {self.model}")
            digest = str(candidates[0]["digest"]).strip().lower()
            result = self._post("/api/embed", {"model": self.model, "input": ["openburnbar memory probe"]})
            vectors = result.get("embeddings") or []
            dimension = len(vectors[0]) if vectors and vectors[0] else 0
        except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            dimension = 0
        self.dimension = dimension
        if dimension:
            endpoint_id = sha256_hex(self.base_url)[:12]
            self.version_id = f"ollama:{self.model}:{dimension}:{endpoint_id}:{digest}"

    def embed(self, texts: Sequence[str]) -> list[list[float] | None]:
        if not self.available or not texts:
            return [None for _ in texts]
        try:
            result = self._post("/api/embed", {"model": self.model, "input": list(texts)})
        except (urllib.error.URLError, OSError, ValueError) as exc:
            self.error = f"{type(exc).__name__}: {exc}"
            return [None for _ in texts]
        vectors = result.get("embeddings") or []
        out: list[list[float] | None] = []
        for vector in vectors:
            if isinstance(vector, list) and len(vector) == self.dimension:
                out.append(_l2_normalize([float(v) for v in vector]))
            else:
                out.append(None)
        while len(out) < len(texts):
            out.append(None)
        return out

    def describe(self) -> dict[str, Any]:
        return {
            "provider": "ollama",
            "model": self.model,
            "baseURL": self.base_url,
            "dimension": self.dimension,
            "versionID": self.version_id,
            "available": self.available,
            "error": self.error,
        }


class FakeEmbeddingProvider(EmbeddingProvider):
    """Deterministic bag-of-tokens embedding for tests. Not semantic; stable."""

    def __init__(self, dimension: int = 64, version_tag: str = "fake-v1") -> None:
        self.dimension = dimension
        self.version_id = f"fake:{version_tag}:{dimension}"

    def embed(self, texts: Sequence[str]) -> list[list[float] | None]:
        out: list[list[float] | None] = []
        for text in texts:
            vector = [0.0] * self.dimension
            for token in tokenize(text):
                digest = hashlib.sha256(token.encode("utf-8")).digest()
                index = int.from_bytes(digest[:4], "big") % self.dimension
                sign = 1.0 if digest[4] % 2 == 0 else -1.0
                vector[index] += sign
            out.append(_l2_normalize(vector) if any(vector) else None)
        return out

    def describe(self) -> dict[str, Any]:
        return {
            "provider": "fake",
            "model": "fake",
            "dimension": self.dimension,
            "versionID": self.version_id,
            "available": True,
        }


class GatewayEmbeddingProvider(EmbeddingProvider):
    """Embeddings through the daemon's loopback gateway under the `memory-embed` purpose.

    The engine never sees a provider key: `call` carries the 15-minute scoped
    bearer from the courier policy. One probe at construction fixes the
    dimension; a refusal leaves the provider unavailable with the gateway's code."""

    def __init__(self, call: Any, *, models: Any = None) -> None:
        from .providers import ModelUnavailable

        self.call = call
        self.models = models
        self._auth_failed = False
        self.model = str(call.label)
        self.dimension = 0
        self.error: str | None = None
        self.version_id = f"gateway:{self.model}:unavailable"
        try:
            probe = call.embed(["openburnbar memory probe"])
            dimension = len(probe[0]) if probe and probe[0] else 0
        except ModelUnavailable as exc:
            self.error = exc.code
            dimension = 0
        if dimension:
            self.dimension = dimension
            self.version_id = f"gateway:{self.model}:{dimension}"

    def embed(self, texts: Sequence[str]) -> list[list[float] | None]:
        from .providers import ModelUnavailable

        if not self.available or not texts:
            return [None for _ in texts]
        try:
            vectors = self.call.embed(list(texts))
        except ModelUnavailable as exc:
            self.error = exc.code
            if exc.code in ("UNAUTHORIZED", "TOKEN_EXPIRED", "INVALID_TOKEN"):
                self._auth_failed = True
            return [None for _ in texts]
        out: list[list[float] | None] = []
        for vector in vectors:
            out.append(_l2_normalize([float(v) for v in vector]) if len(vector) == self.dimension else None)
        while len(out) < len(texts):
            out.append(None)
        return out

    @property
    def stale(self) -> bool:
        """True once the scoped bearer behind `call` has expired (or was refused), so a cache must rebuild it."""
        if self._auth_failed:
            return True
        policy = getattr(self.models, "policy", None)
        return bool(policy is not None and policy.token_expired())

    def describe(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "provider": "gateway",
            "model": self.model,
            "dimension": self.dimension,
            "versionID": self.version_id,
            "available": self.available,
        }
        if self.error is not None:
            payload["error"] = self.error
        return payload


def _l2_normalize(vector: list[float]) -> list[float]:
    norm = math.sqrt(sum(v * v for v in vector))
    if norm <= 0 or not math.isfinite(norm):
        return vector
    return [v / norm for v in vector]


def _cosine(a: Sequence[float], b: Sequence[float]) -> float:
    if len(a) != len(b) or not a:
        return 0.0
    return float(sum(x * y for x, y in zip(a, b, strict=False)))


def encode_vector(vector: Sequence[float]) -> bytes:
    return struct.pack(f"<{len(vector)}f", *vector)


def decode_vector(blob: bytes, dimension: int) -> list[float] | None:
    if not blob or dimension <= 0 or len(blob) != dimension * 4:
        return None
    return list(struct.unpack(f"<{dimension}f", blob))


_PROVIDER_CACHE: dict[str, EmbeddingProvider] = {}


@dataclass(frozen=True)
class EmbeddingContext:
    """What a provider factory may read: the configured name, the local model, and the Ollama URL."""

    configured: str
    model: str
    base_url: str


def _disabled(_context: EmbeddingContext) -> EmbeddingProvider:
    return NullEmbeddingProvider("embedding provider disabled by configuration")


def _ollama(context: EmbeddingContext) -> EmbeddingProvider:
    candidate = OllamaEmbeddingProvider(model=context.model, base_url=context.base_url)
    if candidate.available:
        return candidate
    if context.configured == "ollama":
        return NullEmbeddingProvider(f"ollama unavailable: {candidate.error}")
    return NullEmbeddingProvider(f"ollama not reachable or model '{context.model}' not pulled (auto mode)")


def _pro(_context: EmbeddingContext) -> EmbeddingProvider:
    """Memory Pro embeddings: the courier policy decides the model, the gateway holds the key."""
    from .providers import ModelRouter, ModelUnavailable, load_policy

    try:
        models = ModelRouter(load_policy())
        candidate = GatewayEmbeddingProvider(models.call("memory-embed"), models=models)
    except ModelUnavailable as exc:
        return NullEmbeddingProvider(f"gateway embeddings unavailable: {exc.code}: {exc.reason}")
    if candidate.available:
        return candidate
    return NullEmbeddingProvider(f"gateway embeddings unavailable: {candidate.error}")


EMBEDDING_PROVIDER_FACTORIES: dict[str, Callable[[EmbeddingContext], EmbeddingProvider]] = {
    "none": _disabled,
    "off": _disabled,
    "lexical": _disabled,
    "auto": _ollama,
    "ollama": _ollama,
    "pro": _pro,
}
# Providers that depend on a live service are not cached while unavailable:
# a process can start before Ollama, its model, or the daemon is ready, and
# caching that transient miss would turn a recoverable outage into a restart.
_TRANSIENT_PROVIDERS = frozenset({"auto", "ollama", "pro"})


def embedding_provider(force: EmbeddingProvider | None = None) -> EmbeddingProvider:
    if force is not None:
        return force
    configured = os.environ.get(EMBEDDING_PROVIDER_ENV, "auto").strip().lower() or "auto"
    model = os.environ.get(EMBEDDING_MODEL_ENV, DEFAULT_EMBEDDING_MODEL).strip() or DEFAULT_EMBEDDING_MODEL
    base_url = os.environ.get(OLLAMA_BASE_URL_ENV, DEFAULT_OLLAMA_BASE_URL).strip() or DEFAULT_OLLAMA_BASE_URL
    cache_key = f"{configured}|{model}|{base_url}"
    cached = _PROVIDER_CACHE.get(cache_key)
    if cached is not None:
        if not getattr(cached, "stale", False):
            return cached
        _PROVIDER_CACHE.pop(cache_key, None)  # an expired bearer never serves from cache
    factory = EMBEDDING_PROVIDER_FACTORIES.get(configured)
    provider: EmbeddingProvider
    if factory is None:
        provider = NullEmbeddingProvider(f"unknown embedding provider '{configured}'")
    else:
        provider = factory(EmbeddingContext(configured=configured, model=model, base_url=base_url))
    if provider.available or configured not in _TRANSIENT_PROVIDERS:
        _PROVIDER_CACHE[cache_key] = provider
    return provider


def reset_provider_cache_for_tests() -> None:
    _PROVIDER_CACHE.clear()
    from . import providers

    providers.reset_policy_cache_for_tests()
    # Deferred: `engine` imports this module, and its project cache is engine
    # state. Reaching for it at call time keeps this module a leaf.
    from . import engine

    engine._PROJECT_CACHE.clear()
