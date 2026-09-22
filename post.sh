#!/usr/bin/env bash

# Shared library: credentials, logging, the failure path, and both platforms'
# transport. See lib/botlib/ and the bot-harness docs.
. "$(dirname "$0")/lib/botlib/core.sh"
. "$(dirname "$0")/lib/botlib/secrets.sh"
. "$(dirname "$0")/lib/botlib/mastodon.sh"
. "$(dirname "$0")/lib/botlib/bluesky.sh"

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

require_commands curl jq python3

load_secrets rejected-plates
require_secrets MASTODON_SERVER MASTODON_TOKEN BLUESKY_HANDLE BLUESKY_APP_PASSWORD

# The plate image is 350x176, which is the size generate.py renders
IMAGE_WIDTH=350
IMAGE_HEIGHT=176

# The generated plate image, removed however this script exits
IMAGE_PATH="license_plate.png"

function cleanup {
    rm -f "$IMAGE_PATH"
}

trap cleanup EXIT

# Generate a plate image
output=$(python3 generate.py)
license_plate=$(echo "$output" | grep -oP 'Random plate selected: \K[A-Z0-9& -]{1,8}')
ALT_TEXT="A Virginia license plate reading ${license_plate}"

if [[ ! -f "$IMAGE_PATH" ]]; then
    exit_error "Error: A license plate image was not created."
fi

# Mastodon and Bluesky are attempted independently: a failure on one platform
# is logged and the other is still attempted, rather than the whole run dying
# on whichever platform happens to be first. Each block sets its own MASTODON_
# and BLUESKY_ vars to record what happened, and the script exits non-zero at
# the end if either platform failed -- one Slack alert either way, but it no
# longer costs a healthy platform its post.
MASTODON_OK="no"
BLUESKY_OK="no"

# Upload the image to Mastodon and wait for it to finish processing.
#
# v2 rather than the v1 endpoint this bot used to call: v1 returned only once
# the media was ready, which was simpler but meant a slow upload could time
# out with no way to resume. v2 accepts immediately and is polled.
if MEDIA_ID=$(masto_upload_media "$IMAGE_PATH" "$ALT_TEXT"); then
    if masto_await_media "$MEDIA_ID"; then
        # Post the status to Mastodon, including the uploaded image. The body
        # is empty: the alt text carries the plate, and the image is the post.
        if masto_post_status "" "$MEDIA_ID" > /dev/null; then
            log_info "posted to mastodon media_id=${MEDIA_ID}"
            MASTODON_OK="yes"
        else
            log_error "Posting message to Mastodon failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        fi
    else
        log_error "Mastodon never finished processing the image: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
    fi
else
    log_error "Image could not be uploaded to Mastodon: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
fi

# Login to Bluesky
if SESSION_JSON=$(bsky_create_session "$BLUESKY_HANDLE" "$BLUESKY_APP_PASSWORD"); then
    ACCESS_JWT=$(bsky_access_jwt "$SESSION_JSON")

    # The repo is the account's DID, not its handle. This bot used to send the
    # handle, which works against the live API but is not what a record is
    # keyed on -- a handle change would orphan every post made under the old
    # one.
    BLUESKY_DID=$(bsky_did "$SESSION_JSON")
    if [ -z "$BLUESKY_DID" ]; then
        log_error "Bluesky login didn’t return a DID: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
    else
        # Upload the image, which goes to the account's own PDS rather than to
        # bsky.social. The host comes out of the session response, which
        # already carries the DID document.
        if ! PDS_HOST=$(bsky_pds_host_from_session "$SESSION_JSON"); then
            log_error "Could not determine the Bluesky PDS host."
        elif ! IMAGE_BLOB=$(bsky_upload_blob "$PDS_HOST" "$ACCESS_JWT" "image/png" "$IMAGE_PATH"); then
            log_error "Image upload to Bluesky failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
        else
            # Prepare the record. Built with jq rather than a heredoc so that
            # alt text containing a quote or a backslash is escaped rather
            # than producing invalid JSON -- the plate characters are
            # constrained today, but the record is no place to rely on that.
            RECORD=$(jq -n \
                --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
                --arg alt "$ALT_TEXT" \
                --argjson image "$IMAGE_BLOB" \
                --argjson width "$IMAGE_WIDTH" \
                --argjson height "$IMAGE_HEIGHT" \
                '{
                    "$type": "app.bsky.feed.post",
                    text: "",
                    createdAt: $created_at,
                    embed: {
                        "$type": "app.bsky.embed.images",
                        images: [ {
                            image: $image,
                            alt: $alt,
                            aspectRatio: { width: $width, height: $height }
                        } ]
                    }
                }')

            if BLUESKY_RESPONSE=$(bsky_create_record "$BLUESKY_DID" "$ACCESS_JWT" "$RECORD"); then
                log_info "posted to bluesky uri=$(printf '%s' "$BLUESKY_RESPONSE" | jq -r '.uri // empty')"
                BLUESKY_OK="yes"
            else
                log_error "Bluesky post failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
            fi
        fi
    fi
else
    log_error "Bluesky login failed: HTTP ${BOTLIB_LAST_STATUS} ${BOTLIB_LAST_BODY}"
fi

if [ "$MASTODON_OK" = "no" ] || [ "$BLUESKY_OK" = "no" ]; then
    exit_error "Posting failed: mastodon=${MASTODON_OK} bluesky=${BLUESKY_OK}"
fi
