#!/bin/bash

# The action runs this file from the action's own checkout on top of the
# published ghcr.io/project-copacetic/copa-action:v<copa version> image (see
# action.yaml), so it must keep working with every published image. Use only
# bash, coreutils and the docker CLI; docker buildx exists only in images built
# after February 2024.

set -ex;

image=$1
report=$2
patched_tag=$3
timeout=$4
connection_format=$5
format=$6
output_file=$7
max_retries=${8:-0}

# multi-platform options, passed as environment variables so that the
# positional arguments stay compatible with earlier releases
platform="${COPA_PLATFORM:-}"
push="${COPA_PUSH:-false}"
oci_dir="${COPA_OCI_DIR:-}"

# check if output_file has been set
if [ -z "$output_file" ]
then
    output=""
else
    output="--format $format --output ./data/$output_file"
fi

# check selected method of buildkit connection
case "$connection_format" in
    # through a buildx instance
    "buildx")
        docker buildx create --name=copa-action
        docker buildx use --default copa-action
        connection="--addr buildx://copa-action"
    ;;
    # through a running buildkit container over tcp
    "buildkit-container")
        connection="--addr tcp://127.0.0.1:8888"
    ;;
    # through the default docker buildkit endpoint enabled with a custom socket
    "custom-socket")
        connection=""
    ;;
esac

# build the optional copa arguments
report_args=()
if [ -n "$report" ]
then
    report_args=(-r "./data/$report")
fi

extra_args=()
if [ -n "$platform" ]
then
    extra_args+=(--platform "$platform")
fi
if [ "$push" = "true" ]
then
    extra_args+=(--push)
fi
if [ -n "$oci_dir" ]
then
    extra_args+=(--oci-dir "./data/$oci_dir")
fi

# resolve the reference of the patched image (or index) the way copa names it
if [[ "$patched_tag" == *:* ]] || [[ "$patched_tag" == *@* ]]
then
    # patched-tag is a full image reference
    patched_image="${patched_tag%%@*}"
else
    image_name="${image%%@*}"
    if [[ "${image_name##*/}" == *:* ]]
    then
        image_name="${image_name%:*}"
    fi
    patched_image="$image_name:$patched_tag"
fi

# without push or oci-dir, a multi-platform result is only loaded into docker
# as one image per platform (<patched-image>-<arch>), with no image under the
# patched reference itself
may_be_multi_platform=false
if [ "$push" != "true" ] && [ -z "$oci_dir" ]
then
    if [ -z "$report" ] || [ -d "./data/$report" ] || [ -n "$platform" ]
    then
        may_be_multi_platform=true
        echo "::warning::patched-image may be empty: if $image is a multi-platform image, Copa loads each patched platform into Docker as a separate <patched-image>-<arch> image instead of one image. Set push or oci-dir to keep a multi-platform result as one image."
    fi
fi

patch_image() {
if copa patch -i "$image" "${report_args[@]}" -t "$patched_tag" $connection --timeout $timeout $output "${extra_args[@]}"
    then
        if [ "$may_be_multi_platform" = "true" ] && ! docker image inspect "$patched_image" > /dev/null 2>&1
        then
            echo "::warning::Copa did not load a single image named $patched_image, so patched-image is empty."
            echo "patched-image=" >> "$GITHUB_OUTPUT"
        else
            echo "patched-image=$patched_image" >> "$GITHUB_OUTPUT"
        fi
        return 0
    else
        return 1
    fi
}

# run copa to patch image
if [ "$max_retries" -eq 0 ]
then
    if ! patch_image
    then
        echo "Error patching image $image with copa"
        exit 1
    fi
else
    retries=0
    while [ "$retries" -lt "$max_retries" ]
    do
        if patch_image
        then
            break
        else
            retries=$((retries + 1))
            if [ "$retries" -eq "$max_retries" ]
            then
                echo "Error patching image $image with copa"
                exit 1
            else
                echo "WARNING: Attempt $retries failed. Retrying..."
            fi
        fi
    done
fi
