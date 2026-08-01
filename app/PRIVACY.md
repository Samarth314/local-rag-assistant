# Privacy

ATARU exists so that answering questions about your own documents does not
require sending them to anyone. The app is a client to your own server, and the
decisions below are what make that claim true rather than aspirational.

## Where data goes

**Only to the base URL you configure in Settings.** There is no analytics
endpoint, no crash reporter, no feature-flag service and no third-party host
anywhere in this app. `LiveATARUService` is the only file that makes network
requests, and every one of them is built by `EndpointBuilder` from your base
URL.

There is no advertising identifier, no device fingerprint and no client
identifier of any kind in any request.

## Dictation is transcribed on device

`SFSpeechRecognizer` is configured with `requiresOnDeviceRecognition = true`.

This matters more than it looks. Without that flag, `SFSpeechRecognizer` streams
captured audio to Apple's servers for transcription — so a question about your
medical records would leave the phone, to a third party, *before ATARU ever saw
it*. That would defeat the point of running the assistant at home.

If on-device recognition is unavailable for the current locale, the app says so
and offers typing instead. It never silently uses the network path.

## Document content is fetched deliberately

Opening a document shows only metadata the library already loaded. The bytes are
downloaded when you tap **Preview** or **Send** — never on appear, never
speculatively, never in the background.

Everything downloaded lives in one scratch directory, excluded from iCloud
backup, and is deleted when the app enters the background. It can also be
cleared on demand from Settings.

## Sharing is always your decision

The share sheet is the system one. There is no default recipient, no automatic
upload and no "share to" integration. `assignToContact`, `addToReadingList` and
`openInIBooks` are excluded, because those put vault content somewhere the user
did not intend.

When the server returns extracted text instead of the original file, the detail
screen says so before you send it. Handing someone "the lab report" when what
you actually have is a text extraction of it is a misrepresentation the app
should not let you make by accident.

## Secrets

The bearer token is stored in the Keychain with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — this device only, never
synced to iCloud. It is never written to `UserDefaults` (a plist in the app
container, readable from a backup), never logged, and never included in an error
message.

## Caching

`URLSession` is configured `.ephemeral` with `urlCache = nil`. Responses contain
vault content and are not written to a URL cache; they live only as long as the
objects holding them.

## Transport

HTTPS is required in Release builds. Plain `http://` is accepted only in Debug
builds and only for private hosts — RFC1918 ranges, `100.64/10` (Tailscale's
CGNAT range), `.local`, and `.ts.net`. This is what lets you talk to a Jetson on
your Tailnet during development without opening the door to an unencrypted
connection to an arbitrary internet host in a shipped build.

**That rule is enforced by the app, not by App Transport Security.** `Info.plist`
sets `NSAllowsArbitraryLoads`, because Apple's `NSAllowsLocalNetworking`
exception covers RFC 1918 and `.local` but not `100.64.0.0/10` (RFC 6598), which
is the range Tailscale actually assigns — so there is no narrower ATS exception
that would reach a Tailnet host by IP.

The consequence is worth stating plainly: ATS will not stop this app from making
an insecure request. `AppConfiguration.validate` is what stops it, and it is
stricter than ATS would be. If you want the platform check back as well, run
`tailscale serve` on your host and connect over `https://…ts.net`, which has a
real certificate — then no exception is doing any work.

## Demo fixtures

The bundled sample documents are synthetic. They contain no real names, no
addresses, no account numbers, no medical values, and nothing derived from any
real vault. A unit test asserts this.

## What the app does not do

- No HealthKit access. ATARU's records are not Apple Health, and the app does
  not request permissions for a feature it does not implement.
- No background refresh, no push notifications, no location.
- No third-party SDKs of any kind.
