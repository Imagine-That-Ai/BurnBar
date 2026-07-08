import Foundation

extension CursorConnectorManager {
    /// Python source for the proxy's per-client sliding-window rate limiter,
    /// failed-auth cap, and client-identity derivation. Emitted verbatim into
    /// `proxyScript()` at module scope; split out to keep that function within
    /// the repo's body-length ratchet.
    private static func proxyRateLimitHelpers() -> String {
        """
        # Sliding-window rate limiter: {client_ip: [(timestamp, count), ...]}
        MAX_TRACKED_CLIENTS = 4096
        _rate_limit_lock = threading.Lock()
        _rate_limit_state = {}
        _auth_fail_lock = threading.Lock()
        _auth_fail_state = {}

        def _normalize_client_ip(value):
            if not isinstance(value, str):
                return None
            token = value.split(",", 1)[0].strip()
            try:
                return ipaddress.ip_address(token).compressed if token else None
            except ValueError:
                return None

        def _client_identity(handler):
            peer = handler.client_address[0] if handler.client_address else None
            normalized_peer = _normalize_client_ip(peer)
            if normalized_peer in ("127.0.0.1", "::1"):
                connecting_ip = _normalize_client_ip(handler.headers.get("Cf-Connecting-IP"))
                if connecting_ip:
                    return f"cf:{connecting_ip}"
            return f"peer:{normalized_peer or 'unknown'}"

        def _remember_client_entries(state, client_ip, entries, window_start):
            if entries:
                state[client_ip] = entries
            else:
                state.pop(client_ip, None)
            if len(state) <= MAX_TRACKED_CLIENTS:
                return
            for key, existing in list(state.items()):
                fresh = [(ts, cnt) for ts, cnt in existing if ts > window_start]
                if fresh:
                    state[key] = fresh
                else:
                    state.pop(key, None)
            while len(state) > MAX_TRACKED_CLIENTS:
                state.pop(next(iter(state)))

        def _rate_limit_check(client_ip):
            # Returns (allowed, current_count). thread-safe.
            now = time.time()
            window_start = now - RATE_LIMIT_WINDOW
            with _rate_limit_lock:
                entries = _rate_limit_state.get(client_ip, [])
                entries = [(ts, cnt) for ts, cnt in entries if ts > window_start]
                total = sum(cnt for _, cnt in entries)
                if total >= RATE_LIMIT_REQUESTS:
                    _remember_client_entries(_rate_limit_state, client_ip, entries, window_start)
                    return False, total
                _remember_client_entries(_rate_limit_state, client_ip, entries, window_start)
                return True, total

        def _rate_limit_record(client_ip, request_size=1):
            now = time.time()
            window_start = now - RATE_LIMIT_WINDOW
            with _rate_limit_lock:
                entries = _rate_limit_state.get(client_ip, [])
                entries = [(ts, cnt) for ts, cnt in entries if ts > window_start]
                entries.append((now, request_size))
                _remember_client_entries(_rate_limit_state, client_ip, entries, window_start)

        def _auth_fail_record(client_ip, request_size=1):
            now = time.time()
            with _auth_fail_lock:
                entries = _auth_fail_state.get(client_ip, [])
                window_start = now - RATE_LIMIT_WINDOW
                entries = [(ts, cnt) for ts, cnt in entries if ts > window_start]
                entries.append((now, request_size))
                _remember_client_entries(_auth_fail_state, client_ip, entries, window_start)
                return sum(cnt for _, cnt in entries)

        def _send_rate_limited(handler, limit):
            handler.send_response(HTTPStatus.TOO_MANY_REQUESTS)
            handler.send_header("Retry-After", str(RATE_LIMIT_WINDOW))
            handler.send_header("X-RateLimit-Limit", str(limit))
            handler.send_header("X-RateLimit-Remaining", "0")
            handler.send_header("Content-Type", "application/json")
            handler.send_header("Content-Length", "0")
            handler.end_headers()

        def _constant_time_ascii_equal(value, expected):
            if not isinstance(value, str) or not isinstance(expected, str):
                return False
            try:
                return hmac.compare_digest(value.encode("ascii"), expected.encode("ascii"))
            except UnicodeEncodeError:
                return False
        """
    }

    static func proxyScript() -> String {
        """
        #!/usr/bin/env python3
        import hmac, ipaddress, json, ssl, sys, uuid, datetime, time, threading
        from http import HTTPStatus
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from urllib.error import HTTPError, URLError; from urllib.request import Request, urlopen

        CONFIG_PATH = sys.argv[1]

        def load_config():
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)

        SECRET_CACHE = {}

        def resolve_route_api_key(route):
            direct = route.get("api_key")
            if isinstance(direct, str) and direct.strip():
                return direct.strip()
            route_id = route.get("route_id")
            config = load_config()
            broker_url = config.get("secret_broker_url")
            broker_token = config.get("secret_broker_token")
            if not isinstance(route_id, str) or not route_id:
                return None
            if not isinstance(broker_url, str) or not broker_url:
                return None
            if not isinstance(broker_token, str) or not broker_token:
                return None
            if route_id in SECRET_CACHE:
                return SECRET_CACHE[route_id]
            try:
                req = Request(
                    broker_url.rstrip("/") + "/secret/" + route_id,
                    headers={"Authorization": "Bearer " + broker_token},
                )
                with urlopen(req, timeout=2) as resp:
                    payload = json.loads(resp.read().decode("utf-8"))
            except Exception:
                return None
            secret = payload.get("api_key") if isinstance(payload, dict) else None
            if not secret:
                return None
            SECRET_CACHE[route_id] = secret
            return secret

        def extract_text_parts(content):
            if content is None:
                return []
            if isinstance(content, str):
                return [content]
            if isinstance(content, list):
                parts = []
                for item in content:
                    if isinstance(item, str):
                        parts.append(item)
                    elif isinstance(item, dict):
                        t = item.get("type")
                        if t in ("input_text", "output_text", "text") and isinstance(item.get("text"), str):
                            parts.append(item["text"])
                return parts
            if isinstance(content, dict) and isinstance(content.get("text"), str):
                return [content["text"]]
            return []

        def copy_passthrough_fields(source, target, fields):
            if not isinstance(source, dict) or not isinstance(target, dict):
                return target
            for field in fields:
                if field in source and source.get(field) is not None:
                    target[field] = source.get(field)
            return target

        def response_item_to_chat_messages(item):
            if not isinstance(item, dict):
                return []

            item_type = item.get("type")
            if item_type in ("function_call", "custom_tool_call"):
                call_id = item.get("call_id") or item.get("id") or f"call_{uuid.uuid4().hex}"
                function_source = item.get("function") if isinstance(item.get("function"), dict) else {}
                function_payload = {
                    "name": item.get("name") or function_source.get("name") or "tool",
                    "arguments": item.get("arguments") or item.get("input") or function_source.get("arguments") or "{}",
                }
                message = {
                    "role": "assistant",
                    "content": item.get("content") if item.get("content") is not None else "",
                    "tool_calls": [{
                        "id": call_id,
                        "type": "function",
                        "function": function_payload,
                    }],
                }
                copy_passthrough_fields(item, message, ("reasoning_content", "thinking", "reasoning"))
                return [message]

            if item_type in ("function_call_output", "tool_result"):
                message = {
                    "role": "tool",
                    "content": "\\n".join(extract_text_parts(item.get("output") if "output" in item else item.get("content"))),
                    "tool_call_id": item.get("call_id") or item.get("tool_call_id") or item.get("id") or "",
                }
                copy_passthrough_fields(item, message, ("name",))
                return [message]

            role = item.get("role") or "user"
            if role == "developer":
                role = "system"
            message = {"role": role}
            text = "\\n".join(extract_text_parts(item.get("content")))
            if item.get("content") is not None:
                message["content"] = text
            else:
                message["content"] = item.get("output") if isinstance(item.get("output"), str) else ""
            copy_passthrough_fields(
                item,
                message,
                ("reasoning_content", "thinking", "reasoning", "tool_calls", "tool_call_id", "name")
            )
            if message.get("content") or message.get("reasoning_content") or message.get("tool_calls") or message.get("tool_call_id"):
                return [message]
            return []

        def chat_message_to_response_output(message):
            content = message.get("content")
            if isinstance(content, str):
                text = content
            else:
                text = "\\n".join(extract_text_parts(content))

            output_items = []
            message_item = {
                "id": f"msg_{uuid.uuid4().hex}",
                "type": "message",
                "status": "completed",
                "role": message.get("role") or "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}],
            }
            copy_passthrough_fields(message, message_item, ("reasoning_content", "thinking", "reasoning"))
            output_items.append(message_item)

            tool_calls = message.get("tool_calls")
            if isinstance(tool_calls, list):
                for tool_call in tool_calls:
                    if not isinstance(tool_call, dict):
                        continue
                    function_payload = tool_call.get("function") if isinstance(tool_call.get("function"), dict) else {}
                    call_id = tool_call.get("id") or f"call_{uuid.uuid4().hex}"
                    call_item = {
                        "id": call_id,
                        "type": "function_call",
                        "status": "completed",
                        "call_id": call_id,
                        "name": function_payload.get("name") or tool_call.get("name") or "tool",
                        "arguments": function_payload.get("arguments") or tool_call.get("arguments") or "{}",
                    }
                    output_items.append(call_item)
            return output_items, text

        def int_value(value):
            if value is None or isinstance(value, bool):
                return None
            if isinstance(value, (int, float)):
                return max(int(round(value)), 0)
            if isinstance(value, str):
                stripped = value.strip()
                if not stripped:
                    return None
                try:
                    return max(int(round(float(stripped))), 0)
                except ValueError:
                    return None
            return None

        def usage_number(usage, *paths):
            if not isinstance(usage, dict):
                return 0
            for path in paths:
                cursor = usage
                valid_path = True
                for key in path:
                    if not isinstance(cursor, dict):
                        valid_path = False
                        break
                    cursor = cursor.get(key)
                if not valid_path:
                    continue
                parsed = int_value(cursor)
                if parsed is not None:
                    return parsed
            return 0

        def estimate_prompt_chars(request_payload):
            if not isinstance(request_payload, dict):
                return 0
            messages = request_payload.get("messages")
            if not isinstance(messages, list):
                return 0
            total = 0
            for message in messages:
                if not isinstance(message, dict):
                    continue
                text = "\\n".join(extract_text_parts(message.get("content")))
                if text:
                    total += len(text)
            return total

        def extract_chat_completion_text(payload):
            if not isinstance(payload, dict):
                return ""
            choice = (payload.get("choices") or [{}])[0]
            if not isinstance(choice, dict):
                return ""
            message = choice.get("message") or {}
            if not isinstance(message, dict):
                return ""
            return "\\n".join(extract_text_parts(message.get("content")))

        def normalize_usage(usage, prompt_char_estimate=0, output_char_estimate=0):
            prompt = usage_number(
                usage,
                ("prompt_tokens",),
                ("input_tokens",),
                ("promptTokens",),
                ("inputTokens",)
            )
            completion = usage_number(
                usage,
                ("completion_tokens",),
                ("output_tokens",),
                ("completionTokens",),
                ("outputTokens",)
            )
            cache_creation = usage_number(
                usage,
                ("cache_creation_input_tokens",),
                ("cache_creation_tokens",),
                ("cacheCreationTokens",)
            )
            cache_read = usage_number(
                usage,
                ("cache_read_tokens",),
                ("cache_read_input_tokens",),
                ("cacheReadTokens",),
                ("prompt_tokens_details", "cached_tokens"),
                ("promptTokensDetails", "cachedTokens"),
                ("cached_tokens",),
                ("cachedTokens",)
            )
            # VAL-TOKEN-006: Extract reasoning tokens from all known paths
            reasoning_tokens = usage_number(
                usage,
                ("thinking_tokens",),
                ("reasoning_tokens",),
                ("thinkingTokens",),
                ("reasoningTokens",),
                ("completion_tokens_details", "reasoning_tokens"),
                ("output_tokens_details", "reasoning_tokens")
            )
            total = usage_number(usage, ("total_tokens",), ("totalTokens",))

            explicit_total = prompt + completion + cache_creation + cache_read
            normalized_total = max(total, explicit_total)

            # VAL-TOKEN-004: Normalization occurs when total_tokens is present.
            # Deriving input/output from total_tokens is normalization (VAL-TOKEN-004), not fallback.
            # Fallback (character-based estimation) only occurs when total_tokens is absent AND all buckets are 0.
            if normalized_total > 0:
                # Normalization: derive missing primary buckets from total_tokens.
                # VAL-TOKEN-006: Reasoning tokens are a separate bucket and must be subtracted
                # from available_for_in_out to prevent them from being incorrectly added to completion.
                available_for_in_out = max(normalized_total - cache_creation - cache_read - reasoning_tokens, 0)
                if available_for_in_out > 0:
                    if prompt == 0 and completion == 0:
                        # Both missing but total available - use hints to split or default ratio
                        combined_hint = prompt_char_estimate + output_char_estimate
                        if combined_hint > 0:
                            ratio = prompt_char_estimate / combined_hint
                        else:
                            ratio = 0.62
                        prompt = int(round(available_for_in_out * ratio))
                        completion = max(available_for_in_out - prompt, 0)
                    elif prompt == 0 and completion > 0 and available_for_in_out > completion:
                        prompt = available_for_in_out - completion
                    elif completion == 0 and prompt > 0 and available_for_in_out > prompt:
                        completion = available_for_in_out - prompt
                    elif prompt + completion < available_for_in_out:
                        completion += available_for_in_out - (prompt + completion)
            elif prompt == 0 and completion == 0 and cache_creation == 0 and cache_read == 0 and reasoning_tokens == 0 and prompt_char_estimate + output_char_estimate > 0:
                # Fallback: character-based estimation only when NO total_tokens and NO token buckets.
                # VAL-TOKEN-004 / VAL-TOKEN-006: Explicit reasoning_tokens are exact usage data;
                # fallback must NOT run when any exact bucket (including reasoning) is present.
                if prompt_char_estimate > 0:
                    prompt = max(int(round(prompt_char_estimate / 3.35)), 1)
                if output_char_estimate > 0:
                    completion = max(int(round(output_char_estimate / 3.35)), 1)

            # VAL-TOKEN-006: Reasoning tokens are preserved explicitly, not folded into completion.
            # If the provider reports reasoning tokens separately, they remain as a distinct bucket.

            return {
                "prompt_tokens": max(prompt, 0),
                "completion_tokens": max(completion, 0),
                "cache_creation_tokens": max(cache_creation, 0),
                "cache_read_tokens": max(cache_read, 0),
                "reasoning_tokens": max(reasoning_tokens, 0),
                "total_tokens": max(normalized_total, prompt + completion + cache_creation + cache_read),
            }

        def parse_stream_usage(stream_bytes):
            text = stream_bytes.decode("utf-8", errors="ignore")
            usage = {}
            output_parts = []
            event_id = None

            for raw_line in text.splitlines():
                line = raw_line.strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if not payload or payload == "[DONE]":
                    continue
                try:
                    event = json.loads(payload)
                except json.JSONDecodeError:
                    continue

                if event_id is None and isinstance(event.get("id"), str):
                    event_id = event.get("id")

                if isinstance(event.get("usage"), dict):
                    usage = event.get("usage") or usage

                choices = event.get("choices")
                if isinstance(choices, list) and choices:
                    first_choice = choices[0] if isinstance(choices[0], dict) else {}
                    delta = first_choice.get("delta") or {}
                    if isinstance(delta, dict):
                        output_parts.extend(extract_text_parts(delta.get("content")))
                    message = first_choice.get("message")
                    if isinstance(message, dict):
                        output_parts.extend(extract_text_parts(message.get("content")))

                if isinstance(event.get("output_text"), str):
                    output_parts.append(event["output_text"])

            if not usage and not output_parts:
                return None

            return {
                "id": event_id or f"stream_{uuid.uuid4().hex}",
                "usage": usage,
                "output_text": "\\n".join([part for part in output_parts if part]),
            }

        def responses_to_chat_payload(payload):
            messages = []
            instructions = payload.get("instructions")
            if isinstance(instructions, str) and instructions.strip():
                messages.append({"role": "system", "content": instructions})
            input_value = payload.get("input")
            if isinstance(input_value, str):
                messages.append({"role": "user", "content": input_value})
            elif isinstance(input_value, list):
                for item in input_value:
                    if isinstance(item, str):
                        messages.append({"role": "user", "content": item})
                        continue
                    if not isinstance(item, dict):
                        continue
                    messages.extend(response_item_to_chat_messages(item))
            chat = {"model": payload["model"], "messages": messages or [{"role":"user","content":""}]}
            for key in ("stream", "temperature", "top_p", "stop", "tools", "tool_choice", "parallel_tool_calls", "presence_penalty", "frequency_penalty", "metadata"):
                if key in payload:
                    chat[key] = payload[key]
            if "max_output_tokens" in payload:
                chat["max_tokens"] = payload["max_output_tokens"]
            elif "max_completion_tokens" in payload:
                chat["max_tokens"] = payload["max_completion_tokens"]
            return chat

        def chat_to_responses_payload(model, payload):
            choice = (payload.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            output, text = chat_message_to_response_output(message if isinstance(message, dict) else {})
            normalized_usage = normalize_usage(payload.get("usage") or {})
            return {
                "id": payload.get("id") or f"resp_{uuid.uuid4().hex}",
                "object": "response",
                "created_at": int(datetime.datetime.now().timestamp()),
                "status": "completed",
                "model": model,
                "output": output,
                "output_text": text,
                "usage": {
                    "input_tokens": normalized_usage.get("prompt_tokens"),
                    "output_tokens": normalized_usage.get("completion_tokens"),
                    "total_tokens": normalized_usage.get("total_tokens"),
                },
            }

        def log_usage(config, provider, model, payload, request_payload=None, output_text=""):
            prompt_char_estimate = estimate_prompt_chars(request_payload)
            output_char_estimate = len(output_text) if isinstance(output_text, str) else 0
            normalized_usage = normalize_usage(
                payload.get("usage") or {},
                prompt_char_estimate=prompt_char_estimate,
                output_char_estimate=output_char_estimate
            )
            event = {
                "request_id": payload.get("id") or uuid.uuid4().hex,
                "provider": provider,
                "model": model,
                "prompt_tokens": normalized_usage.get("prompt_tokens", 0) or 0,
                "completion_tokens": normalized_usage.get("completion_tokens", 0) or 0,
                "cache_creation_tokens": normalized_usage.get("cache_creation_tokens", 0) or 0,
                "cache_read_tokens": normalized_usage.get("cache_read_tokens", 0) or 0,
                "reasoning_tokens": normalized_usage.get("reasoning_tokens", 0) or 0,
                "total_tokens": normalized_usage.get("total_tokens", 0) or 0,
                "input_char_estimate": prompt_char_estimate,
                "output_char_estimate": output_char_estimate,
                "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()
            }
            with open(config["usage_log"], "a", encoding="utf-8") as f:
                f.write(json.dumps(event) + "\\n")

        def _int_config(config, name, default):
            raw_value = config.get(name)
            if raw_value is None:
                return default
            try:
                return int(raw_value)
            except (TypeError, ValueError):
                return default

        CONFIG = load_config()
        SESSION_TOKEN = CONFIG.get("session_token", "")
        TUNNEL_ROTATION_TOKEN = CONFIG.get("tunnel_rotation_token", "")
        RATE_LIMIT_REQUESTS = _int_config(CONFIG, "rate_limit_requests", 100)
        RATE_LIMIT_WINDOW = _int_config(CONFIG, "rate_limit_window", 60)
        AUTH_FAIL_LIMIT = _int_config(CONFIG, "auth_fail_limit", 20)

        \(Self.proxyRateLimitHelpers())

        def _is_health_path(path):
            return path.split("?", 1)[0] in ("/health", "/healthz")

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                sys.stderr.write("[cursor_connector] " + (fmt % args) + "\\n")

            def send_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def check_auth(self):
                # Always allow health checks without auth (needed for startup verification).
                if _is_health_path(self.path):
                    return True

                # Enforce bearer token auth for all other endpoints.
                # Health checks are the only public endpoints.
                if TUNNEL_ROTATION_TOKEN:
                    auth = self.headers.get("Authorization", "")
                    if not _constant_time_ascii_equal(auth, f"Bearer {TUNNEL_ROTATION_TOKEN}"):
                        client_identity = _client_identity(self)
                        current = _auth_fail_record(client_identity)
                        if current > AUTH_FAIL_LIMIT:
                            _send_rate_limited(self, AUTH_FAIL_LIMIT)
                        else:
                            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": {"message": "unauthorized"}})
                        return False

                # Rate limiting on authenticated API requests only. Public
                # health probes must not consume the user-visible tunnel quota.
                client_ip = _client_identity(self)
                allowed, _current = _rate_limit_check(client_ip)
                if not allowed:
                    _send_rate_limited(self, RATE_LIMIT_REQUESTS)
                    return False

                return True

            def do_GET(self):
                if _is_health_path(self.path): self.send_json(HTTPStatus.OK, {"ok": True}); return
                if not self.check_auth():
                    return
                # Record request for rate limiting after successful auth.
                _rate_limit_record(_client_identity(self))
                config = load_config()
                if self.path.startswith("/v1/models"):
                    data = [{"id": mid, "object": "model", "created": 0, "owned_by": "openburnbar"} for mid in sorted(config["routes"].keys())]
                    self.send_json(HTTPStatus.OK, {"object": "list", "data": data})
                    return
                self.send_json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})

            def do_POST(self):
                if _is_health_path(self.path): self.send_json(HTTPStatus.OK, {"ok": True}); return
                if not self.check_auth():
                    return
                # Record request for rate limiting after successful auth.
                _rate_limit_record(_client_identity(self))
                config = load_config()
                is_chat = self.path.startswith("/v1/chat/completions")
                is_responses = self.path.startswith("/v1/responses")
                if not is_chat and not is_responses:
                    self.send_json(HTTPStatus.NOT_FOUND, {"error": {"message": "not found"}})
                    return
                length = int(self.headers.get("Content-Length", "0") or 0)
                body = self.rfile.read(length) if length > 0 else b"{}"
                payload = json.loads(body.decode("utf-8"))
                model = payload.get("model")
                route = config["routes"].get(model)
                if not route:
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": {"message": f"unknown model {model}"}})
                    return
                api_key = resolve_route_api_key(route)
                if not api_key:
                    self.send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": f"missing keychain credential for {route['provider']}"}})
                    return
                sys.stderr.write(f"[cursor_connector] route path={self.path} model={model} upstream={route['base_url']}\\n")
                outbound = payload if is_chat else responses_to_chat_payload(payload)
                outbound_body = json.dumps(outbound).encode("utf-8")
                req = Request(
                    route["base_url"].rstrip("/") + "/chat/completions",
                    data=outbound_body,
                    method="POST",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}
                )
                ctx = ssl.create_default_context()
                try:
                    with urlopen(req, timeout=600, context=ctx) as resp:
                        upstream_body = resp.read()
                        content_type = resp.headers.get("Content-Type", "application/json")
                        response_body = upstream_body
                        is_stream_request = bool(outbound.get("stream"))
                        did_log_usage = False
                        if "application/json" in content_type:
                            try:
                                response_json = json.loads(upstream_body.decode("utf-8"))
                                assistant_text = extract_chat_completion_text(response_json)
                                log_usage(
                                    config,
                                    route["provider"],
                                    model,
                                    response_json,
                                    request_payload=outbound,
                                    output_text=assistant_text
                                )
                                did_log_usage = True
                                if is_responses:
                                    response_body = json.dumps(chat_to_responses_payload(model, response_json)).encode("utf-8")
                                    content_type = "application/json"
                            except json.JSONDecodeError:
                                pass
                        if not did_log_usage and ("text/event-stream" in content_type or is_stream_request):
                            stream_meta = parse_stream_usage(upstream_body)
                            if stream_meta is not None:
                                log_usage(
                                    config,
                                    route["provider"],
                                    model,
                                    {"id": stream_meta.get("id"), "usage": stream_meta.get("usage") or {}},
                                    request_payload=outbound,
                                    output_text=stream_meta.get("output_text", "")
                                )
                        self.send_response(resp.getcode())
                        self.send_header("Content-Type", content_type)
                        self.send_header("Content-Length", str(len(response_body)))
                        self.end_headers()
                        self.wfile.write(response_body)
                except HTTPError as e:
                    err = e.read() if e.fp else b"{}"
                    self.send_response(e.code)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(err)))
                    self.end_headers()
                    self.wfile.write(err)
                except URLError as e:
                    self.send_json(HTTPStatus.BAD_GATEWAY, {"error": {"message": str(e.reason)}})

        if __name__ == "__main__":
            config = load_config()
            server = ThreadingHTTPServer(("127.0.0.1", int(config["port"])), Handler)
            sys.stderr.write(f"cursor_connector_proxy on http://127.0.0.1:{config['port']}/v1\\n")
            server.serve_forever()
        """
    }
}
