#!/usr/bin/env bash
#
# cross region ami copy
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
cross region ami copy

    -h            display this help and exit
    -f STRING     source ami id (required)
    -F STRING     source region (required)
    -n STRING     ami name (required)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
    -S STRING     list of accounts to grant access
EOF
}

OPTIND=1
while getopts "hf:F:n:p:R:S:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    f )
      SOURCE_AMI_ID="${OPTARG}"
      ;;
    F )
      SOURCE_REGION="${OPTARG}"
      ;;
    n )
      AMI_NAME="${OPTARG}"
      ;;
    p )
      AWS_PROFILE="${OPTARG}"
      ;;
    R )
      AWS_REGION="${OPTARG}"
      ;;
    S )
      if [[ -z "${SHARE_ACCOUNTS}" ]]; then
        SHARE_ACCOUNTS=()
      fi
      SHARE_ACCOUNTS+=( "${OPTARG}" )
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
  AMI_NAME \
  SOURCE_AMI_ID \
  SOURCE_REGION \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

# auto-resolve aws-region
if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="eu-west-1"
  fi
fi

consolelog "copying ami from ${SOURCE_REGION} to ${AWS_REGION}..."
copied_ami_id="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 copy-image \
  --source-image-id "${SOURCE_AMI_ID}" \
  --source-region "${SOURCE_REGION}" \
  --name "${AMI_NAME}")"

aws::tag_ec2 "${copied_ami_id}" "Key=Name,Value=${AMI_NAME}"
aws::poll_ami "${copied_ami_id}"

if [[ ! -z "${SHARE_ACCOUNTS}" ]]; then
  consolelog "share with accounts:"
  for acc_id in "${SHARE_ACCOUNTS[@]}"; do
    consolelog "* ${acc_id}"
    aws \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      ec2 modify-image-attribute \
      --image-id "${copied_ami_id}" \
      --launch-permission "{\"Add\":[{\"UserId\":\"${acc_id}\"}]}"
  done
fi

consolelog "done!" "success"
