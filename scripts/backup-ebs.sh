#!/usr/bin/env bash
#
# create ebs snapshots
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS VOLUME_ID
create ebs snapshots

    -h            display this help and exit
    -m STRING     snapshot description
    -n STRING     snapshot name (required)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
EOF
}

OPTIND=1
while getopts "hm:n:p:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    m )
      SNAPSHOT_DESCRIPTION="${OPTARG}"
      ;;
    n )
      SNAPSHOT_NAME="${OPTARG}"
      ;;
    p )
      AWS_PROFILE="${OPTARG}"
      ;;
    R )
      AWS_REGION="${OPTARG}"
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

required_vars=( \
  AWS_PROFILE \
  SNAPSHOT_NAME \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

if [[ -z "${1}" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
fi

if [[ -z "${SNAPSHOT_DESCRIPTION}" ]]; then
  SNAPSHOT_DESCRIPTION="${SNAPSHOT_NAME} [$(date)]"
fi

ret="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  ec2 create-snapshot \
  --description "${SNAPSHOT_DESCRIPTION}" \
  --volume-id "${1}")"

snapshot_id="$(echo "${ret}" | jq -r '.SnapshotId')"
consolelog "created snapshot: ${snapshot_id}" "success"

aws::tag_ec2 "${snapshot_id}" "Key=Name,Value=${SNAPSHOT_NAME}"
