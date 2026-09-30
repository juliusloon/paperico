"""Single source of truth for paper status strings and structured error codes.

Implements agentero-lessons §2.3: clients (native app or web) may only make
decisions off these stable codes, never off error-message text. `error_message`
stays free-form for humans; `error_code` is the machine contract.
"""

from __future__ import annotations

import json
from enum import StrEnum

import httpx

from ..services.llm import LLMServiceError


class PaperStatus(StrEnum):
    UPLOADED = "uploaded"
    PARSING = "parsing"
    PARSED = "parsed"
    NORMALIZING = "normalizing"
    ANALYZING = "analyzing"
    REDUCING = "reducing"
    READY = "ready"
    ERROR = "error"


class ErrorCode(StrEnum):
    MINERU_NOT_CONFIGURED = "MINERU_NOT_CONFIGURED"
    MINERU_TIMEOUT = "MINERU_TIMEOUT"
    MINERU_SUBMIT_FAILED = "MINERU_SUBMIT_FAILED"
    MINERU_PARSE_FAILED = "MINERU_PARSE_FAILED"
    LLM_NOT_CONFIGURED = "LLM_NOT_CONFIGURED"
    # Reserved for the truncation detector the map stage may surface once
    # raw sidecars (T2.1) make partial outputs visible; not yet written.
    LLM_TRUNCATED = "LLM_TRUNCATED"
    LLM_CALL_FAILED = "LLM_CALL_FAILED"
    JSON_PARSE_FAILED = "JSON_PARSE_FAILED"
    PDF_MISSING = "PDF_MISSING"
    PARSE_EMPTY = "PARSE_EMPTY"
    INTERRUPTED_BY_RESTART = "INTERRUPTED_BY_RESTART"
    INTERNAL = "INTERNAL"


class PipelineError(RuntimeError):
    """A pipeline failure carrying its stable ErrorCode for the API layer."""

    def __init__(self, message: str, code: ErrorCode = ErrorCode.INTERNAL):
        super().__init__(message)
        self.error_code = code


def error_code_of(exc: BaseException) -> ErrorCode:
    """Classify an exception into the stable ErrorCode contract.

    Typed exceptions (PipelineError, MinerU service errors) win; everything
    else is classified by type — never by message text.
    """
    code = getattr(exc, "error_code", None)
    if isinstance(code, ErrorCode):
        return code
    if isinstance(exc, json.JSONDecodeError):
        return ErrorCode.JSON_PARSE_FAILED
    if isinstance(exc, LLMServiceError):
        return ErrorCode.LLM_CALL_FAILED
    if isinstance(exc, (TimeoutError, httpx.TimeoutException)):
        return ErrorCode.MINERU_TIMEOUT
    return ErrorCode.INTERNAL


def set_paper_error(paper, exc: BaseException, *, message_limit: int = 500) -> None:
    """Write status/error_message/error_code onto a Paper row in one place.

    `paper` is duck-typed (any object with the three attributes) so this stays
    import-light for services and api layers alike.
    """
    paper.status = PaperStatus.ERROR
    paper.error_message = str(exc)[:message_limit]
    paper.error_code = error_code_of(exc).value
