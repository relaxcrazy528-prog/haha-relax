# Security

KeepOnline's shipping target does not execute shell commands, request administrator access, modify system power preferences, install background daemons, or control private lid APIs. Ordinary and optional disk assertions have a system-managed expiration and belong to this process.

The native power backend is called synchronously inside the session engine's actor isolation. Session identities are checked immediately before using native assertion IDs, which may be reused by the OS. Expired sessions never silently recreate assertions.

Unverified battery/lid support is deliberately unavailable. Research inventory scripts are read-only and are not part of the application. Reports must distinguish a successful request, an active assertion, and observed machine behavior.

Do not put passwords, serial numbers, full system logs, network addresses, or private project data in public issues. For a vulnerability, use GitHub private vulnerability reporting when enabled by the repository owner. No external reporting address has been configured yet.

Do not add CI signing secrets to pull-request workflows. Signing and notarization belong in a separately protected maintainer release process.
