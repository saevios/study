#!/usr/bin/env bash
#
# envwars tool
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS export|import STDOUT|STDIN
envwars tool

    -h            display this help and exit
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
EOF
}

env_encode() {
  local key="${1#/}"
  echo "${key//\//_}" | tr '[:lower:]' '[:upper:]'
}

env_decode() {
  local key="${1%%=*}"
  local val="${1#*=}"
  echo "/${key//_//}" | tr '[:upper:]' '[:lower:]'
  echo "${val}"
}

OPTIND=1
while getopts "hp:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
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

case "${1}" in
  export )
    while read -r k v; do
      echo "$(env_encode "${k}")=${v}"
    done < <(aws \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --output json \
      dynamodb scan \
      --table-name envwars | jq -r '.Items[] | "\(.key.S)\t\(.value.S)"')
    ;;

  import )
    while IFS='' read -r line || [[ -n "${line}" ]]; do
      if [[ -z "${line}" ]]; then
        continue
      fi

      keyvalue=( $(env_decode "${line}") )

      if [[ -z "${keyvalue[1]}" ]]; then
        consolelog "deleting ${keyvalue[0]}..." "error"
        aws \
          --profile "${AWS_PROFILE}" \
          --region "${AWS_REGION}" \
          --output text \
          dynamodb delete-item \
          --table-name envwars \
          --key "$(jq -nc --arg key "${keyvalue[0]}" '{"key": {"S": $key}}')"
      else
        consolelog "upserting ${keyvalue[0]} with '${keyvalue[1]}'..." "success"
        aws \
          --profile "${AWS_PROFILE}" \
          --region "${AWS_REGION}" \
          --output text \
          dynamodb put-item \
          --table-name envwars \
          --item "$(jq -nc --arg key "${keyvalue[0]}" --arg val "${keyvalue[1]}" '{"key": {"S": $key}, "value": {"S": $val}}')"
      fi
    done < "${2:-/dev/stdin}"
    ;;
esac
