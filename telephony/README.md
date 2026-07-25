# ATARU by phone

Call your assistant and ask it about your documents, with voice **or** the
keypad. Runs entirely on your tailnet: no carrier, no cloud speech service, no
phone number, no monthly bill.

```
Linphone (iPhone)  ──SIP/RTP over Tailscale──▶  Asterisk  ──AGI──▶  voice.py
                                                                       │
                                                              HTTP /voice/answer
                                                                       ▼
                                                            the RAG service
```

## Why this shape

A real dialable phone number needs a carrier, and a carrier means your audio —
and with Twilio's `<Say>`, your *answer text* — leaves the machine. Since ATARU
exists to keep that material local, the default front door is a SIP extension
on the tailnet instead of a PSTN number. You dial an extension from a softphone
rather than a number from anywhere, and in exchange nothing leaves your network
and it costs nothing.

If you later want to call from any phone, see **Adding a real phone number**.

## Requirements

- Docker on the host that will answer calls (the Mac mini or the Orin).
- Tailscale on that host **and** on the phone.
- The RAG service reachable over HTTP (`python cli.py serve`, default `:8000`).
- A SIP softphone. Asterisk answers calls; something has to place them.
  [Linphone](https://linphone.org) and Zoiper are both free; any SIP client works.

## Setup

**1. Configure.** Copy the example and fill it in:

```bash
cd telephony
cp .env.example .env
```

| Variable | What it is |
|---|---|
| `ATARU_SIP_HOST` | Tailnet address of this host (e.g. `100.x.y.z`) |
| `ATARU_SIP_PASSWORD` | Softphone SIP password — long and random |
| `ATARU_VOICE_PIN` | **DTMF access code.** Required; the container refuses to start without it |
| `RAG_API_URL` | Where the RAG service listens (default `http://127.0.0.1:8000`) |
| `RAG_STT_URL` | *Optional* ASR endpoint. Omit for keypad-only |
| `RAG_TTS_URL` | *Optional* TTS endpoint. Omit to use offline espeak-ng |

**2. Build and run:**

```bash
docker compose --env-file .env up -d --build
docker compose logs -f asterisk
```

**3. Point your softphone at it.** Add a SIP account (not a hosted account
with the app vendor):

- Username `phone`
- Password — your `ATARU_SIP_PASSWORD`
- Domain — your `ATARU_SIP_HOST`
- Transport **UDP** (only UDP is offered; TLS is not configured)

Both devices must be on the tailnet. **Then dial `100`.**

Confirm registration server-side rather than trusting the app:

```bash
docker compose exec asterisk asterisk -rx "pjsip show contacts"
```

## Using the line

You are asked for the access code first — nothing is read out before it clears.
Then:

| Key | Does |
|---|---|
| `1`–`5` | Pin an agent (comms, finance, health, life, records — alphabetical) |
| `9` | Name the source document for the last answer |
| `0` | Repeat the menu |
| `#` | Hang up |

You can also just speak a question instead of choosing an agent — the router
picks the agent, exactly as it does on the CLI. Saying "that's all" ends the call.

The keypad is generated from `RAG_VOICE_AGENTS`, so adding an agent server-side
changes the menu with no code change here.

## Speech is optional

Spoken questions are transcribed by **NVIDIA Parakeet**, running as a separate
container (`telephony/stt/`). It is deliberately isolated: NeMo pulls in torch
and the image is several GB, so a model reload can never wedge the call path.

```bash
docker compose --env-file .env up -d --build stt   # first build is slow
curl -s --data-binary @clip.wav -H 'Content-Type: audio/wav' \
     http://127.0.0.1:8081/asr
```

On the Jetson, override the base with a CUDA-enabled NeMo image:
`STT_BASE_IMAGE=dustynv/nemo:r36.4.0` in `.env`.

With `RAG_STT_URL` blank the line is **keypad-only** and still fully usable — it
degrades rather than breaking. Any endpoint accepting a POSTed WAV and returning
`{"text": ...}` works, so an existing ASR service can be pointed at instead.

Output speech uses **Piper** — a neural TTS that runs offline on CPU and sounds
far better than a formant synthesiser over a phone line. The voice model is
baked into the image at build time.

espeak-ng stays installed as a fallback: if the Piper download fails during the
build, the line still works, just robotic. Check which engine is live:

```bash
docker compose exec asterisk python3 -c \
  "import sys; sys.path.insert(0,'/opt/ataru'); from voice_media import MediaConfig; print(MediaConfig.from_env().engine)"
```

`piper` is what you want; `espeak` means the download failed. A remote engine
can still be used instead via `RAG_TTS_URL` (takes precedence over both).

## Calling without a softphone: the iOS Shortcut

A Shortcut over Tailscale gives you the same assistant with no SIP app at all —
"Hey Siri, Ask ATARU", speak a question, hear the answer. Three actions:

| Action | Setting |
|---|---|
| Dictate Text | — |
| Get Contents of URL | `http://<tailnet-ip>:8000/voice/speak?q=` + the *Dictated Text* variable |
| Play Sound | *Contents of URL* |

`/voice/speak` returns the answer as WAV audio rendered by the **same Piper
voice the phone line uses**, so the two front doors sound identical. The text
is also returned in the `X-Ataru-Text` header if you want to display it.

The audio is served at Piper's native 22.05 kHz, not the line's 8 kHz — that
downsample is a constraint of the *phone network*, not of the voice, and a
phone speaker has no reason to suffer it.

If you would rather use an iOS voice (lower latency: text is a few hundred
bytes, audio is a few hundred KB), use `/voice/answer?q=` with *Get Dictionary
Value* → key `text` → *Speak Text* instead. Both routes exist; neither leaves
the tailnet.

Requires `RAG_PIPER_MODEL` to point at a voice inside the **rag** container —
the root `Dockerfile` bakes in the same `en_US-lessac-medium` as telephony. If
the download failed at build time the endpoint falls back to espeak-ng; if
neither is present it returns **503** and `/voice/answer` still works.

## Two constraints the medium imposes

**The fast model is pinned.** Escalation to the thorough model is disabled on
this path. Measured on the Orin the fast model answers in ~2.5s and the thorough
one in 20–30s; past roughly three seconds of silence a caller assumes the line
dropped. `/voice/answer` also skips query expansion, which alone costs ~6s.
The trade is slightly weaker recall for a line that feels alive.

**Answers are reshaped for the ear.** Vault answers are markdown full of
bracketed paths, which is unlistenable read aloud. `to_speech()` strips that and
truncates to about three sentences; the citation is offered on keypress `9`
instead of being spoken.

## Security

- **A PIN is mandatory and the line fails closed.** Caller ID is trivially
  spoofed, so the DTMF code is the real authentication. If `ATARU_VOICE_PIN` is
  unset the container exits rather than answering openly, and speech received
  before the PIN clears never reaches the backend (there is a test for exactly
  that).
- Three wrong attempts ends the call. The compare is constant-time so the line
  cannot be used as an oracle.
- The dialplan has **no outbound context**, so a stolen softphone credential
  cannot place calls through this server.
- Nothing is exposed publicly. Reachability comes from Tailscale; there is no
  port forward and no registration to any external SIP provider.
- The rendered `pjsip.conf` (which contains the SIP password) exists only inside
  the container and is written `chmod 600`. `.env` is gitignored.

## Adding a real phone number later

The call logic in `voice.py` is provider-agnostic on purpose — it consumes
"caller pressed digits" and "caller said something" and returns what to say.
Twilio needs only a thin webhook adapter translating those to TwiML, plus a
publicly reachable URL (Tailscale Funnel exposes just that one endpoint).

Costs about $1.15/month plus $0.0085/minute inbound. Be aware of the privacy
change: with `<Gather input="speech">`/`<Say>`, caller audio goes to Google's
STT and **your answer text goes to Twilio's TTS**. Twilio Media Streams plus
your own local STT/TTS avoids that — Twilio then carries audio but never sees a
transcript or an answer.

## Verified vs not

**Verified:** the call state machine, AGI protocol parsing, media command
builders, speech reshaping, PIN enforcement and fail-closed behaviour — 56
offline tests covering them, no telephony stack required. Also verified: the
entrypoint renders the SIP template correctly and aborts when the PIN is missing.

**Not yet verified:** a real SIP call. Docker was not available on the machine
where this was written, so no call has been placed. Expect to iterate — the
likeliest remaining spot is RTP handling under `network_mode: host`.

The base image is **Ubuntu, not Debian**: asterisk was dropped before Debian 12
released and has no installation candidate there
([Debian #1031046](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=1031046)).
Ubuntu keeps it in `universe` with arm64 builds. Override with
`--build-arg BASE_IMAGE=` if you need something else.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Container exits immediately | `ATARU_VOICE_PIN` unset — that is deliberate |
| Softphone will not register | `ATARU_SIP_HOST` must be the *tailnet* address; check Tailscale is up on both ends |
| Call connects, silence | espeak/sox missing, or `RAG_VOICE_SOUNDS` unwritable — `docker compose logs asterisk` |
| One-way audio | Almost always RTP/NAT; confirm `network_mode: host` and the `local_net` lines in `pjsip.conf.template` |
| "I can't reach your document index" | `RAG_API_URL` wrong, or `cli.py serve` is not running |
| Speech ignored, keypad fine | No `RAG_STT_URL` — that is the documented keypad-only mode |
