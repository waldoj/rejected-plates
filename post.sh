#!/usr/bin/env bash

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="{{MASTODON_SERVER}}"

# Your Mastodon account's access token
MASTODON_TOKEN="{{MASTODON_TOKEN}}"

# Your Bluesky handle
BLUESKY_HANDLE="{{BLUESKY_HANDLE}}"

# Your Bluesky app password
BLUESKY_APP_PASSWORD="{{BLUESKY_APP_PASSWORD}}"

# Define a failure function
function exit_error {
    printf '%s\n' "$1" >&2
    rm -f license_plate.png
    exit "${2-1}"
}

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

# Generate a plate image
output=$(python3 generate.py)
license_plate=$(echo "$output" | grep -oP 'Random plate selected: \K[A-Z0-9& -]{1,8}')

if [[ ! -f "license_plate.png" ]]; then
    echo "Error: A license plate image was not created."
    exit
fi

# Upload the image to Mastodon
RESPONSE=$(curl -s -H "Authorization: Bearer ${MASTODON_TOKEN}" -X POST \
    -H "Content-Type: multipart/form-data" \
    "${MASTODON_SERVER}/api/v1/media" \
    --form file=@"$IMAGE_PATH" \
    --form "description=$ALT_TEXT" | grep -E -o "\"id\":\"([0-9]+)\"")
RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    echo $RESPONSE
    exit_error "Image could not be uploaded"
fi

# Strip the media ID response down to the integer; this is in lieu of actually parsing the JSON
MEDIA_ID=$(echo "$RESPONSE" |grep -E -o "[0-9]+")

# If the upload didn't yield a valid media ID, give up
if [ ${#MEDIA_ID} -lt 10 ]; then
    exit_error "Image upload didn’t return a valid media ID"
fi

# Post the status to Mastodon, including the uploaded image
curl -s "${MASTODON_SERVER}/api/v1/statuses" \
    -H "Authorization: Bearer ${MASTODON_TOKEN}" \
    --data "media_ids[]=${MEDIA_ID}" \
    --data-urlencode "status="

# Login to Bluesky to get session token
SESSION_JSON=$(curl -s -X POST https://bsky.social/xrpc/com.atproto.server.createSession \
  -H "Content-Type: application/json" \
  -d "{\"identifier\":\"$BLUESKY_HANDLE\",\"password\":\"$BLUESKY_APP_PASSWORD\"}")

ACCESS_JWT=$(echo "$SESSION_JSON" | grep -o '"accessJwt":"[^"]*' | cut -d':' -f2 | tr -d '"')
if [ -z "$ACCESS_JWT" ]; then
  exit_error "Bluesky login failed."
fi

# Upload the image to Bluesky
BLOB_JSON=$(curl -s -X POST "https://bsky.social/xrpc/com.atproto.repo.uploadBlob" \
  -H "Authorization: Bearer $ACCESS_JWT" \
  -H "Content-Type: image/png" \
  --data-binary @"$IMAGE_PATH")
IMAGE_BLOB=$(echo "$BLOB_JSON" | jq -c '.blob')
if [ -z "$IMAGE_BLOB" ]; then
  exit_error "Image upload to Bluesky failed."
fi

# Prepare the status post for Bluesky
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
          "alt": "$ALT_TEXT"
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

# Delete the image file after posting
rm -f "$IMAGE_PATH"
