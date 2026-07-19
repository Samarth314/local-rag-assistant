"""Word-based text chunking, adapted from the llama-index SentenceSplitter pattern
but without a tokenizer dependency -- word count is a good enough proxy here since
the embedding model handles truncation on its own."""

import re

PARAGRAPH_SEPARATOR = re.compile(r"\n\s*\n")


def chunk_text(text: str, chunk_size: int, overlap: int) -> list[str]:
    paragraphs = [p.strip() for p in PARAGRAPH_SEPARATOR.split(text) if p.strip()]

    chunks: list[str] = []
    current_words: list[str] = []

    for paragraph in paragraphs:
        words = paragraph.split()
        i = 0
        while i < len(words):
            room = chunk_size - len(current_words)
            if room <= 0:
                chunks.append(" ".join(current_words))
                current_words = current_words[-overlap:] if overlap else []
                continue
            take = words[i : i + room]
            current_words.extend(take)
            i += len(take)

    if current_words:
        chunks.append(" ".join(current_words))

    return chunks
