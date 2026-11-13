# Publishing Blask Sync

Blask Sync ships two ways:

- **GitHub (Developer ID).** `.github/workflows/release.yml` signs the app with a Developer ID Application
  certificate under the hardened runtime, notarizes and staples it, then publishes it with its Sparkle feed.
  Notarized apps open without the Gatekeeper warning, so the `xattr` step is gone for new users.
- **Mac App Store.** `VARIANT=appstore scripts/bundle.sh` builds a sandboxed app without Sparkle (the App Store
  updates it), and `scripts/package-appstore.sh` signs and packages it, and uploads it with `--upload`.
  Its listing, privacy answers and review notes are in [listing.md](listing.md).

## One-time setup in the Apple Developer account

Team ID: `NWM8D7V2YA`.

### Certificates (developer.apple.com → Certificates, IDs & Profiles → Certificates)

Easiest from Xcode → Settings → Accounts → Manage Certificates → **+**, which creates the key in your keychain:

1. **Developer ID Application** — signs the GitHub release.
2. **Apple Distribution** — signs the App Store app.
3. **Mac Installer Distribution** (shows up as "3rd Party Mac Developer Installer") — signs the App Store `.pkg`.

Back up each with its private key: Keychain Access → My Certificates → right-click → Export (`.p12`), into
`~/Documents/BlaskSync-signing/` next to the existing backups.

### App ID and profile

1. Identifiers → **+** → App IDs → App: description "Blask Sync", explicit bundle ID `asia.miron.BlaskSync`. No
   extra capabilities are needed (the sandbox, network and audio entitlements need none).
2. Profiles → **+** → **Mac App Store Connect** → that App ID → the Apple Distribution certificate. Download it,
   e.g. to `~/Documents/BlaskSync-signing/BlaskSync_AppStore.provisionprofile`.

### App Store Connect API key

App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**, access
**Developer** (enough for notarization and uploads). Download `AuthKey_<KEY ID>.p8` (only possible once) and
note the Key ID and Issuer ID. Keep the `.p8` in `~/.appstoreconnect/private_keys/` (where `altool` looks) and
in the signing backup.

### GitHub secrets (Settings → Secrets and variables → Actions)

| Secret | Value |
| --- | --- |
| `SIGNING_P12` | the **Developer ID Application** `.p12`, base64: `base64 -i DeveloperID.p12 \| pbcopy` (replaces the self-signed certificate) |
| `SIGNING_P12_PASSWORD` | its export password |
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | API Issuer ID |
| `ASC_KEY_P8` | contents of `AuthKey_<KEY ID>.p8` (`pbcopy < AuthKey_XXXX.p8`) |
| `SPARKLE_PRIVATE_KEY` | unchanged |

## The first notarized GitHub release

macOS ties Screen Recording and System Audio Recording permissions to the signing certificate. Moving from the
self-signed certificate to Developer ID changes it once, so after updating, users are asked for those
permissions again. Say so in that release's notes. Sparkle accepts the update, because it checks the EdDSA
signature, which doesn't change.

## Creating the app in App Store Connect

Apps → **+** → New App: platform macOS, name **Blask Sync**, primary language English (U.S.), bundle ID
`asia.miron.BlaskSync`, SKU `blask-sync`, full access. Then fill in everything from [listing.md](listing.md):

- App Information: subtitle, category **Utilities** (secondary **Entertainment**), content rights (no
  third-party content), age rating questionnaire (all "None"/"No" → 4+).
- Pricing and Availability: Free, all territories.
- App Privacy: privacy policy URL, then **Data Not Collected**.
- The version page: screenshots, promotional text, description, keywords, support and marketing URLs,
  copyright, App Review information (contact, notes, demo video), and the build.

## Uploading a build

```sh
VERSION=1.0.0 BUILD_NUMBER=1 \
PROVISIONING_PROFILE=~/Documents/BlaskSync-signing/BlaskSync_AppStore.provisionprofile \
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
scripts/package-appstore.sh --upload
```

`BUILD_NUMBER` must be higher than every earlier upload. After processing (10–30 minutes) the build appears in
App Store Connect → TestFlight; install it through TestFlight on your Mac and test it before submitting, since
that's the sandboxed build reviewers get.

## Things to test in the sandboxed build before submitting

- **Music sync** (the Core Audio tap). Apple doesn't document whether process taps work in the App Sandbox; the
  meters in Settings → Music must move while music plays. If they don't, the App Store version can't offer music
  sync as is.
- Pairing a bridge (the sandboxed app keeps its own copy of the pairing, in
  `~/Library/Containers/asia.miron.BlaskSync/`, so it has to pair once).
- Screen sync, Manual, open at login, lights off at shutdown, switching language (relaunches the app).

## Screenshots

Mac App Store screenshots are 16:10, one of 1280×800, 1440×900, 2560×1600 or 2880×1800, 1–10 of them. Suggested
set: the menu bar panel over a colorful desktop, Settings → Screen (mapping canvas), Settings → Music (meters),
the Manual Control window, and a photo-style shot of the lights behind a monitor if you have one.
