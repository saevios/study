#!/usr/bin/env bash
#
# add pubkey to aws
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
add pubkey to aws

    -h            display this help and exit
    -f STRING     path to pubkey (required)
    -n STRING     name of keypair (required)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
EOF
}

OPTIND=1
while getopts "hf:n:p:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    f )
      PUBKEY_FILE="${OPTARG}"
      ;;
    n )
      KEYPAIR_NAME="${OPTARG}"
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
  PUBKEY_FILE \
  KEYPAIR_NAME \
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

if ! aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 describe-key-pairs \
  --key-names "${KEYPAIR_NAME}" &> /dev/null; then

  consolelog 'adding key...'
  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --output text \
    ec2 import-key-pair \
    --key-name "${KEYPAIR_NAME}" \
    --public-key-material "$(cat "${PUBKEY_FILE}")" > /dev/null
else
  consolelog 'key already added' 'success'
fi
