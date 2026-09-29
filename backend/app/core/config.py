"""Application configuration with encrypted API key storage."""

from pathlib import Path
from pydantic_settings import BaseSettings
from pydantic import Field, field_validator

BACKEND_ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    # Storage
    storage_root: Path = Field(default=Path(__file__).parent.parent / "storage")
    database_url: str = f"sqlite+aiosqlite:///{BACKEND_ROOT / 'paperico.db'}"

    # Encryption key for API keys (Fernet symmetric)
    encryption_key: str = ""

    # MinerU defaults
    mineru_base_url: str = "https://mineru.net/api/v4"
    mineru_api_key: str = ""
    mineru_model_backend: str = "pipeline"  # pipeline | vlm

    # LLM defaults
    llm_base_url: str = "https://api.openai.com/v1"
    llm_api_key: str = ""
    llm_model: str = "gpt-4o-mini"

    # Job governance (T1.1/T1.3): the fallback switch restores the legacy
    # BackgroundTasks path; kind limits are JSON, e.g. PAPERICO_JOB_KIND_LIMITS='{"mineru": 4}'
    use_job_center: bool = True
    job_kind_limits: dict[str, int] = Field(default_factory=dict)
    trash_retention_days: int = 7

    # Chat context (T2.2): set true for one observation cycle to restore the
    # legacy hard [:3000]/[:2000] truncation if quality regresses.
    chat_legacy_truncation: bool = False

    @field_validator("storage_root")
    @classmethod
    def absolute_storage_root(cls, value: Path) -> Path:
        value = value.expanduser()
        return (value if value.is_absolute() else BACKEND_ROOT / value).resolve()

    model_config = {"env_prefix": "PAPERICO_", "env_file": str(BACKEND_ROOT / ".env")}


settings = Settings()


def ensure_dirs():
    """Create storage directories if they don't exist."""
    for sub in ("pdfs", "images", "mineru_output"):
        (settings.storage_root / sub).mkdir(parents=True, exist_ok=True)
