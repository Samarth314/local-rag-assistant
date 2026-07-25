# Asterisk + the ATARU AGI bridge, with fully offline speech synthesis.
#
# Deliberately THIN: this image gets espeak-ng and sox, not lancedb and torch.
# Retrieval happens over HTTP against the RAG service (RAG_API_URL), so the
# telephony container and the index stay independent and a wedged call can
# never take the vault down with it.
#
# Debian ships asterisk for arm64, so this builds on the Jetson or the Mac mini
# with no source build.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        asterisk \
        espeak-ng \
        sox \
        gettext-base \
        python3 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# The AGI runs under the system python3 (stdlib only -- see the note above).
WORKDIR /opt/ataru
COPY voice.py voice_media.py voice_backend.py voice_agi.py /opt/ataru/
COPY telephony/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY telephony/pjsip.conf.template /etc/asterisk/pjsip.conf.template

RUN chmod +x /opt/ataru/voice_agi.py /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/lib/asterisk/agi-bin /var/lib/asterisk/sounds/ataru \
    && ln -sf /opt/ataru/voice_agi.py /var/lib/asterisk/agi-bin/ataru

# One second of silence: GET DATA needs a file to play when collecting digits
# after a prompt has already been spoken.
RUN sox -n -r 8000 -c 1 -b 16 /var/lib/asterisk/sounds/ataru/silence.wav trim 0.0 1.0

ENV PYTHONPATH=/opt/ataru
ENV RAG_VOICE_SOUNDS=/var/lib/asterisk/sounds/ataru

EXPOSE 5060/udp 5060/tcp 10000-10099/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["asterisk", "-f", "-vvv"]
