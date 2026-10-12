"""MCP server tests: fake HTTP transport, no database and no network."""

import asyncio

import httpx
import pytest

from solo_decisions import mcp_server as mod
from solo_decisions.mcp_server import build_server

API_KEY = "EMPIRE_DECISIONS_API"
READS = {"decisions.decision.list", "decisions.decision.get", "decisions.decision.stats",
         "decisions.decision.events", "decisions.event.list", "decisions.review.list", "decisions.review.get"}
WRITES = {"decisions.decision.create", "decisions.decision.note", "decisions.review.update"}
ARGS = {"decisions.decision.get": {"id": 1}, "decisions.decision.events": {"id": 1}, "decisions.review.get": {"id": 2},
        "decisions.decision.create": {"title": "t", "decision": "d"},
        "decisions.decision.note": {"id": 1, "event_type": "reviewed"},
        "decisions.review.update": {"id": 2, "status": "completed"}}
SAMPLES = [
    ("decisions.decision.list", {"status": ["proposed"], "domain": "money", "limit": 5}, "GET", "/v1/decisions",
     {"status": "proposed", "domain": "money", "limit": "5", "offset": "0"}),
    ("decisions.decision.events", {"id": 7, "order": "asc", "after_id": 3}, "GET", "/v1/decisions/7/events",
     {"order": "asc", "after_id": "3", "limit": "100"}),
    ("decisions.review.list", {"decision_id": 7}, "GET", "/v1/decision-reviews", {"decision_id": "7", "limit": "100"}),
    ("decisions.decision.note", {"id": 7, "event_type": "reviewed", "reason": "ok"}, "POST", "/v1/decisions/7/events", {}),
    ("decisions.review.update", {"id": 4, "status": "completed", "expected_version": 2}, "PATCH", "/v1/decision-reviews/4", {}),
]


def test_note_cannot_change_state_and_create_cannot_approve():
    srv = server(Fake())
    with pytest.raises(Exception, match="invalid_arguments: event_type"):
        call(srv, "decisions.decision.note", {"id": 1, "event_type": "approved"})
    for field in ("approval_status", "status", "action_status", "approval_required"):
        with pytest.raises(Exception, match=f"invalid_arguments: {field}"):
            call(srv, "decisions.decision.create", {"title": "t", "decision": "d", field: "approved"})


def test_create_sends_an_idempotency_key_and_only_the_given_fields():
    fake = Fake(status=201, body={"id": 1})
    call(server(fake), "decisions.decision.create", {"title": "t", "decision": "d", "confidence": 0.5})
    request = fake.requests[0]
    assert request.headers["idempotency-key"].startswith("mcp-")
    assert request.content == b'{"title":"t","decision":"d","confidence":0.5}'


IDENTITY = {"actor": "x", "workspace_id": "w", "workspace": "w", "tenant_id": "t", "delegation": "d", "token": "t",
            "authorization": "Bearer x", "sub": "s"}


class Fake:
    """A fake HTTP transport: records every request and answers with ``body``."""

    def __init__(self, status: int = 200, body: object | None = None) -> None:
        self.requests: list[httpx.Request] = []
        self.status, self.body = status, {"items": []} if body is None else body

    def client(self) -> httpx.Client:
        def handle(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            return httpx.Response(self.status, json=self.body)
        return httpx.Client(transport=httpx.MockTransport(handle), base_url="https://api.test")


def server(fake: Fake, read_only: bool = False):
    return build_server(fake.client(), lambda: "tok-123", read_only=read_only).server


def call(srv, name: str, args: dict | None = None):
    return asyncio.run(srv.call_tool(name, args or {}))


def names(srv) -> set[str]:
    return {tool.name for tool in asyncio.run(srv.list_tools())}


def test_tools_list_matches_the_contract():
    srv = server(Fake())
    assert names(srv) == READS | WRITES
    for tool in asyncio.run(srv.list_tools()):
        assert tool.input_schema["additionalProperties"] is False


def test_read_only_registers_only_read_tools():
    assert names(server(Fake(), read_only=True)) == READS


def test_unknown_arguments_are_rejected_before_any_http_call():
    fake = Fake()
    srv = server(fake)
    for name in sorted(READS | WRITES):
        with pytest.raises(Exception, match="invalid_arguments: surprise"):
            call(srv, name, {**ARGS.get(name, {}), "surprise": 1})
    assert fake.requests == []


def test_identity_arguments_are_never_accepted():
    fake = Fake()
    srv = server(fake)
    for name in sorted(READS | WRITES):
        for key, value in IDENTITY.items():
            with pytest.raises(Exception, match="invalid_arguments"):
                call(srv, name, {**ARGS.get(name, {}), key: value})
    assert fake.requests == []
    for name in READS | WRITES:
        tool = next(t for t in asyncio.run(srv.list_tools()) if t.name == name)
        assert not set(IDENTITY) & set(tool.input_schema["properties"])


def test_every_call_carries_the_callers_bearer_and_nothing_else_of_identity():
    fake = Fake()
    srv = server(fake)
    for name in sorted(READS | WRITES):
        call(srv, name, ARGS.get(name, {}))
    assert len(fake.requests) == len(READS | WRITES)
    for request in fake.requests:
        assert request.headers["authorization"] == "Bearer tok-123"
        assert "tok-123" not in str(request.url)
        assert request.url.host == "api.test"


def test_sample_calls_map_to_the_api():
    for name, args, method, path, params in SAMPLES:
        fake = Fake()
        call(server(fake), name, args)
        request = fake.requests[-1]
        assert (request.method, request.url.path) == (method, path), name
        assert dict(request.url.params) == params, name


def test_errors_carry_only_the_status_and_a_short_code():
    fake = Fake(status=403, body={"detail": {"error": "forbidden", "secret": "tok-123 do-not-leak"}})
    with pytest.raises(Exception) as caught:
        call(server(fake), sorted(READS)[0], ARGS.get(sorted(READS)[0], {}))
    assert str(caught.value).endswith("403: forbidden") and "do-not-leak" not in str(caught.value)


def test_transport_failure_does_not_echo_the_error():
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("Authorization: Bearer tok-123 refused")
    srv = build_server(httpx.Client(transport=httpx.MockTransport(boom), base_url="https://api.test"),
                       lambda: "tok-123").server
    with pytest.raises(Exception) as caught:
        call(srv, sorted(READS)[0], ARGS.get(sorted(READS)[0], {}))
    assert "tok-123" not in str(caught.value) and "503" in str(caught.value)


def test_url_must_be_https_or_loopback(tmp_path):
    assert mod.api_url(API_KEY, {API_KEY: "https://x.example"}) == "https://x.example"
    assert mod.api_url(API_KEY, {API_KEY: "http://127.0.0.1:9"}) == "http://127.0.0.1:9"
    with pytest.raises(mod.ConfigError):
        mod.api_url(API_KEY, {API_KEY: "http://example.com"})
    with pytest.raises(mod.ConfigError):
        mod.api_url(API_KEY, {"EMPIRE_CLIENT_CONFIG": str(tmp_path / "none")})


def test_token_order_and_file_mode(tmp_path):
    token_file = tmp_path / "t.jwt"
    token_file.write_text("from-file\n")
    token_file.chmod(0o644)
    with pytest.raises(mod.ConfigError):
        mod.bearer({"EMPIRE_TOKEN_FILE": str(token_file)})
    token_file.chmod(0o600)
    assert mod.bearer({"EMPIRE_TOKEN_FILE": str(token_file)}) == "from-file"
    assert mod.bearer({"EMPIRE_TOKEN": "env", "EMPIRE_TOKEN_FILE": str(token_file)}) == "env"
    assert mod.bearer({"EMPIRE_MCP_AUTOMATION": "x-y", "EMPIRE_AUTOMATION_TOKEN_X_Y": "auto"}) == "auto"
