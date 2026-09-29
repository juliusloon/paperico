"""OpenAI-compatible LLM client with streaming support."""

import json
from collections.abc import AsyncGenerator
import httpx
from ..core.config import settings
from ..core.crypto import decrypt_or_empty


class LLMServiceError(RuntimeError):
    """Safe, actionable error returned by an OpenAI-compatible service."""


class LLMClient:
    """Thin wrapper around OpenAI-compatible chat completions API."""

    def __init__(self, base_url: str = "", api_key: str = "", model: str = ""):
        self.base_url = self._normalize_base_url(base_url or settings.llm_base_url)
        self.api_key = (api_key or settings.llm_api_key).strip()
        self.model = (model or settings.llm_model).strip()

    @staticmethod
    def _normalize_base_url(base_url: str) -> str:
        """Accept either a provider base URL or a pasted completions endpoint."""
        normalized = base_url.strip().rstrip("/")
        suffix = "/chat/completions"
        if normalized.endswith(suffix):
            normalized = normalized[:-len(suffix)]
        return normalized.rstrip("/")

    @property
    def is_configured(self) -> bool:
        return bool(self.base_url and self.api_key and self.model)

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    @staticmethod
    def _error_from_response(resp: httpx.Response) -> LLMServiceError:
        message = ""
        try:
            payload = resp.json()
            error = payload.get("error", payload) if isinstance(payload, dict) else payload
            if isinstance(error, dict):
                message = str(error.get("message") or error.get("detail") or error.get("code") or "")
            elif error:
                message = str(error)
        except (ValueError, TypeError):
            message = resp.text.strip()
        message = " ".join(message.split())[:300]
        detail = f": {message}" if message else ""
        return LLMServiceError(f"模型服务返回 HTTP {resp.status_code}{detail}")

    @staticmethod
    def _is_temperature_rejection(resp: httpx.Response) -> bool:
        """Some models (e.g. Kimi K2 thinking) reject any explicit temperature value."""
        if resp.status_code != 400:
            return False
        try:
            payload = resp.json()
        except ValueError:
            return False
        if not isinstance(payload, dict):
            return False
        error = payload.get("error", payload)
        message = str(error.get("message", "")) if isinstance(error, dict) else str(error)
        return "temperature" in message.lower()

    async def _post(self, client: httpx.AsyncClient, payload: dict) -> httpx.Response:
        """POST chat completions; retry once without temperature if the model rejects it."""
        url = f"{self.base_url}/chat/completions"
        resp = await client.post(url, headers=self._headers(), json=payload)
        if "temperature" in payload and self._is_temperature_rejection(resp):
            payload = {k: v for k, v in payload.items() if k != "temperature"}
            resp = await client.post(url, headers=self._headers(), json=payload)
        return resp

    @classmethod
    def _content_from_response(cls, data: dict) -> str:
        try:
            message = data["choices"][0]["message"]
            content = message.get("content") or message.get("reasoning_content")
            if isinstance(content, list):
                content = "".join(
                    str(part.get("text", "")) if isinstance(part, dict) else str(part)
                    for part in content
                )
            if content is None:
                raise KeyError("content")
            return str(content)
        except (KeyError, IndexError, TypeError) as exc:
            raise LLMServiceError("模型服务响应中缺少 choices[0].message.content") from exc

    async def chat(
        self,
        messages: list[dict],
        temperature: float = 0.3,
        max_tokens: int = 4096,
        response_format: dict | None = None,
        reasoning_effort: str | None = None,
    ) -> str:
        """Single-shot chat completion. Returns assistant message content."""
        payload: dict = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        if response_format:
            payload["response_format"] = response_format
        if reasoning_effort and reasoning_effort != "off":
            payload["reasoning_effort"] = reasoning_effort

        async with httpx.AsyncClient(timeout=120) as client:
            resp = await self._post(client, payload)
            if not resp.is_success:
                raise self._error_from_response(resp)
            try:
                data = resp.json()
            except ValueError as exc:
                raise LLMServiceError("模型服务返回了非 JSON 响应") from exc
            return self._content_from_response(data)

    async def chat_stream(
        self,
        messages: list[dict],
        temperature: float = 0.3,
        max_tokens: int = 4096,
        reasoning_effort: str | None = None,
    ) -> AsyncGenerator[str, None]:
        """Streaming chat completion. Yields content deltas."""
        payload: dict = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": True,
        }
        if reasoning_effort and reasoning_effort != "off":
            payload["reasoning_effort"] = reasoning_effort

        async with httpx.AsyncClient(timeout=120) as client:
            for attempt in range(2):
                async with client.stream(
                    "POST",
                    f"{self.base_url}/chat/completions",
                    headers=self._headers(),
                    json=payload,
                ) as resp:
                    if not resp.is_success:
                        await resp.aread()
                        if attempt == 0 and "temperature" in payload and self._is_temperature_rejection(resp):
                            payload = {k: v for k, v in payload.items() if k != "temperature"}
                            continue
                        raise self._error_from_response(resp)
                    async for line in resp.aiter_lines():
                        if not line.startswith("data: "):
                            continue
                        data_str = line[6:]
                        if data_str.strip() == "[DONE]":
                            break
                        try:
                            chunk = json.loads(data_str)
                            delta = chunk["choices"][0].get("delta", {})
                            content = delta.get("content", "")
                            if content:
                                yield content
                        except (json.JSONDecodeError, KeyError, IndexError):
                            continue
                    return

    async def chat_vision(
        self,
        messages: list[dict],
        temperature: float = 0.3,
        max_tokens: int = 2048,
    ) -> str:
        """Chat with vision (multimodal) messages."""
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
        }
        async with httpx.AsyncClient(timeout=120) as client:
            resp = await self._post(client, payload)
            if not resp.is_success:
                raise self._error_from_response(resp)
            try:
                data = resp.json()
            except ValueError as exc:
                raise LLMServiceError("模型服务返回了非 JSON 响应") from exc
            return self._content_from_response(data)


def get_llm_client(profile_id: str = "", db_settings: dict | None = None) -> LLMClient:
    """Get an LLM client configured from a model profile."""
    if db_settings and profile_id:
        profiles = db_settings.get("model_profiles", [])
        for p in profiles:
            if p.get("id") == profile_id:
                api_key = decrypt_or_empty(p.get("api_key", ""))
                return LLMClient(
                    base_url=p.get("base_url", ""),
                    api_key=api_key,
                    model=p.get("model", ""),
                )
    return LLMClient()
