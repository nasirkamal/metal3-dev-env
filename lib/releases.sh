#!/bin/bash

function get_latest_release() {
  set +x
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    release="$(curl -sL "${1}")" || ( set -x && exit 1 )
  else
    release="$(curl -H "Authorization: token ${GITHUB_TOKEN}" -sL "${1}")" || ( set -x && exit 1 )
  fi
  # This gets the latest release as vx.y.z , ignoring any version with a suffix starting with - , for example -rc0
  release_tag="$(echo "$release" | jq -r "[.[].tag_name | select( startswith(\"${2:-""}\")) | select(contains(\"-\")==false)] | max ")"
  if [[ "$release_tag" == "null" ]]; then
    set -x
    exit 1
  fi
  set -x
  # shellcheck disable=SC2005
  echo "$release_tag"
}


CAPM3RELEASEPATH="${CAPM3RELEASEPATH:-https://api.github.com/repos/${CAPM3_BASE_URL}/releases}"
CAPIRELEASEPATH="${CAPIRELEASEPATH:-https://api.github.com/repos/${CAPI_BASE_URL}/releases}"

if [ "${CAPM3_VERSION}" == "v1alpha4" ]; then
  export CAPM3RELEASE="${CAPM3RELEASE:-$(get_latest_release "${CAPM3RELEASEPATH}" "v0.4.")}"
  export CAPIRELEASE="${CAPIRELEASE:-$(get_latest_release "${CAPIRELEASEPATH}" "v0.3.")}"
  CAPIBRANCH="${CAPIBRANCH:-${CAPIRELEASE}}"

else
  export CAPM3RELEASE="${CAPM3RELEASE:-$(get_latest_release "${CAPM3RELEASEPATH}" "v0.3.")}"
  export CAPIRELEASE="${CAPIRELEASE:-$(get_latest_release "${CAPIRELEASEPATH}" "v0.3.")}"
  CAPIBRANCH="${CAPIBRANCH:-${CAPIRELEASE}}"
fi

# On first iteration, jq might not be installed
if [[ "$CAPIRELEASE" == "" ]]; then
  command -v jq &> /dev/null && echo "Failed to fetch CAPI release from Github" && exit 1
fi

if [[ "$CAPM3RELEASE" == "" ]]; then
  command -v jq &> /dev/null && echo "Failed to fetch CAPM3 release from Github" && exit 1
fi