# ATARU for iOS

The mobile client for a private, local-first RAG assistant. Two things:

- **Ask** — hold a button, speak a question, hear the answer in the same voice
  the telephone front door uses.
- **Library** — browse everything ATARU has indexed, preview it, and send it on.

Nothing runs on the phone but the UI. No model, no vector index, no copy of the
vault. The phone is a client on your own Tailnet.

## Build and run

Requires Xcode 16+ and iOS 17+. No third-party packages, no paid dependency, no
backend needed to open it.

`ATARU.xcodeproj` is **generated from `project.yml` and is not in the repo**, so
generate it first — after cloning, and again whenever anyone adds or removes a
source file:

```bash
brew install xcodegen
```

```bash
cd app && xcodegen generate && open ATARU.xcodeproj
```

Keeping the project file out of version control is deliberate. `project.pbxproj`
is a generated blob that conflicts on almost any concurrent change, and two
people adding files in the same week is exactly when that hurts.

Run the tests:

```bash
xcodebuild -project ATARU.xcodeproj -scheme ATARU -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

39 unit tests, 4 UI tests.

## Demo and Live

**Demo** is the default and needs nothing. It serves synthetic fixtures through
the same `ATARUService` protocol Live uses, with simulated latency, so every
screen and every state — loading, empty, filtered-to-nothing, unsupported file
type, missing original — is reachable without a server.

**Live** points at your own backend. In **Settings**, set the base URL to your
ATARU host, e.g. `http://100.106.109.31:8000`, and tap **Save and test**.

`http://` is accepted only in Debug builds and only for private hosts
(RFC1918, `100.64/10` for Tailscale, `.local`, `.ts.net`). A Release build
requires HTTPS. See `Core/Configuration/AppConfiguration.swift`.

A bearer token is optional and lives in the Keychain.

## What the backend must provide

See `API_CONTRACT.md`. The endpoints are the ones in the companion
`local-rag-assistant` repo:

| Route | Used for |
|---|---|
| `GET /health` | connection test |
| `GET /documents` | the library |
| `GET /documents/{id}` | detail |
| `GET /documents/{id}/content` | preview and send |
| `GET /voice/speak?q=` | spoken answer (WAV) |
| `GET /voice/answer?q=` | text answer, used when the server has no TTS |

## Two decisions worth knowing about

**Dictation is on-device, enforced.** `SFSpeechRecognizer` is configured with
`requiresOnDeviceRecognition = true`. Without that flag it streams your audio to
Apple for transcription, which would mean questions about a private vault
leaving the phone before ATARU ever saw them. If on-device recognition isn't
available for the current locale, the app offers typing instead — it never
quietly falls back to the network path.

**Document bytes are fetched only when you ask.** Opening a document shows
metadata the library already loaded. The file itself is downloaded when you tap
Preview or Send, and everything downloaded is deleted when the app goes to the
background.

## Layout

```
ATARU/
├── App/               entry point, app state, tab shell
├── Core/
│   ├── Audio/         dictation and answer playback
│   ├── Configuration/ base URL validation, endpoint building
│   ├── DesignSystem/  theme tokens, typography, shared components
│   ├── Networking/    service protocol, live + demo implementations
│   ├── Security/      Keychain, redaction, biometric lock
│   └── Utilities/     formatters, haptics
├── Features/
│   ├── Documents/     library, detail, preview, share
│   ├── Settings/      connection and privacy
│   └── Voice/         orb, ask flow
├── Shared/Models/     domain types
└── Resources/
```

## Scope

This is a deliberate subset of the original nine-feature spec. Home, Brief,
Health, Journal, Services and System were cut: the backend does not expose them,
and a tab bar full of destinations that cannot be filled is a worse product than
two that work. The design system and service boundary still accommodate them.

Not implemented: iPad-specific split layouts (it runs, adaptively, but was not
designed for), pagination (the library loads in one page and filters locally),
and offline caching of the document list.

## Installing on your own iPhone

The Simulator needs no setup. A physical device needs a signing identity.

**1. Set your team and bundle prefix.** These stay out of the repo:

```bash
cp Config.example.xcconfig Config.xcconfig
```

Edit it and set `DEVELOPMENT_TEAM` to your 10-character Team ID, plus
`ATARU_BUNDLE_ID_PREFIX` to your own reverse-DNS prefix. Bundle IDs are globally
unique, so the default `com.ataru.client` may already be claimed by someone else
— that failure looks like an unhelpful provisioning error rather than a name
collision.

Get the Team ID from the certificate's **OU** field:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

```
subject=UID=…, CN=Apple Development: you@example.com (AAAAAAAAAA), OU=BBBBBBBBBB, …
                                                      ^ certificate id  ^ TEAM ID
```

Take `OU`, not the code in parentheses. They look identical — ten uppercase
characters — and using the wrong one still *builds*, then fails much later with
`InvalidProviderToken` on every VoIP push, which points nowhere near signing.

**2. Generate the project, open and run.**

```bash
xcodegen generate && open ATARU.xcodeproj
```

Plug the phone in, pick it from the device menu at the top of the window, and
press ⌘R. First run only: on the phone, **Settings → General → VPN & Device
Management → Developer App → Trust**.

**A free Apple ID works**, with two limits: the app expires after **7 days** and
must be reinstalled from Xcode, and you can have three sideloaded apps at once.
The paid Developer Program ($99/year) extends that to a year.

Signing lives in `Signing.xcconfig`, which `#include?`s `Config.xcconfig` if it
exists. That means `xcodegen generate` never wipes your team ID — a normal
hazard when signing is set through the Xcode UI on a generated project.
