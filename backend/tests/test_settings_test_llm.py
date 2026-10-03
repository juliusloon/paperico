"""Tests for /api/settings/test-llm: connectivity probe + capability detection.

The probe helpers open their own httpx clients, so the network-level tests run
against a scriptable localhost stub instead of mocking httpx internals.
"""

import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import patch

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.api import settings_api
from app.api.settings_api import _probe_chat_capability, _probe_model_output_limit
from app.core import crypto
from app.core.database import get_db

OK_PAYLOAD = {"choices": [{"message": {"content": "OK"}}]}
REASONING_REJECT = {"error": {"message": "Unrecognized request argument supplied: reasoning_effort"}}
MAX_TOKENS_REJECT = {
    "error": {"message": "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}
}
AUTH_REJECT = {"error": {"message": "Incorrect API key provided"}}


class _StubHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _respond(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.endswith("/models"):
            status, payload = self.server.models
            self._respond(status, payload)
        else:
            self._respond(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        self.server.requests.append(body)
        required_token_field = self.server.required_token_fields.get(body.get("model"))
        if required_token_field and (
            required_token_field not in body or "max_tokens" in body
        ):
            self._respond(400, MAX_TOKENS_REJECT)
            return
        queue = self.server.post_responses
        status, payload = queue.pop(0) if queue else queue[-1]
        self._respond(status, payload)


class StubServer:
    """Threading HTTP server whose responses each test scripts upfront."""

    def __enter__(self):
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), _StubHandler)
        self._server.post_responses = []
        self._server.requests = []
        self._server.required_token_fields = {}
        self._server.models = (200, {"data": []})
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *exc):
        self._server.shutdown()
        self._server.server_close()
        return False

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self._server.server_port}/v1"

    @property
    def requests(self):
        return self._server.requests

    def respond_post(self, *items):
        self._server.post_responses = list(items)

    def require_token_field(self, model, field):
        self._server.required_token_fields[model] = field

    def respond_models(self, status, payload):
        self._server.models = (status, payload)


class ProbeChatCapabilityTests(unittest.IsolatedAsyncioTestCase):
    async def test_supported_reasoning(self):
        with StubServer() as stub:
            stub.respond_post((200, OK_PAYLOAD), (200, OK_PAYLOAD))
            success, supports, error = await _probe_chat_capability(stub.base_url, "sk-x", "m1")
            self.assertTrue(success)
            self.assertTrue(supports)
            self.assertEqual(error, "")
            self.assertNotIn("reasoning_effort", stub.requests[0])
            self.assertEqual(stub.requests[1]["reasoning_effort"], "low")

    async def test_unsupported_reasoning_is_not_a_failure(self):
        with StubServer() as stub:
            stub.respond_post((200, OK_PAYLOAD), (400, REASONING_REJECT))
            success, supports, error = await _probe_chat_capability(stub.base_url, "sk-x", "m1")
            self.assertTrue(success)
            self.assertFalse(supports)
            self.assertEqual(error, "")

    async def test_auth_failure_surfaces_provider_message(self):
        with StubServer() as stub:
            stub.respond_post((401, AUTH_REJECT))
            success, _, error = await _probe_chat_capability(stub.base_url, "sk-bad", "m1")
            self.assertFalse(success)
            self.assertIn("HTTP 401", error)
            self.assertIn("Incorrect API key", error)

    async def test_retries_with_max_completion_tokens(self):
        with StubServer() as stub:
            stub.require_token_field("o-model", "max_completion_tokens")
            stub.respond_post((200, OK_PAYLOAD), (200, OK_PAYLOAD))
            success, supports, _ = await _probe_chat_capability(stub.base_url, "sk-x", "o-model")
            self.assertTrue(success)
            self.assertTrue(supports)
            retry = stub.requests[1]
            self.assertNotIn("max_tokens", retry)
            self.assertEqual(retry["max_completion_tokens"], 128)
            reasoning = stub.requests[2]
            self.assertNotIn("max_tokens", reasoning)
            self.assertEqual(reasoning["max_completion_tokens"], 128)
            self.assertEqual(reasoning["reasoning_effort"], "low")


class ProbeModelOutputLimitTests(unittest.IsolatedAsyncioTestCase):
    async def test_reads_nested_openrouter_style_limit(self):
        with StubServer() as stub:
            stub.respond_models(200, {"data": [
                {"id": "other"},
                {"id": "m1", "top_provider": {"max_completion_tokens": 16384}},
            ]})
            limit = await _probe_model_output_limit(stub.base_url, "sk-x", "m1")
            self.assertEqual(limit, 16384)

    async def test_reads_flat_limit_and_ignores_unknown_models(self):
        with StubServer() as stub:
            stub.respond_models(200, {"data": [{"id": "m1", "max_output_tokens": 4096}]})
            self.assertEqual(await _probe_model_output_limit(stub.base_url, "sk-x", "m1"), 4096)
            self.assertIsNone(await _probe_model_output_limit(stub.base_url, "sk-x", "missing"))

    async def test_unreachable_or_unlisted_metadata_returns_none(self):
        with StubServer() as stub:
            stub.respond_models(404, {"error": {"message": "nope"}})
            self.assertIsNone(await _probe_model_output_limit(stub.base_url, "sk-x", "m1"))
        # Server gone entirely must not raise.
        self.assertIsNone(await _probe_model_output_limit("http://127.0.0.1:9/v1", "sk-x", "m1"))


class TestLlmEndpointTests(unittest.TestCase):
    def setUp(self):
        self.app = FastAPI()
        self.app.include_router(settings_api.router, prefix="/api/settings")

    def _client(self, row=None):
        class FakeDB:
            async def get(self, model, key):
                return row

        self.app.dependency_overrides[get_db] = lambda: FakeDB()
        return TestClient(self.app)

    def test_validates_required_fields_before_touching_db(self):
        # Empty profiles row: validation must short-circuit before any DB write.
        empty_row = SimpleNamespace(data={"model_profiles": []})
        with self._client(row=empty_row) as client:
            cases = [
                ({"base_url": "", "api_key": "k", "model": "m"}, "Base URL"),
                ({"base_url": "http://x/v1", "api_key": "k", "model": ""}, "模型名称"),
                ({"base_url": "http://x/v1", "api_key": "", "model": "m"}, "API Key"),
            ]
            for body, fragment in cases:
                result = client.post("/api/settings/test-llm", json=body).json()
                self.assertFalse(result["success"])
                self.assertIn(fragment, result["message"])

    def test_success_returns_capability_fields(self):
        captured = {}

        async def fake_probe(base_url, api_key, model):
            captured.update(base_url=base_url, api_key=api_key, model=model)
            return True, True, ""

        async def fake_limit(base_url, api_key, model):
            return 16384

        with self._client() as client:
            with patch.object(settings_api, "_probe_chat_capability", fake_probe), \
                 patch.object(settings_api, "_probe_model_output_limit", fake_limit):
                result = client.post("/api/settings/test-llm", json={
                    "base_url": "http://x/v1/", "api_key": "sk-live", "model": "m1",
                }).json()
        self.assertTrue(result["success"])
        self.assertTrue(result["supports_reasoning"])
        self.assertEqual(result["reasoning_levels"], ["off", "low", "medium", "high"])
        self.assertEqual(result["default_max_output_tokens"], 16384)
        self.assertIn("16384", result["message"])
        self.assertEqual(captured, {"base_url": "http://x/v1", "api_key": "sk-live", "model": "m1"})

    def test_unsupported_reasoning_forces_off(self):
        async def fake_probe(base_url, api_key, model):
            return True, False, ""

        async def fake_limit(base_url, api_key, model):
            return None

        with self._client() as client:
            with patch.object(settings_api, "_probe_chat_capability", fake_probe), \
                 patch.object(settings_api, "_probe_model_output_limit", fake_limit):
                result = client.post("/api/settings/test-llm", json={
                    "base_url": "http://x/v1", "api_key": "sk-live", "model": "m1",
                }).json()
        self.assertTrue(result["success"])
        self.assertFalse(result["supports_reasoning"])
        self.assertEqual(result["reasoning_levels"], ["off"])
        self.assertIsNone(result["default_max_output_tokens"])

    def test_empty_key_falls_back_to_saved_profile_key(self):
        captured = {}

        async def fake_probe(base_url, api_key, model):
            captured["api_key"] = api_key
            return True, True, ""

        row = SimpleNamespace(data={"model_profiles": [
            {"id": "primary", "name": "p", "base_url": "http://x/v1", "api_key": crypto.encrypt("sk-saved"), "model": "m1"},
        ]})
        with self._client(row=row) as client:
            async def fake_limit(base_url, api_key, model):
                return None

            with patch.object(settings_api, "_probe_chat_capability", fake_probe), \
                 patch.object(settings_api, "_probe_model_output_limit", fake_limit):
                result = client.post("/api/settings/test-llm", json={
                    "base_url": "http://x/v1", "api_key": "", "model": "m1", "profile_id": "primary",
                }).json()
        self.assertTrue(result["success"])
        self.assertEqual(captured["api_key"], "sk-saved")


if __name__ == "__main__":
    unittest.main()
