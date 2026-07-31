Mount point for the APNs signing key (.p8).

Keep the key OUT of this repo in normal use -- point APNS_KEY_DIR in .env at a
directory outside the checkout, e.g.

    APNS_KEY_DIR=/home/samarth/.ataru

This directory exists only so the compose volume has something to bind when no
key is configured. Anything dropped here is gitignored.
