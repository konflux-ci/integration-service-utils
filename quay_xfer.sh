#!/bin/bash

### requires jq + skopeo to be installed locally

# arg check
if [ $# -ne 2 ]; then
  echo "Usage: $0 [source_image] [destination_image]"
  exit 1
fi

# extract the registry info
SOURCE="$1"
DESTINATION="$2"
SOURCE_REGISTRY="$(echo "${SOURCE}" | awk -F'/' '{print $1}')"
SOURCE_REPO="${SOURCE#$SOURCE_REGISTRY}"
SOURCE_REPO="${SOURCE_REPO:1}"
DESTINATION_REGISTRY="$(echo "${DESTINATION}" | awk -F'/' '{print $1}')"

# check that
if skopeo login --get-login "${SOURCE_REGISTRY}" &> /dev/null && skopeo login --get-login "${DESTINATION_REGISTRY}" &> /dev/null; then
    echo "Credentials for both repos authenticated"
  else
    echo "Error authenticating credentials"
    echo "Login using skopeo login for both repos"
    exit 1
fi 

# build skopeo command
SKOPEO_CMD="skopeo copy --all"

# fetch tags from the source repo with pagination
TAGS=()
page=1
echo "Begin fetching tags"

while :; do
  echo "Fetching tags from page $page..."
  RESPONSE=$(curl -s "https://quay.io/api/v1/repository/${SOURCE_REPO}/tag/?page=${page}&limit=100")

  if [ -z "$RESPONSE" ]; then
    echo "Error fetching tags from quay.io"
    exit 1
  fi

  TAGS_PAGE=$(echo "$RESPONSE" | jq -r '.tags[].name')

  if [ -z "$TAGS_PAGE" ]; then
    echo "No tags found on page $page"
    break
  fi

  TAGS+=($TAGS_PAGE)
  HAS_ADDITIONAL=$(echo "$RESPONSE" | jq '.has_additional')

  if [ "$HAS_ADDITIONAL" = "true" ]; then
    page=$((page+1))
  else
    break
  fi
done

echo "Total tags to copy: ${#TAGS[@]}"

# copy each tag
for TAG in "${TAGS[@]}"; do
  echo "Copying tag $TAG..."
  $SKOPEO_CMD docker://"${SOURCE}":"${TAG}" docker://"${DESTINATION}":"${TAG}"
done
