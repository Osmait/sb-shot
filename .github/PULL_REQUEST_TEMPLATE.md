## Summary

<!-- What does this change and why? Link the related issue, e.g. "Fixes #123". -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / performance
- [ ] Documentation
- [ ] Localization

## How it was tested

<!-- Steps you followed, macOS version, number of displays, etc. -->

- [ ] Unit tests pass (`xcodebuild test -project sb-shot.xcodeproj -scheme SbShot -destination 'platform=macOS' -only-testing:SbShotTests`)
- [ ] Integration tests pass locally, if capture or recording code changed (`TEST_RUNNER_SBSHOT_INTEGRATION=1`)
- [ ] Tested manually in the running app

## Screenshots / recordings

<!-- Required for UI changes. Remove personal information. -->

## Checklist

- [ ] Code is formatted with SwiftFormat and `swiftlint lint` adds no new warnings
- [ ] Comments, identifiers and commit messages are in English
- [ ] New user-facing strings use `LocalizedStringKey` / `String(localized:)` and have a Spanish translation in `Localizable.xcstrings`
- [ ] Layers are respected (Domain / Infrastructure / Presentation / App)
- [ ] Documentation updated (`README.md`, `ARCHITECTURE.md`) if behavior, shortcuts or settings changed
- [ ] No signing changes (team, bundle identifier) are included
