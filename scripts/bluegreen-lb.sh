#!/usr/bin/env bash
#
# bluegreen multi-service loadbalancer
#

readlink_bin="${READLINK_PATH:-readlink}"
if ! "${readlink_bin}" -f test &> /dev/null; then
  __DIR__="$(dirname "$("${readlink_bin}" "${0}")")"
else
  __DIR__="$(dirname "$("${readlink_bin}" -f "${0}")")"
fi

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/functions_dns.shlib"
source "${__DIR__}/libs/tpl.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
bluegreen multi-service loadbalancer

    -h            display this help and exit
    -d STRING     HOSTED_ZONE_ID/NAME to update (external)
    -D STRING     HOSTED_ZONE_ID/NAME to update (internal)
    -l STRING     listener spec (lb_port;instance_port;stack_name;check_path) (external)
    -L STRING     listener spec (lb_port;instance_port;stack_name;check_path) (internal)
    -N STRING     base name (default: app)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
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
while getopts "hd:D:l:L:N:p:R:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    d )
      EXT_R53_HOSTED_ZONE_ID="${OPTARG%%/*}"
      EXT_R53_RECORD_NAME="${OPTARG#*/}"
      ;;
    D )
      INT_R53_HOSTED_ZONE_ID="${OPTARG%%/*}"
      INT_R53_RECORD_NAME="${OPTARG#*/}"
      ;;
    l )
      if [[ -z "${EXT_LISTENERS}" ]]; then
        EXT_LISTENERS=()
      fi
      EXT_LISTENERS+=( "${OPTARG}" )
      ;;
    L )
      if [[ -z "${INT_LISTENERS}" ]]; then
        INT_LISTENERS=()
      fi
      INT_LISTENERS+=( "${OPTARG}" )
      ;;
    N )
      BASE_NAME="${OPTARG}"
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
  BUILD_NUMBER \
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

if [[ -z "${BASE_NAME}" ]]; then
  BASE_NAME=app
fi

account_id="$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  sts get-caller-identity \
  --output text \
  --query 'Account')"

consolelog "creating loadbalancer cfn..."

num="0"
ext_listener_resources=()
ext_targetgroup_resources=()
ext_targetgroup_output_resources=()

for listener in "${EXT_LISTENERS[@]}"; do
  listener_split=(${listener//;/ })
  lb_port="${listener_split[0]}"
  instance_port="${listener_split[1]}"
  stack_name="${listener_split[2]}"
  check_path="${listener_split[3]}"
  num=$((num + 1))

  ext_targetgroup_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-targetgroup-staging-ext.yml")" )
  ext_targetgroup_output_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-targetgroup-output-staging-ext.yml")" )

  # has ssl
  if [[ ! -z "${listener_split[4]}" ]]; then
    cert_arn="${listener_split[4]}"
    ext_listener_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-ssl-listener-staging-ext.yml")" )
  else
    ext_listener_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-listener-staging-ext.yml")" )
  fi
done

ext_listener_resource="$(implode "
" "${ext_listener_resources[@]}")"

ext_targetgroup_resource="$(implode "
" "${ext_targetgroup_resources[@]}")"

ext_targetgroup_output_resource="$(implode "
" "${ext_targetgroup_output_resources[@]}")"

num="0"
int_listener_resources=()
int_targetgroup_resources=()
int_targetgroup_output_resources=()

for listener in "${INT_LISTENERS[@]}"; do
  listener_split=(${listener//;/ })
  lb_port="${listener_split[0]}"
  instance_port="${listener_split[1]}"
  stack_name="${listener_split[2]}"
  check_path="${listener_split[3]}"
  num=$((num + 1))

  int_targetgroup_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-targetgroup-staging-int.yml")" )
  int_targetgroup_output_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-targetgroup-output-staging-int.yml")" )

  # has ssl
  if [[ ! -z "${listener_split[4]}" ]]; then
    cert_arn="${listener_split[4]}"
    int_listener_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-ssl-listener-staging-int.yml")" )
  else
    int_listener_resources+=( "$(tpl::render "${__DIR__}/templates/legacy-lb-listener-staging-int.yml")" )
  fi
done

int_listener_resource="$(implode "
" "${int_listener_resources[@]}")"

int_targetgroup_resource="$(implode "
" "${int_targetgroup_resources[@]}")"

int_targetgroup_output_resource="$(implode "
" "${int_targetgroup_output_resources[@]}")"

tpl::render "${__DIR__}/templates/legacy-lb-staging.yml" > legacy-lb-staging.yml

params=()
params+=( "BaseNameParam=${BASE_NAME}" )

net_stack_name="${BASE_NAME}-net"
consolelog "fetching network stack info..."
stack_values=( $(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation describe-stacks \
  --stack-name "${net_stack_name}" \
  | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

if [[ -z "${stack_values}" ]]; then
  consolelog "ERROR: unable to fetch network stack info!" "error"
  exit 1
fi

# create app stack
blue_stack_name="${BASE_NAME}-lb-${BUILD_NUMBER}"
consolelog "creating blue-lb [${blue_stack_name}]..."
if ! aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  cloudformation deploy \
  --template-file "legacy-lb-staging.yml" \
  --stack-name "${blue_stack_name}" \
  --parameter-overrides "${params[@]}"; then
  consolelog "ERROR: blue-env failed!" "error"
  exit 1
fi

consolelog "querying blue-lb [${blue_stack_name}]..."
stack_values=( $(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation describe-stacks \
  --stack-name "${blue_stack_name}" \
  | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

if [[ -z "${stack_values}" ]]; then
  consolelog "ERROR: unable to fetch blue-lb stack info!" "error"
  exit 1
fi

created_target_groups_ext=()
created_target_groups_int=()
for stack_value in "${stack_values[@]}"; do
  k="${stack_value%%=*}"
  v="${stack_value#*=}"

  if [[ "${k}" == "lb-external-name" ]]; then
    blue_lb_external_name="${v}"
  fi

  if [[ "${k}" == "lb-external-dns" ]]; then
    blue_lb_external_dns="${v}"
  fi

  if [[ "${k}" == "lb-internal-name" ]]; then
    blue_lb_internal_name="${v}"
  fi

  if [[ "${k}" == "lb-internal-dns" ]]; then
    blue_lb_internal_dns="${v}"
  fi

  if [[ "${k}" == lb-targetgroup-ext-* ]]; then
    created_target_groups_ext["${k##*-}"]="${v}"
  fi

  if [[ "${k}" == lb-targetgroup-int-* ]]; then
    created_target_groups_int["${k##*-}"]="${v}"
  fi
done

if [[ -z "${created_target_groups_ext[@]}" ]] && [[ -z "${created_target_groups_int[@]}" ]]; then
  consolelog "unable to get created_target_groups" "error"
  exit 1
fi

# linking asg with target groups
num=1
for listener in "${EXT_LISTENERS[@]}"; do
  listener_split=(${listener//;/ })
  stack_name="${listener_split[2]}"

  # resolve stack_name to asg_name
  stack_values=( $(aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --output json \
    cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

  if [[ -z "${stack_values}" ]]; then
    consolelog "ERROR: unable to fetch ${stack_name} stack info!" "error"
    exit 1
  fi

  for stack_value in "${stack_values[@]}"; do
    k="${stack_value%%=*}"
    v="${stack_value#*=}"

    if [[ "${k}" == "app-asg-name" ]]; then
      asg_name="${v}"
    fi
  done

  if [[ -z "${asg_name}" ]]; then
    consolelog "unable to fetch asg_name" "error"
    exit 1
  fi

  consolelog "linking #${num} ${created_target_groups_ext[${num}]} with ${asg_name}..."

  # attach target group to asg
  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    autoscaling attach-load-balancer-target-groups \
    --auto-scaling-group-name "${asg_name}" \
    --target-group-arns "${created_target_groups_ext[${num}]}"

  num=$((num + 1))
done

num=1
for listener in "${INT_LISTENERS[@]}"; do
  listener_split=(${listener//;/ })
  stack_name="${listener_split[2]}"

  # resolve stack_name to asg_name
  stack_values=( $(aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --output json \
    cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

  if [[ -z "${stack_values}" ]]; then
    consolelog "ERROR: unable to fetch ${stack_name} stack info!" "error"
    exit 1
  fi

  for stack_value in "${stack_values[@]}"; do
    k="${stack_value%%=*}"
    v="${stack_value#*=}"

    if [[ "${k}" == "app-asg-name" ]]; then
      asg_name="${v}"
    fi
  done

  if [[ -z "${asg_name}" ]]; then
    consolelog "unable to fetch asg_name" "error"
    exit 1
  fi

  consolelog "linking #${num} ${created_target_groups_ext[${num}]} with ${asg_name}..."

  # attach target group to asg
  aws \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    autoscaling attach-load-balancer-target-groups \
    --auto-scaling-group-name "${asg_name}" \
    --target-group-arns "${created_target_groups_int[${num}]}"

  num=$((num + 1))
done

for target_group in "${created_target_groups_ext[@]}"; do
  consolelog "polling ${target_group}..."
  aws::poll_targetgroup "${target_group}"
done
for target_group in "${created_target_groups_int[@]}"; do
  consolelog "polling ${target_group}..."
  aws::poll_targetgroup "${target_group}"
done

consolelog "swapping dns records..."
dns::upsert_record "${EXT_R53_HOSTED_ZONE_ID}" "${EXT_R53_RECORD_NAME}" "CNAME" "120" "${blue_lb_external_dns}"
dns::upsert_record "${INT_R53_HOSTED_ZONE_ID}" "${INT_R53_RECORD_NAME}" "CNAME" "120" "${blue_lb_internal_dns}"

# tag old stack for deletion
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
  if [[ "${stack_name}" == "${BASE_NAME}-lb-"* ]]; then
    delete_stack "${account_id}" "${stack_name}" "900"
  fi
done
