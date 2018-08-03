#!/usr/bin/env bash
#
# get latest build ami
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/functions_jenkins.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
get latest build ami

    -h            display this help and exit
    -J STRING     source job-name (folder/project, required)
    -n STRING     ami name (required)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
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
    n )
      AMI_BASENAME="${OPTARG}"
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
  AMI_BASENAME \
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

# auto-resolve aws-region
if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="eu-west-1"
  fi
fi

last_ami_build="$(jenkins::last_build "${SOURCE_JOB_NAME}")"
if [[ -z "${last_ami_build}" ]]; then
  consolelog "unable to find last_ami_build" "error"
  exit 1
else
  ami_name="${AMI_BASENAME}-b${last_ami_build}x"
  consolelog "searching for: ${ami_name}..."
fi

if ! res="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  ec2 describe-images \
  --filters "Name=name,Values=${ami_name}" \
  --owners self)"; then
  consolelog "unable to find the ami" "error"
  exit 1
fi

for image in $(echo "${res}" | jq -r '.Images[] | @base64'); do
  if [[ "$(_jq "${image}" ".Name")" == "${ami_name}" ]]; then
    ami_id="$(_jq "${image}" ".ImageId")"
    break
  fi
done

if [[ -z "${ami_id}" ]]; then
  echo "${res}"
  consolelog "unable to find ami" "error"
  exit 1
fi

if [[ ! -z "${JENKINS_HOME}" ]]; then
  echo "BUILD_AMI_ID=${ami_id}" >> propsfile
fi

consolelog "found: ${ami_id}" "success"
