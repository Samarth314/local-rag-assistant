# Asterisk + the ATARU AGI bridge, with fully offline speech synthesis.
#
# Deliberately THIN: this image gets espeak-ng and sox, not lancedb and torch.
# Retrieval happens over HTTP against the RAG service (RAG_API_URL), so the
# telephony container and the index stay independent and a wedged call can
# never take the vault down with it.
#
# Base is Ubuntu, NOT Debian: asterisk was dropped from Debian 12 (bookworm)
# and has no installation candidate there (Debian bug #1031046). Ubuntu keeps
# it in `universe`, which is enabled by default in the official images, and
# ships arm64 -- so this builds on the Jetson with no source build.
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        asterisk \
        espeak-ng \
        sox \
        gettext-base \
        python3 \
        ca-certificates \
        curl \
    && rm -rf /var/lib/apt/lists/*

# Piper: a neural TTS that runs offline on CPU and sounds vastly better than
# espeak over a phone line. espeak-ng above stays installed as the fallback,
# so a failed download here degrades the voice rather than breaking the line.
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
    || echo "WARNING: Piper install failed; falling back to espeak-ng at runtime"; \
    rm -f /tmp/piper.tar.gz

# The AGI runs under the system python3 (stdlib only -- see the note above).
WORKDIR /opt/ataru
COPY voice.py voice_media.py voice_backend.py voice_agi.py /opt/ataru/
COPY telephony/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY telephony/pjsip.conf.template /etc/asterisk/pjsip.conf.template

# The dialplan calls the AGI by absolute path, so astagidir is irrelevant.
# Symlinks are still placed in BOTH conventional agi-bin locations, because
# which one Asterisk searches depends on astdatadir/astagidir and differs
# between builds -- /usr/share/asterisk/agi-bin is the default on Ubuntu.
RUN chmod +x /opt/ataru/voice_agi.py /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/lib/asterisk/agi-bin /usr/share/asterisk/agi-bin \
                /var/lib/asterisk/sounds/ataru \
    && ln -sf /opt/ataru/voice_agi.py /var/lib/asterisk/agi-bin/ataru \
    && ln -sf /opt/ataru/voice_agi.py /usr/share/asterisk/agi-bin/ataru

# One second of silence: GET DATA needs a file to play when collecting digits
# after a prompt has already been spoken.
RUN sox -n -r 8000 -c 1 -b 16 /var/lib/asterisk/sounds/ataru/silence.wav trim 0.0 1.0

ENV PYTHONPATH=/opt/ataru
ENV RAG_VOICE_SOUNDS=/var/lib/asterisk/sounds/ataru
ENV RAG_PIPER_MODEL=/opt/piper/voices/en_US-lessac-medium.onnx

EXPOSE 5060/udp 5060/tcp 10000-10099/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["asterisk", "-f", "-vvv"]
