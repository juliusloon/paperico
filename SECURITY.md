# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.2.x native app | ✅ |
| 0.1.x compatibility API | ✅ |

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
- Native app credentials are stored in macOS Keychain; non-secret settings use UserDefaults.
  The separate compatibility API encrypts its credentials with Fernet, using a local
  key (mode 0600) or `PAPERICO_ENCRYPTION_KEY`.
- The native app stores PDFs and results in its sandboxed Application Support directory.
  The API uses `PAPERICO_STORAGE_ROOT`. Cloud parsing sends PDFs to MinerU; model requests
  send the relevant text/context to the model endpoints you configure.
- Native ZIP extraction validates paths, existing symlinks, sizes and CRC32. Library
  corruption and unsupported schema versions are surfaced without replacing source files.

Reports about the "no authentication / trusted LAN" model are welcome when they describe
a way it can be bypassed or escalated (e.g. a path traversal, SSRF via server settings,
or credential disclosure), but please keep the intended deployment model in mind.
