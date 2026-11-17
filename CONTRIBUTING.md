# Contributing to FlySight Explorer

Thanks for helping! Bug reports, feature ideas and pull requests are all welcome.

## Getting started

1. Fork the repo and create a branch from `main`.
2. Follow the build steps in the [README](README.md). Put your signing team and
   bundle ID in `Config/Local.xcconfig` — **do not** change `DEVELOPMENT_TEAM`,
   bundle IDs or signing settings in the Xcode project or `Config/Base.xcconfig`.
3. Make your change. Add or update tests in `FlySightExplorerTests/` when
   you touch parsing, analysis or other logic that can be tested without a device.
4. Run the tests (⌘U) before opening a PR.

## Pull requests

- Keep PRs focused: one fix or feature per PR.
- Give the PR a clear title, written for users — it ends up in the release
  notes (e.g. "Fix download stalling on large TRACK.CSV files").
- Describe what changed and how you tested it (simulator, which iPhone, which
  FlySight firmware). Screenshots help for UI changes.
- CI must pass. A maintainer will review; changes to `.github/`, `fastlane/`
  and `Config/` need a maintainer from CODEOWNERS.
- User-facing strings live in `Localization.swift`; please add both the
  Hungarian (`hu`) and English (`en`) text. Texts iOS shows for the app
  (permission prompts, app name) are in `FlySightExplorer/InfoPlist.xcstrings`.

## Reporting bugs

Open an issue with steps to reproduce, the app version, iOS version and, if
relevant, the FlySight firmware version. If a track fails to load, the in-app
diagnostic log output is very useful — please strip any locations you don't
want to share.

## License of contributions

By submitting a pull request you agree that your contribution is licensed under
the [Apache License 2.0](LICENSE), the same license as the project (see
section 5 of the license).
