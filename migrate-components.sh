#!/bin/bash

# Migrates the spec.containerImage field to status.lastPromotedImage if
# status.lastPromotedImage is not already set.
#
# If spec.containerImage has been updated by imageRepository (has not sha)
# then the script will attempt to get the latest push snapshot or override
# snapshot that contains the component and gets the image from there
#
# REQUIREMENTS:
#  - kubectl >= 1.24
#  - jq

# takes two snapshot jsons and returns whichever has the newest metadata.creationTimestamp
get_newest_snapshot_json() {
    PUSH_SNAPSHOT_JSON=$1
    OVERRIDE_SNAPSHOT_JSON=$2

    # otherwise, return whichever is younger
    PS_TIMESTAMP=$(echo $PUSH_SNAPSHOT_JSON | jq .metadata.creationTimestamp)
    OS_TIMESTAMP=$(echo $OVERRIDE_SNAPSHOT_JSON | jq .metadata.creationTimestamp)
    if [[ $OS_TIMESTAMP > $PS_TIMESTAMP ]]; then
        echo $OVERRIDE_SNAPSHOT_JSON
    fi
    echo $PUSH_SNAPSHOT_JSON
}

get_latest_override_snapshot_with_component() {
    COMPONENT=$1
    NAMESPACE=$2
    APPLICATION=$3

    SNAPSHOTS=$(kubectl get snapshots -n $NAMESPACE --sort-by .metadata.creationTimestamp --selector=pac.test.appstudio.openshift.io/type=override,appstudio.openshift.io/application=$APPLICATION --no-headers | tac | cut -d ' ' -f1)

    if ! [[ $SNAPSHOTS ]]; then
        return 0
    fi

    while read -r snapshot; do
        names=$(kubectl get -o json snapshot $snapshot -n $NAMESPACE | jq .spec.components[].name);
        if [[ $names =~ $COMPONENT ]]; then
            echo $snapshot
        fi
    done <<< $SNAPSHOTS
}

# gets the component container image from the latest push or override snapshot
# If the newest override snapshot 
get_image_from_latest_push_or_override_snapshot() {
    COMPONENT=$1
    NAMESPACE=$2

    APPLICATION=$(kubectl get component $COMPONENT -n $NAMESPACE -o json | jq -r .spec.application)

    LATEST_PUSH_SNAPSHOT=$(kubectl get snapshots -n $NAMESPACE --sort-by .metadata.creationTimestamp --selector=pac.test.appstudio.openshift.io/event-type=push,appstudio.openshift.io/application=$APPLICATION | tail -n 1 | cut -d ' ' -f1)
    LATEST_OVERRIDE_SNAPSHOT=$(get_latest_override_snapshot_with_component $COMPONENT $NAMESPACE $APPLICATION)

    SNAPSHOT_JSON=""
    if [[ $LATEST_PUSH_SNAPSHOT ]] && [[ $LATEST_OVERRIDE_SNAPSHOT ]]; then
        # if the application has push and override snapshots, do more work to determine which to use
        LATEST_PUSH_SNAPSHOT_JSON=$(kubectl get snapshot $LATEST_PUSH_SNAPSHOT -n $NAMESPACE -o json)
        LATEST_OVERRIDE_SNAPSHOT_JSON=$(kubectl get snapshot $LATEST_PUSH_SNAPSHOT -n $NAMESPACE -o json)
        SNAPSHOT_JSON=$(get_newest_snapshot_json $LATEST_PUSH_SNAPSHOT_JSON $LATEST_OVERRIDE_SNAPSHOT_JSON)
    else
        if [[ $LATEST_PUSH_SNAPSHOT ]]; then
            # if only the push snapshot exists use the push snapshot
            SNAPSHOT_JSON=$(kubectl get snapshot $LATEST_PUSH_SNAPSHOT -n $NAMESPACE -o json)
        elif [[ $LATEST_OVERRIDE_SNAPSHOT ]]; then
            # if only the override snapshot exists use the override snapshot
            SNAPSHOT_JSON=$(kubectl get snapshot $LATEST_OVERRIDE_SNAPSHOT -n $NAMESPACE -o json)
        else
            return 0
        fi
    fi

    # get image from snapshot
    IMAGE=$(echo $SNAPSHOT_JSON | jq --arg COMPONENT "$COMPONENT" '.spec.components[] | select (.name == $COMPONENT) | .containerImage')
    echo $IMAGE
}

migrate_fields() {
    COMPONENT=$1
    NAMESPACE=$2

    COMPONENT_JSON=$(kubectl get -o json component $COMPONENT -n $NAMESPACE)

    LAST_PROMOTED_IMAGE=$(echo $COMPONENT_JSON | jq .status.lastPromotedImage)

    #if [[ -n $LAST_PROMOTED_IMAGE && $LAST_PROMOTED_IMAGE -ne "null" ]]; then
    if [ "$LAST_PROMOTED_IMAGE" != "null" ]; then
        echo "components/${COMPONENT} in namespace ${NAMESPACE} already has status.lastPromotedImage"
        return 0
    fi
    
    IMAGE=$(echo $COMPONENT_JSON | jq .spec.containerImage)
    if [[ $IMAGE != *"sha256"* ]]; then
        echo "${IMAGE} does not contain sha256 digest.  Attempting to find matching promoted snapshot"
        IMAGE=$(get_image_from_latest_push_or_override_snapshot $COMPONENT $NAMESPACE)
        # if the image is an empty string then not matching snapshot was found
        if ! [[ $IMAGE ]]; then
            echo "Skipping component ${COMPONENT} in NAMESPACE ${NAMESPACE} with invalid spec.ContainerImage and no push or override snapshots"
            return 0
        fi
    fi

    # set spec.lastPromotedImage to spec.containerImage
    PATCH="{\"status\":{\"lastPromotedImage\":${IMAGE}}}"

    /usr/bin/kubectl patch component --dry-run=client $COMPONENT -p "$PATCH" --type merge --subresource status -n $NAMESPACE
}

ALL_COMPONENTS=$(kubectl get components  -o custom-columns=Name:.metadata.name,Namespace:.metadata.namespace --all-namespaces --no-headers)

while read -r line; do
    migrate_fields $line
done <<< $ALL_COMPONENTS
