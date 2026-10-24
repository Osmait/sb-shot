# Contributing to sb-shot

Thanks for your interest in improving sb-shot. This guide explains how to set up the project, the conventions the code follows and how to get a pull request merged.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security issues should be reported privately as described in [SECURITY.md](SECURITY.md).

## Before you start

- For bugs, search the [existing issues](https://github.com/Osmait/sb-shot/issues) first, then open one with the bug report form.
- For new features or larger changes, open a feature request (or comment on an existing one) before writing code, so we can agree on the approach. Small fixes and documentation improvements can go straight to a pull request.

## Setup

Requirements:

- macOS 15.6 or later
- Xcode 26 or later
- Optional but recommended: [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and [SwiftLint](https://github.com/realm/SwiftLint)

```bash
brew install swiftformat swiftlint
git clone https://github.com/<your-user>/sb-shot.git
cd sb-shot
open sb-shot.xcodeproj
```

1. In the **SbShot** target, under **Signing & Capabilities**, select your own team. If needed, change the bundle identifier locally, but **do not commit** signing changes (team or bundle identifier) in your pull request.
2. Run the **SbShot** scheme on **My Mac**.
3. Grant the Screen Recording permission when asked. If the permission gets stuck after re-signing, reset it with `tccutil reset ScreenCapture <bundle id>`.

Read [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the layers and the main flows.

## Code style

- **Formatting:** run SwiftFormat with the repository configuration before committing:

  ```bash
  swiftformat sb-shot/ sb-shotTests/ sb-shotUITests/
  ```

- **Linting:** run `swiftlint lint` and don't introduce new warnings. If you must disable a rule, do it on the specific line (`// swiftlint:disable:next <rule>`) and explain why.
- **Language:** identifiers, comments, documentation, commit messages and PR descriptions are in English.
- **Comments:** explain *why*, not *what*. Document non-obvious decisions (sandbox limitations, coordinate systems, threading).
- **Layers:** keep the separation between `Domain`, `Infrastructure`, `Presentation` and `App`:
  - Domain code does not import SwiftUI views or talk to system services directly.
  - System services (ScreenCaptureKit, files, clipboard…) sit behind protocols so they can be replaced by fakes in tests.
  - New dependencies are created in `AppContainer` and injected; avoid new singletons.
- **Concurrency:** the targets default to `MainActor` isolation. Mark background work (`nonisolated`, `Task.detached`) explicitly and keep heavy work (encoding, rendering, export) off the main thread.
- **Rendering:** anything drawn on the editor canvas must go through `AnnotationRenderer`, so the canvas and the exported image stay identical. The same applies to video backgrounds and `VideoBackgroundCompositor`.
- **Own windows:** new floating windows must not appear in captures or recordings.
- **Dependencies:** the project has no third-party dependencies. Please discuss before adding one.

## Adding or changing strings

The UI is written in English and translated into Spanish through the String Catalog `sb-shot/Localizable.xcstrings`.

- In SwiftUI, string literals passed to `Text`, `Button`, `Toggle`, `Label`, `Section`, etc. are `LocalizedStringKey`s and are picked up automatically.
- For strings built in code (enum titles, toast messages, window titles, AppKit labels, alerts), use `String(localized: "…")`. Use interpolation instead of concatenation so translators see the full sentence, for example `String(localized: "Saved to \(folder)")`.
- Add a `comment:` when the context isn't obvious (for example, short words like "Open" or "Clear").
- Don't localize identifiers, `UserDefaults` keys, file extensions or log messages.
- After adding strings, build the app so Xcode adds them to the catalog, then open `Localizable.xcstrings` and add the **Spanish** translation. No entry should remain in the *New* or *Needs Review* state for Spanish.
- Check both languages: run the scheme with **App Language** set to Spanish (Product › Scheme › Edit Scheme › Run › Options) and make sure labels fit.

## Tests

Unit tests use [Swift Testing](https://developer.apple.com/documentation/testing) and live in `sb-shotTests` (target `SbShotTests`).

```bash
xcodebuild test \
  -project sb-shot.xcodeproj \
  -scheme SbShot \
  -destination 'platform=macOS' \
  -only-testing:SbShotTests \
  CODE_SIGNING_ALLOWED=NO
```

Expectations:

- Bug fixes should include a test that fails without the fix, when the code is testable.
- New logic in `Domain`, `Infrastructure` (rendering, geometry, files, history, video processing) and view models should come with tests. Use fakes for system services.
- Tests must not depend on the screen, permissions, network or the user's files. Use temporary directories and in-memory `UserDefaults` suites.
- Real captures and recordings belong in integration tests, which only run when `SBSHOT_INTEGRATION` is set:

  ```bash
  TEST_RUNNER_SBSHOT_INTEGRATION=1 xcodebuild test \
    -project sb-shot.xcodeproj -scheme SbShot -destination 'platform=macOS' \
    -only-testing:SbShotTests/RecordingIntegrationTests
  ```

  They need an unlocked screen and the Screen Recording permission. Run them locally when you touch capture or recording code.

CI runs the unit tests on every pull request.

## Pull request process

1. Fork the repository and create a branch from `main` (`fix/…`, `feature/…`, `docs/…`).
2. Keep the pull request focused on one change. Unrelated refactors make reviews slower.
3. Run SwiftFormat, SwiftLint and the unit tests locally.
4. Update the documentation (`README.md`, `ARCHITECTURE.md`) if you change behavior, shortcuts, settings or the architecture.
5. For UI changes, include screenshots or a short recording in the pull request description (in English and, if relevant, Spanish).
6. Fill in the pull request template and link the related issue (`Fixes #123`).
7. A maintainer will review it. Please address the feedback with new commits; they may be squashed when merging.

## Commit messages

- Write commit messages in English, in the imperative mood: "Fix window shadow on external displays", not "Fixed" or "Fixes".
- Keep the subject line short (about 72 characters or less) and add a body when the reason for the change isn't obvious.
- Reference issues in the body when relevant (`Fixes #123`).

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
