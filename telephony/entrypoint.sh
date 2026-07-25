#!/bin/sh
# Asterisk does not expand environment variables inside its config files, so
# the SIP host and softphone password are substituted here at container start.
# The rendered file lives only in the container's filesystem.
set -e

# Note: no apostrophes in these messages -- an inner quote inside ${VAR:?...}
# is parsed inconsistently across sh implementations.
: "${ATARU_SIP_HOST:?ATARU_SIP_HOST must be set to the tailnet address of this host}"
: "${ATARU_SIP_PASSWORD:?ATARU_SIP_PASSWORD must be set}"

if [ -z "${ATARU_VOICE_PIN:-}" ]; then
    echo "refusing to start: ATARU_VOICE_PIN is unset." >&2
    echo "Caller ID is spoofable, so the DTMF code is the only authentication." >&2
    exit 1
fi

envsubst '${ATARU_SIP_HOST} ${ATARU_SIP_PASSWORD}' \
    < /etc/asterisk/pjsip.conf.template \
    > /etc/asterisk/pjsip.conf
chmod 600 /etc/asterisk/pjsip.conf

exec "$@"
