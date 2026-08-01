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
