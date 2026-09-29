"""Fernet-based encryption for API keys.

The first version generated a new key every time the backend started when no
environment variable was configured.  That made every stored API key
undecryptable after a restart.  We now persist a machine-local key under the
application storage directory (mode 0600) and still allow an environment key
to override it.
"""

import os
from cryptography.fernet import Fernet, InvalidToken
from .config import settings

_fernet: Fernet | None = None


def _get_fernet() -> Fernet:
    global _fernet
    if _fernet is None:
        key = settings.encryption_key.strip()
        if not key:
            key_path = settings.storage_root / ".paperico.key"
            key_path.parent.mkdir(parents=True, exist_ok=True)
            if key_path.exists():
                key = key_path.read_text(encoding="utf-8").strip()
            else:
                key = Fernet.generate_key().decode()
                key_path.write_text(key, encoding="utf-8")
                try:
                    os.chmod(key_path, 0o600)
                except OSError:
                    pass
            settings.encryption_key = key
        _fernet = Fernet(key.encode() if isinstance(key, str) else key)
    return _fernet


def encrypt(plaintext: str) -> str:
    return _get_fernet().encrypt(plaintext.encode()).decode()


def decrypt(ciphertext: str) -> str:
    return _get_fernet().decrypt(ciphertext.encode()).decode()


def decrypt_or_empty(ciphertext: str) -> str:
    """Decrypt a stored secret, returning an empty value for legacy/bad data."""
    if not ciphertext:
        return ""
    try:
        return decrypt(ciphertext)
    except (InvalidToken, ValueError, TypeError):
        return ""


def mask_key(key: str) -> str:
    """Return masked version of API key for display."""
    if not key or len(key) < 8:
        return "****"
    return key[:4] + "****" + key[-4:]
