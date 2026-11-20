# Releasing (maintainers)

Official builds are signed with 360world's Apple Developer account
(team `94J6N6TEVZ`, bundle ID `com.world360.flysightexplorer`).

## How a release works

1. Make sure `main` is green.
2. Tag the commit and push the tag:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```
3. The **Release** workflow starts and waits for approval of the `app-store`
   environment. Approve it in the Actions tab.
4. fastlane fetches the signing certificate/profile from the encrypted match
   repo, builds with `MARKETING_VERSION=1.2.0` and the next free build number,
   and uploads to TestFlight. The TestFlight "What to Test" text lists the
   commits since the previous `v*` tag (dependency bumps left out).
5. After a successful upload, a **GitHub Release** `v1.2.0` is created with
   notes generated from the PRs merged since the previous release, grouped by
   label (see `.github/release.yml`). You can edit the notes on GitHub
   afterwards.
6. In App Store Connect, test the build in TestFlight, then submit it for review.

### Labels drive the release notes

Before merging a PR, give it one label: `enhancement` (🚀 New features),
`bug` (🐛 Bug fixes) or `documentation` (📖 Documentation). Anything else goes
under 🧰 Other changes. Use `skip-changelog` to leave a PR out entirely.
Dependabot PRs are always left out. PR titles become the release-note lines,
so make them readable.

## Where the secrets live

All of these are **environment secrets** in the `app-store` environment
(Settings → Environments → app-store). None are repository secrets.

| Secret | What it is |
|---|---|
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_P8_BASE64` | The `.p8` API key file, base64-encoded |
| `MATCH_GIT_URL` | SSH URL of the private signing repo |
| `MATCH_PASSWORD` | Passphrase that encrypts the signing repo |
| `MATCH_GIT_PRIVATE_KEY` | Private half of the read-only deploy key on the signing repo |

## Renewing / recreating signing assets

Distribution certificates expire after a year. On a maintainer Mac with the
same environment variables exported (except `MATCH_GIT_PRIVATE_KEY`):

```bash
bundle install
bundle exec fastlane setup_signing
```

## App Store screenshots

A Debug build reads a few launch arguments (`ScreenshotMode` in
`FlySightExplorer/ContentView.swift`; not compiled into Release builds):

| Argument | Effect |
|---|---|
| `-screenshotTab 0…4` | open a tab (0 HUD, 1 Analysis, 2 Logbook, 3 Settings, 4 Device) |
| `-screenshotSecondsAfterExit N` | put the playback cursor N seconds after exit |
| `-screenshotHideStatusBar YES` | hide the status bar |
| `-app_language en` / `hu`, `-hud_layout dial` … | override stored settings |

Use an iPhone 17 Pro Max (6.9", 1320 × 2868) and an iPad Pro 13-inch
(2064 × 2752) simulator, install a Debug build, then for each shot:

```bash
xcrun simctl launch <udid> com.world360.flysightexplorer \
  -AppleLanguages "(en)" -app_language en -screenshotHideStatusBar YES \
  -screenshotTab 0 -screenshotSecondsAfterExit 70 -hud_layout glideFirst
xcrun simctl io <udid> screenshot 1-hud-glide.png
```

The 1.0 set used: HUD Glide at 70 s, Analysis at 70 s, HUD Dial at 110 s,
Settings, Logbook — all with the built-in wingsuit sample.

Save the results into `fastlane/screenshots/<locale>/` (`en-US`, `hu`) with a
device prefix, e.g. `iphone69-1-hud-glide.png`, `ipad13-1-hud-glide.png`.
App Store Connect sorts them by file name and picks the device slot from the
image size.

## App Store listing (texts and screenshots)

The listing lives in the repo and is uploaded by its own workflow,
**Update App Store listing** (`.github/workflows/store-listing.yml`):

```
fastlane/metadata/<locale>/description.txt     App Store description
fastlane/metadata/<locale>/release_notes.txt   What's New (skipped automatically
                                               until the first version is live)
fastlane/metadata/<locale>/privacy_url.txt     privacy policy URL
fastlane/metadata/<locale>/support_url.txt     support URL
fastlane/screenshots/<locale>/*.png            screenshots, iPhone 6.9" + iPad 13"
```

`<locale>` is `en-US` or `hu`. Fields without a file (keywords, subtitle,
promotional text, …) are left as they are in App Store Connect.

To update the listing:

1. Change the files in a PR and merge it. Update `release_notes.txt` for
   every new version.
2. Actions → **Update App Store listing** → **Run workflow**, and enter the
   version (e.g. `1.0.1`, same as the tag without `v`).
3. Approve the `app-store` deployment.

The workflow first checks that the privacy policy and support URLs load, then
creates or updates that version in App Store Connect with the texts and
screenshots. It replaces all screenshots for each language. It never uploads
a build and never submits for review; you still do that in App Store Connect.

It uses the `app-store` environment (only `ASC_KEY_ID`, `ASC_ISSUER_ID` and
`ASC_KEY_P8_BASE64`; the signing secrets are not passed to it). Because the
workflow runs from `main`, the environment's deployment rules allow the branch
`main` in addition to `v*` tags.

## Privacy policy

Hosted with GitHub Pages from the `docs/` folder on `main`:

| Language | File | URL |
|---|---|---|
| English | `docs/privacy-policy.md` | https://360world.github.io/flysight-explorer-ios-app/privacy-policy.html |
| Hungarian | `docs/privacy-policy.hu.md` | https://360world.github.io/flysight-explorer-ios-app/privacy-policy.hu.html |

Changes go live a minute or two after they are merged into `main`.
