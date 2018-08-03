#!/usr/bin/env bash
#
# bluegreen ami-style deploys (simple)
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/functions_dns.shlib"

set -E
trap 'throw_exception' ERR

params=()

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
bluegreen ami-style deploys

    -h            display this help and exit
    -a STRING     app ami id (required)
    -d STRING     HOSTED_ZONE_ID/NAME to update (external)
    -D STRING     HOSTED_ZONE_ID/NAME to update (internal)
    -g NUMBER     volume size (default: 8)
    -I STRING     instance type
    -n STRING     app name (default: app)
    -N STRING     base name (default: same as app-name)
    -p STRING     aws profile (required)
    -P STRING     additional params (key=value)
    -R STRING     aws region (defaults to profile setting)
    -s STRING     smoketesturl
    -t STRING     path to net cfn (required)
    -T STRING     path to app cfn (required)
    -X STRING     extra cfns (name:file)
EOF
}

delete_stack() {
  local delay="${3}"
  local payload="$(jq -nc \
    --arg profile "${AWS_PROFILE}" \
    --arg region "${AWS_REGION}" \
    --arg account_id "${1}" \
    --arg stack_name "${2}" \
    '
    {
      "profile": $profile,
      "region": $region,
      "account_id": $account_id|tonumber,
      "stack_name": $stack_name
    }
  ')"

  if [[ -z "${delay}" ]]; then
    delay="900"
  fi

  # hardcoded profile - alternatively jenkins-node role needs access back to sqs
  aws \
    --profile "wi" \
    --region "eu-west-2" \
    --output text \
    sqs send-message \
    --queue-url "https://sqs.eu-west-2.amazonaws.com/115832059178/stack-gc" \
    --message-body "${payload}" \
    --delay-seconds "${delay}"
}

OPTIND=1
while getopts "ha:d:D:g:I:n:N:p:P:R:s:t:T:X:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    a )
      APP_AMI_ID="${OPTARG}"
      ;;
    d )
      EXT_R53_HOSTED_ZONE_ID="${OPTARG%%/*}"
      EXT_R53_RECORD_NAME="${OPTARG#*/}"
      ;;
    D )
      INT_R53_HOSTED_ZONE_ID="${OPTARG%%/*}"
      INT_R53_RECORD_NAME="${OPTARG#*/}"
      ;;
    g )
      VOLUME_SIZE="${OPTARG}"
      ;;
    I )
      EC2_INSTANCE_TYPE="${OPTARG}"
      ;;
    n )
      APP_NAME="${OPTARG}"
      ;;
    N )
      BASE_NAME="${OPTARG}"
      ;;
    p )
      AWS_PROFILE="${OPTARG}"
      ;;
    P )
      params+=( "${OPTARG}" )
      ;;
    R )
      AWS_REGION="${OPTARG}"
      ;;
    s )
      SMOKE_TEST_URL="${OPTARG}"
      ;;
    t )
      CFN_NET="${OPTARG}"
      if [[ ! -f "${CFN_NET}" ]]; then
        consolelog "unable to open CFN_NET: ${CFN_NET}" "error"
        exit 1
      fi
      ;;
    T )
      CFN_APP="${OPTARG}"
      if [[ ! -f "${CFN_APP}" ]]; then
        consolelog "unable to open CFN_APP: ${CFN_APP}" "error"
        exit 1
      fi
      ;;
    X )
      if [[ -z "${XTRA_STACKS}" ]]; then
        XTRA_STACKS=()
      fi
      XTRA_STACKS+=( "${OPTARG}" )
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
  APP_AMI_ID \
  BUILD_NUMBER \
  CFN_NET \
  CFN_APP \
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

if [[ -z "${APP_NAME}" ]]; then
  APP_NAME=app
fi

if [[ -z "${BASE_NAME}" ]]; then
  BASE_NAME="${APP_NAME}"
fi

if [[ -z "${VOLUME_SIZE}" ]]; then
  VOLUME_SIZE=8
fi

account_id="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  sts get-caller-identity \
  --output text \
  --query 'Account')"

# 1) add ec2 keypair
if ! aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 describe-key-pairs \
  --key-names 'build-ami@wiGroup' &> /dev/null; then

  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --output text \
    ec2 import-key-pair \
    --key-name 'build-ami@wiGroup' \
    --public-key-material "$(cat "${__DIR__}/keypairs/build-ami.pub")" > /dev/null
fi

params+=( "AppNameParam=${APP_NAME}" )
params+=( "BaseNameParam=${BASE_NAME}" )

# 2) run network stack
net_stack_name="${BASE_NAME}-net"
consolelog "deploying network stack..."
if aws::cfn_has_changes "${net_stack_name}" "${CFN_NET}" "${params[@]}"; then
  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --output text \
    cloudformation deploy \
    --template-file "${CFN_NET}" \
    --stack-name "${net_stack_name}" \
    --parameter-overrides "${params[@]}"
fi

if [[ ! -z "${XTRA_STACKS}" ]]; then
  for xtra_stack in "${XTRA_STACKS[@]}"; do
    stack_name="${xtra_stack%%:*}"
    stack_file="${xtra_stack#*:}"

    if [[ ! -f "${stack_file}" ]]; then
      consolelog "ERROR! Unable to open: ${stack_file}" "error"
      exit 1
    fi

    consolelog "deploying ${stack_name} stack..."
    if aws::cfn_has_changes "${stack_name}" "${stack_file}" "${params[@]}"; then
      aws \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" \
        --output text \
        cloudformation deploy \
        --template-file "${stack_file}" \
        --stack-name "${stack_name}" \
        --parameter-overrides "${params[@]}"
    fi
  done
fi

# prepare params
params+=( "AppImageIdParam=${APP_AMI_ID}" )

if [[ ! -z "${EC2_INSTANCE_TYPE}" ]]; then
  params+=( "AppInstanceTypeParam=${EC2_INSTANCE_TYPE}" )
fi
params+=( "AppVolumeSizeParam=${VOLUME_SIZE}" )

# 2) create app stack + poll
blue_stack_name="${APP_NAME}-env-${BUILD_NUMBER}"
consolelog "creating blue-env [${blue_stack_name}]..."
if ! aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  cloudformation deploy \
  --template-file "${CFN_APP}" \
  --stack-name "${blue_stack_name}" \
  --parameter-overrides "${params[@]}"; then
  consolelog "ERROR: blue-env failed!" "error"
  exit 1
fi

# fetch blue env info
consolelog "querying blue-env [${blue_stack_name}]..."
stack_values=( $(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation describe-stacks \
  --stack-name "${blue_stack_name}" \
  | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

if [[ -z "${stack_values}" ]]; then
  consolelog "ERROR: unable to fetch blue-env stack info!" "error"
  exit 1
fi

for stack_value in "${stack_values[@]}"; do
  k="${stack_value%%=*}"
  v="${stack_value#*=}"

  if [[ "${k}" == "app-lb-name" ]]; then
    blue_lb_name="${v}"
  fi

  if [[ "${k}" == "app-lb-name-int" ]]; then
    blue_lb_name_int="${v}"
  fi

  if [[ "${k}" == "app-lb-dns" ]]; then
    blue_lb_dns="${v}"
  fi

  if [[ "${k}" == "app-lb-dns-int" ]]; then
    blue_lb_dns_int="${v}"
  fi
done

# (optionally) poll until elb is healthy
if [[ ! -z "${blue_lb_name}" ]]; then
  aws::poll_elb "${blue_lb_name}"
fi

if [[ ! -z "${blue_lb_name_int}" ]]; then
  aws::poll_elb "${blue_lb_name_int}"
fi

# SMOKE_TEST_URL
if [[ ! -z "${SMOKE_TEST_URL}" ]]; then
  consolelog "smoketesting ${SMOKE_TEST_URL} against ${blue_lb_dns}"
  sleep 10
  while [[ "${i}" -lt "60" ]]; do
    i="$((i + 1))"
    if ! curl \
      --head \
      --silent \
      --fail \
      --show-error \
      --header "Host: ${SMOKE_TEST_URL}" \
      "${blue_lb_dns}" > /dev/null; then
      echo -n '.'
      sleep 5
    else
      success="1"
      break
    fi
  done
  echo ''

  if [[ -z "${success}" ]]; then
    delete_stack "${account_id}" "${blue_stack_name}" "900"
    consolelog "ERROR: smoketest failed!" "error"
    exit 1
  fi
fi

# 3) (optionall) swap out dns record via route53
if [[ ! -z "${EXT_R53_HOSTED_ZONE_ID}" ]] && [[ ! -z "${EXT_R53_RECORD_NAME}" ]]; then
  consolelog "swapping dns record (external) with: ${blue_lb_dns}"
  dns::upsert_record "${EXT_R53_HOSTED_ZONE_ID}" "${EXT_R53_RECORD_NAME}" "CNAME" "120" "${blue_lb_dns}"
fi

if [[ ! -z "${INT_R53_HOSTED_ZONE_ID}" ]] && [[ ! -z "${INT_R53_RECORD_NAME}" ]]; then
  consolelog "swapping dns record (internal) with: ${blue_lb_dns_int}"
  dns::upsert_record "${INT_R53_HOSTED_ZONE_ID}" "${INT_R53_RECORD_NAME}" "CNAME" "120" "${blue_lb_dns_int}"
fi

# 4) tag old stack for deletion
consolelog "tagging old stacks for deletion..."
if ! res="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE)"; then
  consolelog "ERROR: unable to list-stacks" "error"
  exit 1
fi

for stack in $(echo "${res}" | jq -r '.StackSummaries[] | @base64'); do
  stack_name="$(_jq "${stack}" ".StackName")"

  # skip current stack
  if [[ "${stack_name}" == "${blue_stack_name}" ]]; then
    continue
  fi

  # delete any other existing stack after 900 seconds
  if [[ "${stack_name}" == "${APP_NAME}-env-"* ]]; then
    delete_stack "${account_id}" "${stack_name}" "900"
  fi
done
