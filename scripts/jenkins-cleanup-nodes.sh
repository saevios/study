#!/usr/bin/env bash

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_jenkins.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
delete stale/offline nodes

    -h            display this help and exit
EOF
}

OPTIND=1
while getopts "h" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

required_vars=( \
  JENKINS_URL \
  JENKINS_AUTH \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

computers=( $(curl \
  --retry 3 \
  --fail \
  --show-error \
  --silent \
  --user "${JENKINS_AUTH}" \
  "${JENKINS_URL}computer/api/json" | jq -r '.computer[] | @base64') )

for computer in "${computers[@]}"; do
  computer="$(_jq "${computer}")"

  computer_name="$(echo "${computer}" | jq -j '.displayName')"
  if [[ "${computer_name}" == "master" ]]; then
    continue
  fi

  if jenkins::computer_is_offline "${computer}" && [[ "$(echo "${computer}" | jq -j '.offlineCauseReason')" == "Time out for last 5 try" ]]; then
    consolelog "deleting offline computer: ${computer_name}" "error"
    jenkins::computer_delete "${computer_name}"
  fi
done
