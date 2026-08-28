# Repository Guidelines

## Project Structure & Module Organization

MacVital is a macOS 14+ SwiftUI/AppKit application generated with XcodeGen. Shared, safety-critical logic lives in `Sources/MacVitalKit/`; keep it independent of SwiftUI so both the app and privileged helper can use it. The UI and app services are under `Sources/MacVital/`, while `Sources/MacVitalHelper/` contains the root helper. Unit tests are in `Tests/MacVitalKitTests/`. Signing configuration lives in `Config/`, launchd resources in `Resources/`, and reproducible utilities in `Tools/`. Read `docs/SAFETY.md` before changing cleanup behavior and `docs/SIGNING.md` before changing entitlements, identities, or XPC setup.

## Build, Test, and Development Commands

- `make project` regenerates `MacVital.xcodeproj` from `project.yml`; do not hand-edit the generated project.
- `make test` runs the unsigned `MacVitalKitTests` XCTest scheme in isolated `build-test/` derived data.
- `make build` creates an ad-hoc-signed Release build; use `CONFIG=Debug` when needed.
- `make run` builds and launches the app. The privileged helper is unavailable in ad-hoc builds.
- `make build-signed` builds with the configured Developer ID; `make verify-signing` validates an app bundle.
- `make icon` regenerates asset-catalog PNGs from `Tools/MakeAppIcon.swift`.

Install Xcode 15+ and XcodeGen (`brew install xcodegen`) first.

## Coding Style & Naming Conventions

Use four-space indentation and standard Swift API naming: types and protocols in `UpperCamelCase`, properties/functions in `lowerCamelCase`, and descriptive enum cases. Match the existing file-per-primary-type organization and use `// MARK: - Section` in longer files. Prefer small, testable logic in `MacVitalKit`; keep UI styling in the app target. No automatic formatter or linter is configured, so follow nearby code and keep compiler warnings clean.

## Testing Guidelines

Tests use XCTest. Name files and classes `FeatureTests.swift`/`FeatureTests`, with methods beginning `test`, such as `testSymlinkIsRefusedRatherThanFollowed`. Add regression tests for every cleanup rule, protected-path change, attribution change, privilege route, or quarantine behavior. Tests must use temporary fixtures and must never operate on real user data. Run `make test` before submitting.

## Safety, Commits & Pull Requests

Cleanup is allowlist-driven, default-deny, revalidated before quarantine, and AI output must never grant deletion permission. Preserve these invariants and document intentional exceptions.

Recent commits use concise Chinese, outcome-focused subjects without prefixes (for example, `特权助手调用加超时：连上了却不回话同样是挂起`). Keep each commit focused. Pull requests should explain behavior and safety impact, list tests run, link relevant issues, and include screenshots or recordings for UI changes. Call out signing/helper limitations and any unverified Developer ID behavior.
