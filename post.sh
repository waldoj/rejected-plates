#!/usr/bin/env bash

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="{{MASTODON_SERVER}}"

# Your Mastodon account's access token
MASTODON_TOKEN="{{MASTODON_TOKEN}}"

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
RESPONSE=$(curl -H "Authorization: Bearer ${MASTODON_TOKEN}" -X POST -H "Content-Type: multipart/form-data" ${MASTODON_SERVER}/api/v1/media --form file="@license_plate.png" --form "description=A Virginia license plate reading ${license_plate}" |grep -E -o "\"id\":\"([0-9]+)\"")
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

# Send the message to Mastodon
curl "$MASTODON_SERVER"api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" --data "media_ids[]=${MEDIA_ID}" --data "status=  "

RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed"
fi

rm -f license_plate.png
