# Verification record — architecture 3.0 implementation preview

Core verification date: 2026-10-26; panel correction: 2026-10-27. Host reports macOS 26.4 (25E246). Delivered application: arm64, version 2.0.1, build 31; macOS 14 deployment target. Minimum deployment target is not a claim of tested support on every older OS or on Intel.

## 2.0.1 panel correction

- The previous content had a fixed width and an unconstrained height, so the popover could exceed the usable screen area. The panel now has a bounded viewport and a vertical scroll view; expanding content does not grow the outer window.
- Sizing uses the anchor window's screen, its current `visibleFrame`, and AppKit points. It reserves space for the popover chrome and Dock, and updates an open panel when screen geometry changes.
- `scripts/check-panel-layout.py` passed four geometry cases, including offset display coordinates, plus native popovers at 382×560, 382×360, and 320×440 points. Default and live expanded options/help states stayed inside the usable screen, the expanded content scrolled from top to bottom, and reducing the open viewport to 300 points kept it inside the screen. Results: [PanelLayoutResults.json](PanelLayoutResults.json).
- The desktop fixture uses a dedicated top-edge anchor and the production view/sizing code. It does not certify every physical display or replace a complete mouse/keyboard/VoiceOver test. The external UI automation service was unavailable during this correction.
- Version 2.0.1 production build, bundle validation and signature verification passed. Its actual application smoke check passed startup, active indicator, release, idle indicator, and graceful process exit after the UI change.

## Passed locally

- Swift 6.3.3 production compilation, `.app` packaging, property-list validation, local ad-hoc Hardened Runtime signature verification.
- **18 core scenarios, 0 failures**, using `scripts/check-core-portable.py`. The script reuses the source scenarios with a small, explicitly labeled portable assertion adapter. Results: [PortableCoreResults.txt](PortableCoreResults.txt).
- **5 read-only inventory privacy tests**. Raw I/O registry output, identifiers, user paths, network addresses, and command errors do not enter exported inventory. Restricted fields remain unknown.
- Real public IOPM assertions for **ordinary system idle and disk idle**. Observed system-managed expiration while the owner was suspended, failed late renewal without recreation, and idempotent cleanup after expiration.
- A separate forced-process-exit check confirmed the test process's assertions disappeared. Results: [NativeLeaseResults.json](NativeLeaseResults.json).
- Actual application startup, model-driven ordinary-session start, red active indicator state, release, gray idle indicator state, and full graceful process exit. The app smoke check runs the actual application model and native backend, not a preview mock.
- Light, dark, and inactive panel rendering; the preview fixture never creates power assertions or a real session.
- Shipping source scan found no `do shell script`, `disablesleep`, private `IOConnectCall` calls, or `sudo` invocation. `.app` contains no helper daemon or test executable.
- Read-only final check reported `SleepDisabled = No`. The implementation and tests do not write this setting.

## Problems found and corrected during checks

- Replaced a binding function-reference conversion that triggered a compiler issue with an explicit setter closure.
- Used a self-rendered primary button to avoid missing native button layers in offscreen rendering.
- Changed application-driven quit to release resources before initiating AppKit termination. Initiating AppKit's deferred termination inside an active async main-actor task caused an exit wait; the final smoke test confirms full exit after the fix.
- Resolved cleanup diagnostics are cleared after confirmed retry, while unresolved resources remain visible and block a new session.

## Not verified / unavailable

- Standard **XCTest was not run**: this host has Command Line Tools and no XCTest module. The canonical `swift test` suite is supplied for complete Xcode and CI; portable results are not represented as XCTest results.
- No downloadable GitHub release has been published. The CI workflow is retained as an inactive template in `docs/ci-build-and-test.yml`; GitHub Actions has not been enabled or run.
- No Developer ID signing or Apple notarization. The delivered archive is a local, ad-hoc signed preview.
- Battery-powered, no-external-display closed-lid operation remains **not validated and unavailable**. Ordinary mode still allows lid-close sleep. No fallback writes a global sleep setting.
- No physical lid-close, low-battery shutdown, thermal-emergency, long-running SSH/VPN, manual OS shutdown, login-item approval, or multi-OS/Intel compatibility certification. Policy transitions are covered with controlled core inputs instead of intentionally creating unsafe conditions.
- UI automation service timed out; manual mouse/keyboard interaction and VoiceOver have not been fully tested. Programmatic app smoke and rendered UI checks passed.
- Idle energy / memory measurements with Instruments remain to be collected. No zero-energy claim is made.

These results establish the implemented standard core and the honest capability boundary; they do not establish that the complete original closed-lid requirement has been achieved.
