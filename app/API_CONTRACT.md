# API contract

What this client expects from an ATARU backend. Implemented by the companion
`local-rag-assistant` repo; anything else speaking these shapes works too.

All routes are `GET`. Base URL is configured in Settings; routes sit at the root
by default (`EndpointBuilder` can insert an `/api/<version>` prefix if a future
deployment needs one).

Authentication is an optional `Authorization: Bearer <token>` header.

---

## `GET /health`

Connection test.

```json
{"status": "ok"}
```

---

## `GET /documents`

Query parameters: `q` (matches titles and paths), `category`.

The client fetches the library unfiltered and filters locally, so typing in the
search field does not hit the network. Both parameters are still sent when the
client narrows server-side.

```json
{
  "documents": [
    {
      "id": "9f2c1a77b3e40d51",
      "title": "Vault Backup Policy.md",
      "path": "/docs/work/home-stack/Vault Backup Policy.md",
      "category": "work",
      "file_type": "md",
      "size_bytes": 9330,
      "modified_at": 1753142400.0,
      "indexed_at": 1753401200.0,
      "excerpt": "Backup and restore policy: snapshot cadence…",
      "chunk_count": 7,
      "tags": [],
      "previewable": true
    }
  ],
  "total": 1,
  "indexed_total": 42,
  "categories": {"finances": 6, "health": 4, "work": 20, "personal": 12}
}
```

**`id` is opaque and server-assigned.** The client never constructs one, never
parses one, and never sends a filesystem path back. That is what keeps
`/documents/{id}/content` from being a general file-read primitive.

**Timestamps are Unix seconds and every one is nullable.** Documents indexed
before the backend recorded ingest times have `indexed_at: null`, and the client
renders that as unknown rather than as 1 January 1970.

`category` is one of `finances`, `health`, `communications`, `work`,
`personal`. An unrecognised value is displayed as `personal` rather than
failing the page decode.

---

## `GET /documents/{id}`

The same object, with `excerpt` and `chunk_count` populated. Both need the
document's text, which is why the list omits them.

`404` if the id is not in the index.

---

## `GET /documents/{id}/content`

The document's bytes, with `Content-Type` set for the file type and
`Content-Disposition` carrying a human-readable filename — that filename is what
a recipient sees when the user shares the file.

**`X-Ataru-Reconstructed: 1`** means the server could not read the original file
and returned the text it extracted at index time instead. The client shows this
prominently, because the user may be about to send it to someone and "the PDF"
and "our extract of the PDF" are different artefacts.

---

## `GET /voice/speak?q=<question>`

Answers the question and returns **WAV audio**, rendered server-side.

| Header | Meaning |
|---|---|
| `X-Ataru-Text` | the answer as text (ASCII; used for the transcript) |
| `X-Ataru-Source` | path of the top source document, may be empty |

`503` means the answer succeeded but the server has no speech engine. The client
falls back to `/voice/answer` and speaks the text on device rather than failing
the question.

---

## `GET /voice/answer?q=<question>`

Text-only answer.

```json
{"text": "Snapshots run nightly…", "source": "/docs/work/policy.md", "model": "qwen2.5:7b-instruct"}
```

---

## Errors

| Status | Client behaviour |
|---|---|
| 401 | "token was rejected" — prompts for Settings |
| 403 | "endpoint refused the request" |
| 404 | "no such document" / "endpoint doesn't exist" |
| 503 (voice only) | falls back to the text route |
| other 4xx/5xx | "server returned HTTP n" |

Decoding failures report the expected *shape*, never the payload — payloads are
vault content and error strings end up in logs.

## Streaming voice: `WS /voice/session`

The streaming twin of `/voice/speak`. One WebSocket serves a whole call;
send one ask at a time and read events until `done`:

    -> {"type": "ask", "q": "...", "topK": 4}

    <- {"type": "accepted"}
    <- {"type": "delta", "text": "..."}           raw model text, live display
    <- {"type": "audio_begin", "seq": 0, "sampleRate": 24000, "channels": 1,
        "encoding": "pcm_s16le", "text": "<sentence>"}
    <- <binary: raw 16-bit little-endian PCM frames for the current seq>
    <- {"type": "audio_end", "seq": 0}
    <- {"type": "tts_unavailable"}                at most once; speak locally
    <- {"type": "done", "text": "...", "source": "...", "model": "..."}
    <- {"type": "error", "message": "..."}        per-question, socket stays up

Sentence audio is synthesized and sent while the model is still generating
later sentences, so first audio costs one sentence, not the whole answer.
Binary frames always belong to the most recent `audio_begin`. On any socket
failure fall back to `GET /voice/speak` for that question and reconnect on
the next one. Server truncation mirrors the blocking path
(`RAG_VOICE_STREAM_MAX_SENTENCES`, default 3).

---

## Files index: `/api/files/*`

The projects index, which is a DIFFERENT store from `/documents`. `/documents`
serves the vault records; this serves everything under `~/Projects`. The ids
are server-assigned hashes of different things and are **not interchangeable** -
a `/documents` id sent to `/api/files/{id}` is a 404 with nothing on screen to
explain it, which is why an answer's `document` payload carries a `source`.

### `GET /api/files/search`

Query parameters, all optional. `pod`, `umbrella`, `project`, `kind` and `ext`
are **repeatable** - `kind=pdf&kind=slides`, never `kind=pdf,slides`. No `q` is
a browse rather than a search.

| Parameter | Notes |
|---|---|
| `q` | omitted entirely when blank |
| `pod`, `umbrella`, `project`, `kind`, `ext` | repeatable |
| `since`, `until` | `YYYY-MM-DD`, inclusive |
| `location` | `local` or `nas-away` |
| `sort` | `relevance`, `mtime_desc`, `mtime_asc`, `name`, `size_desc` |
| `page`, `page_size` | 1-based page |

```json
{"ok": true, "total": 132, "page": 1, "page_size": 30,
 "hits": [{"id": "abc123", "path": "Projects/Robolabs/Tournaments/run.xlsx",
           "name": "run.xlsx", "title": "run", "ext": "xlsx", "kind": "sheet",
           "pod": "work", "umbrella": "Robolabs", "project": "Tournaments",
           "mtime": "2026-08-14T09:12:00Z", "size": 98304,
           "location": "local", "snippet": "…", "score": 0.82,
           "has_text": true}],
 "facets": {"pod": {"work": 4}, "umbrella": {"Robolabs": 11},
            "kind": {"sheet": 3}, "year": {"2026": 9}}}
```

`kind` is one of pdf, doc, slides, sheet, text, image, video, audio, other; an
unknown value is read as `other` rather than failing the page. `snippet` and
`score` exist only on a search - a browse omits both, and the client must not
read their absence as zero. **Facets are computed over the whole match set**,
not over the page returned: the category rails are drawn from them while one
page is on screen, and counting the page would relabel every chip on "load
more".

`location: "nas-away"` means the bytes are on the NAS and only an `AWAY.md`
placeholder is on this host. The row still appears - it is findable by name -
and the client shows a NAS badge and refuses to open a viewer for it.

### `GET /api/files/{id}`

```json
{"ok": true,
 "file": {"…hit fields…", "text_chars": 8421,
          "extracted_at": "2026-09-10T11:02:44.318000Z"},
 "previewable": true, "viewer": "pdf"}
```

`viewer` is `pdf`, `image`, `text`, `office` or `none`; anything else is read
as `none`. `text_chars` and `extracted_at` sit **inside** `file`.

### `GET /api/files/{id}/content`

The original bytes, inline, with the right content type and a
`Content-Disposition` filename. **404 for a `nas-away` file** - there is
nothing on this host to send, and an empty 200 would be a lie.

### `GET /api/files/{id}/preview`

A PNG thumbnail, or **204** when there is none. Never an error: a missing
thumbnail is cosmetic and the row draws its kind icon instead. The client
caches the absence as well as the image.

### `POST /api/files/narrow`

```json
{"q": "just the 2025 spreadsheets",
 "filters": {"umbrella": ["Robolabs"]},
 "history": [{"q": "robolabs", "filters": {}}]}
```

```json
{"ok": true, "query": "tournament",
 "filters": {"umbrella": ["Robolabs"], "kind": ["sheet"],
             "since": "2025-01-01", "until": "2025-12-31"},
 "explanation": "Narrowed to spreadsheets in Robolabs from 2025.",
 "result": {"…a search result…"}}
```

`filters` echoes the FULL new set, not a delta, and the client adopts it
wholesale. `explanation` is shown verbatim and the client never writes that
line itself: an invented "filtered to PDFs from 2025" that does not match what
the server applied is worse than no line at all. `history` is every earlier
rung, oldest first, each carrying the question asked and the filters that were
in force when it was asked.

A filter set may render a single value as a bare string (`"kind": "pdf"`); the
client accepts both that and a list.

### Chat and voice payloads

`done` on the socket, and the blocking `GET /voice/answer`, may carry either:

```json
"document": {"id": "f1", "title": "LAMC transcript", "file_type": "pdf",
             "previewable": true, "source": "files",
             "url": "/api/files/f1/content"}
"files": {"query": "run sheet",
          "filters": {"umbrella": ["Robolabs"], "kind": ["sheet"]},
          "total": 3}
```

`document` opens the viewer; `files` opens the Files tile with the narrowing
applied. `source` is `vault` or `files` and **defaults to `vault`** when
absent, because that is the index that existed first. If both arrive, the
document wins - a specific artefact is more specific than a listing.

### Putting a file on the wall display

**There is no REST route for this.** The server's document-on-display path is a
chat shortcut (`bridge._document_shortcut`), so the app asks in words: it POSTs
a text turn - "show <title> on the display" - through `/voice/answer` and shows
the server's own answer verbatim, including the two cases where it found the
file and could not display it.
