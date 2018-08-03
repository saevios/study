#!/usr/bin/env bash
#
# purge older ebs snapshots
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/functions_variables.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS VOLUME_ID
purge older ebs snapshots

    -h            display this help and exit
    -N NUMBER     number of backups to keep (default: 30)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
EOF
}

OPTIND=1
while getopts "hN:p:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    n )
      NUM_BACKUPS="${OPTARG}"
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
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="eu-west-1"
  fi
fi

if [[ -z "${1}" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "${NUM_BACKUPS}" ]] || ! variables::ctype_digit "${NUM_BACKUPS}"; then
  NUM_BACKUPS=30
fi

n=0

# get list of snapshots according by volume-id
aws --profile "${AWS_PROFILE}" --output text --region "${AWS_REGION}" ec2 describe-snapshots --filters "Name=volume-id,Values=${1}" |
# we are only interested in the snapshot results (and ignore the name <> tags results)
grep -i snapshots |
# sort by (and only by) the sixt column in reverse (eg by date) where "<tab>" is the column delimiter
sort -k7,7r -t$'\t' |
# read each colum into a variable
while IFS=$'\t' read -r snapshots description encrypted owner_id progress snapshot_id start_time state volume_id volume_size; do
  n=$((n + 1))

  # delete older snapshots after the desired amount is reached
  if [[ "${n}" -gt "${NUM_BACKUPS}" ]]; then
    consolelog "deleted snapshot: ${description}" "error"
    aws \
      --profile "${AWS_PROFILE}" \
      --output text \
      --region "${AWS_REGION}" \
      ec2 delete-snapshot \
      --snapshot-id "${snapshot_id}"
  fi
done
