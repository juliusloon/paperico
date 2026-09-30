# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | ✅ |

## Reporting a vulnerability

Please report security vulnerabilities privately via GitHub's
[report a vulnerability](https://github.com/juliusloon/paperico/security/advisories/new)
flow. Please **do not** open a public issue for anything you believe is a security
problem.

Include as much of the following as you can: a description of the issue, steps to
reproduce, affected version/commit, and any proof-of-concept. You can expect an initial
response within 7 days.

## Scope and design notes

Paperico is designed as a **single-user, local-first** application:

- The backend is intended to be reached from the operator's own machine or LAN. It ships
  with permissive CORS and **no authentication** by design — do not expose it directly to
  the public internet.
- API keys entered in the Settings page are encrypted at rest with Fernet; the key lives
  in the local storage directory (mode 0600) or `PAPERICO_ENCRYPTION_KEY`.
- Uploaded PDFs and extraction results stay under `PAPERICO_STORAGE_ROOT` on your machine;
  they are sent only to the MinerU / LLM endpoints you configure.

Reports about the "no authentication / trusted LAN" model are welcome when they describe
a way it can be bypassed or escalated (e.g. a path traversal, SSRF via server settings,
or credential disclosure), but please keep the intended deployment model in mind.
