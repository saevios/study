#!/usr/bin/env bash
#
# get latest build number
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_jenkins.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
get latest build number

    -h            display this help and exit
    -J STRING     source job-name (folder/project, required)
EOF
}

OPTIND=1
while getopts "hJ:n:p:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    J )
      SOURCE_JOB_NAME="${OPTARG}"
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
  SOURCE_JOB_NAME \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

jenkins::last_build "${SOURCE_JOB_NAME}"
