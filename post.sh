#!/usr/bin/env bash

# Shared library. Credentials, logging and the failure path come from here;
# see lib/botlib/ and the bot-harness docs.
#
# Only core and secrets are sourced. The platform helpers in mastodon.sh and
# bluesky.sh are deliberately not used yet: this bot talks to Mastodon's v1
# media endpoint and parses responses with grep, and moving it to the shared
# v2 helpers would change what it sends. That is a separate, reviewed commit.
. "$(dirname "$0")/lib/botlib/core.sh"
. "$(dirname "$0")/lib/botlib/secrets.sh"

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

load_secrets rejected-plates
require_secrets MASTODON_SERVER MASTODON_TOKEN BLUESKY_HANDLE BLUESKY_APP_PASSWORD

# The generated plate image, removed however this script exits. The original
# did this inside exit_error; a trap covers the success path too, and leaves
# the shared exit_error free of anything bot-specific.
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

# Upload the image to Mastodon.
#
# Note that RESULT captures grep's exit status rather than curl's, since curl
# is piped. Preserved as-is: correcting it would change when this bot fails.
RESPONSE=$(curl -s -H "Authorization: Bearer ${MASTODON_TOKEN}" -X POST \
    -H "Content-Type: multipart/form-data" \
    "${MASTODON_SERVER}/api/v1/media" \
    --form file=@"$IMAGE_PATH" \
    --form "description=$ALT_TEXT" | grep -E -o "\"id\":\"([0-9]+)\"")
RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Image could not be uploaded to Mastodon"
fi

# If the image upload wasn't successful, give up.
MEDIA_ID=$(echo "$RESPONSE" | grep -E -o "[0-9]+")
if [ ${#MEDIA_ID} -lt 10 ]; then
    exit_error "Image upload didn’t return a valid Mastodon media ID"
fi

# Post the status to Mastodon, including the uploaded image
curl -s "${MASTODON_SERVER}/api/v1/statuses" \
    -H "Authorization: Bearer ${MASTODON_TOKEN}" \
    --data "media_ids[]=${MEDIA_ID}" \
    --data-urlencode "status="

log_info "posted to mastodon media_id=${MEDIA_ID}"

# Login to Bluesky to get session token
SESSION_JSON=$(curl -s -X POST https://bsky.social/xrpc/com.atproto.server.createSession \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"$BLUESKY_HANDLE\",\"password\":\"$BLUESKY_APP_PASSWORD\"}")

ACCESS_JWT=$(echo "$SESSION_JSON" | grep -o '"accessJwt":"[^"]*' | cut -d':' -f2 | tr -d '"')
if [ -z "$ACCESS_JWT" ]; then
  exit_error "Bluesky login failed."
fi

# The session token is a credential in its own right, so keep it out of logs
add_redaction "$ACCESS_JWT"

# Upload the image to Bluesky
BLOB_JSON=$(curl -s -X POST "https://bsky.social/xrpc/com.atproto.repo.uploadBlob" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -H "Content-Type: image/png" \
  --data-binary @"$IMAGE_PATH")
IMAGE_BLOB=$(echo "$BLOB_JSON" | jq -c '.blob')
if [ -z "$IMAGE_BLOB" ]; then
  exit_error "Image upload to Bluesky failed."
fi

# Prepare the status post for Bluesky.
#
# repo is the handle rather than the account's DID. That is wrong -- the DID is
# what a record is keyed on, and survives a handle change -- but it is what
# this bot sends today, and correcting it is a separate commit.
POST_BODY=$(cat <<EOF
{
  "repo": "$BLUESKY_HANDLE",
  "collection": "app.bsky.feed.post",
  "record": {
    "\$type": "app.bsky.feed.post",
    "text": "",
    "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "embed": {
      "\$type": "app.bsky.embed.images",
      "images": [
        {
          "image": $IMAGE_BLOB,
          "alt": "$ALT_TEXT",
          "aspectRatio": {"width": 350, "height": 176}
        }
      ]
    }
  }
}
EOF
)

# Post the status to Bluesky, with the uploaded image
BLUESKY_RESPONSE=$(curl -s -X POST "https://bsky.social/xrpc/com.atproto.repo.createRecord" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -H "Content-Type: application/json" \
  -d "$POST_BODY")

# Check for success (should contain a 'uri' field)
if ! echo "$BLUESKY_RESPONSE" | jq -e '.uri' >/dev/null 2>&1; then
  exit_error "Bluesky post failed: $BLUESKY_RESPONSE"
fi

log_info "posted to bluesky uri=$(echo "$BLUESKY_RESPONSE" | jq -r '.uri // empty')"
