FROM python:3.12-slim

WORKDIR /app

# Speech synthesis for GET /voice/speak, so the iOS Shortcut can play the same
# Piper voice the phone line uses instead of an iOS voice that merely sounds
# similar. sox does the resample; espeak-ng is the fallback if the Piper
# download below fails. Both are small -- this does not pull in torch.
RUN apt-get update && apt-get install -y --no-install-recommends \
        espeak-ng \
        sox \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Same voice model and version as telephony/Dockerfile -- they must match, or
# the phone line and the Shortcut speak in two different voices.
ARG PIPER_VERSION=2023.11.14-2
ARG PIPER_VOICE=en_US-lessac-medium
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-arm64}" in \
      arm64) PIPER_ARCH=aarch64 ;; \
      amd64) PIPER_ARCH=x86_64 ;; \
      *)     PIPER_ARCH=aarch64 ;; \
    esac; \
    mkdir -p /opt/piper /opt/piper/voices; \
    ( curl -fsSL -o /tmp/piper.tar.gz \
        "https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_${PIPER_ARCH}.tar.gz" \
      && tar -xzf /tmp/piper.tar.gz -C /opt \
      && ln -sf /opt/piper/piper /usr/local/bin/piper \
      && curl -fsSL -o /opt/piper/voices/${PIPER_VOICE}.onnx \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/${PIPER_VOICE}.onnx?download=true" \
      && curl -fsSL -o /opt/piper/voices/${PIPER_VOICE}.onnx.json \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/${PIPER_VOICE}.onnx.json?download=true" \
      && echo "piper installed" ) \
    || echo "WARNING: Piper install failed; /voice/speak will use espeak-ng"; \
    rm -f /tmp/piper.tar.gz

COPY requirements-docker.txt .
RUN pip install --no-cache-dir -r requirements-docker.txt

COPY *.py ./

# Run as a non-root user; index/state live on the /data volume.
RUN useradd -m rag && mkdir /data && chown rag:rag /data
USER rag
ENV RAG_DATA_DIR=/data
ENV RAG_PIPER_MODEL=/opt/piper/voices/en_US-lessac-medium.onnx

CMD ["python", "cli.py"]
