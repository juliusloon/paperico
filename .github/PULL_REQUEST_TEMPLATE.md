## Summary

<!-- What does this PR change and why? Link related issues with "Fixes #123". -->

## Changes

-
-

## How was this tested?

- [ ] Backend (local copy only): `pytest` (and `ruff check .`) from `backend/`
- [ ] macOS client: `./script/check.sh` (only if `macos/` changed)
- [ ] API schema changed → updated `backend/tests/openapi_snapshot.json` and ran `macos/scripts/check_api_contract.py` until `contract OK`

## Checklist

- [ ] `CHANGELOG.md` updated under **Unreleased** (user-visible changes)
- [ ] No secrets, `.env` files, databases or local paper content added
- [ ] `README.md` / `README.zh-CN.md` updated if behavior or setup changed
