# Contributing

Use Swift 6 on macOS. Keep changes small and run `swift test` with complete Xcode, or the explicitly labeled portable core checker on a Command Line Tools-only host. The [CI workflow](docs/ci-build-and-test.yml) is provided as an inactive template and has not been run on GitHub for this delivery.

Power behavior must be supported by reproducible evidence. Do not replace a capability check with a successful command exit, copy undocumented dictionary fields into the public backend, add privileged helpers to compensate for shared state, or introduce an automatic global fallback.

Any new session source must preserve: one owner of native handles, serialized identity validation and native calls, a system expiration, no recreation after expiry, and no network or disk traffic used as a keep-alive trick. Inspection failure is unknown, not off.

Run real power tests only on an authorized physical test Mac, never on shared CI. Report hardware model / OS build without serial numbers or network identifiers. Do not deliberately overheat or drain a machine to validate policy.

Private lid research must stay outside `Sources/`; the default app cannot link or invoke it. A validated backend needs a separate design review documenting scope, privilege, ownership, cleanup, observation limits, conflict behavior, and exact tested systems. Forks should use independent identifiers for any future services or state stores.
