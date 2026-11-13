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
3. The **Release to TestFlight** workflow starts and waits for approval of the
   `app-store` environment. Approve it in the Actions tab.
4. fastlane fetches the signing certificate/profile from the encrypted match
   repo, builds with `MARKETING_VERSION=1.2.0` and the next free build number,
   and uploads to TestFlight.
5. In App Store Connect, test the build in TestFlight, then submit it for review.

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
