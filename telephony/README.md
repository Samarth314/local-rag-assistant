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
- A softphone. [Linphone](https://linphone.org) is free and open source.

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

**3. Point Linphone at it.** Add an account with:

- Username `phone`
- Password — your `ATARU_SIP_PASSWORD`
- Domain — your `ATARU_SIP_HOST`
- Transport UDP

Both devices must be on the tailnet. **Then dial `100`.**

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

With no `RAG_STT_URL`, the line is **keypad-only** and still fully usable — it
degrades rather than breaking. To enable spoken questions, point `RAG_STT_URL`
at a local ASR endpoint (Parakeet, `whisper.cpp` server, anything that accepts
`POST` of a WAV and returns `{"text": ...}`).

Output speech uses **espeak-ng inside the container** — offline, free, robotic.
For a better voice, point `RAG_TTS_URL` at a local Kokoro-style endpoint that
accepts `{"text": ...}` and returns WAV; it is resampled to 8 kHz automatically.

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
