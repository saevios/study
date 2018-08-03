#!/usr/bin/env bash
#
# create app ami
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/tpl.shlib"

cleanup_ec2=1

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
create app ami

    -h            display this help and exit
    -a STRING     build ami id (required)
    -A STRING     s3 url to artefact (required)
    -d STRING     user-data file (required)
    -E STRING     env prefix
    -F STRING     flavour [debian/ubuntu] (default: ubuntu)
    -g NUMBER     storage size in gb (default: 8gb)
    -n STRING     app ami name (required)
    -p STRING     aws profile (required)
    -R STRING     aws region (defaults to profile setting)
    -S STRING     list of accounts to grant access
EOF
}

OPTIND=1
while getopts "ha:A:d:E:F:g:n:m:p:R:S:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    a )
      BUILD_AMI_ID="${OPTARG}"
      ;;
    A )
      APP_ARTEFACT="${OPTARG}"
      ;;
    d )
      USER_DATA_FILE="${OPTARG}"
      if [[ ! -f "${USER_DATA_FILE}" ]]; then
        consolelog "unable to read file: ${USER_DATA_FILE}" "error"
        exit 1
      fi
      ;;
    E )
      ENV_PREFIX="${OPTARG}"
      ;;
    F )
      FLAVOUR="${OPTARG}"
      ;;
    g )
      AWS_EBS_SIZE="${OPTARG}"
      ;;
    n )
      APP_AMI_BASENAME="${OPTARG}"
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
  BUILD_AMI_ID \
  APP_ARTEFACT \
  USER_DATA_FILE \
  AWS_PROFILE \
  APP_AMI_BASENAME \
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

if [[ -z "${AWS_EBS_SIZE}" ]]; then
  AWS_EBS_SIZE="8"
fi

if [[ -z "${FLAVOUR}" ]]; then
  FLAVOUR="ubuntu"
fi

case "${FLAVOUR}" in
  debian )
    if [[ -z "${SSH_USER}" ]]; then
      EC2_ROOT_DEVICE="/dev/xvda"
    fi
    ;;

  ubuntu )
    if [[ -z "${SSH_USER}" ]]; then
      EC2_ROOT_DEVICE="/dev/sda1"
    fi
    ;;

  * )
    consolelog "unknown flavour..." "error"
    usage
    exit 1
    ;;
esac

consolelog "fetching instance-profile arn..."
if ! instance_profile_arn="$(aws::ref_instance_profile "build-ami")"; then
  consolelog "ERROR: unable to find build-ami instance-profile" "error"
  exit 1
fi

# fetch stack values
consolelog "fetching stack info..."
stack_values=( $(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation describe-stacks \
  --stack-name build-ami \
  | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

if [[ -z "${stack_values}" ]]; then
  consolelog "ERROR: unable to retrieve stack info" "error"
  exit 1
fi

AWS_SGROUPS=()
for stack_value in "${stack_values[@]}"; do
  k="${stack_value%%=*}"
  v="${stack_value#*=}"

  if [[ "${k}" == ssh-* ]]; then
    AWS_SGROUPS+=( "${v}" )
  fi

  if [[ "${k}" == "subnet-b" ]]; then
    AWS_SUBNET_ID="${v}"
  fi
done

# generate app-name
app_ami_name="${APP_AMI_BASENAME}"
if [[ ! -z "${APP_BUILD_NUMBER}" ]]; then
  app_ami_name="${app_ami_name}-b${APP_BUILD_NUMBER}x${BUILD_NUMBER}y"
fi
app_ami_desc="${app_ami_name} [$(date)]"

if [[ ! -z "${ENV_PREFIX}" ]]; then
  app_env_prefix="${ENV_PREFIX}"
else
  app_env_prefix="${APP_AMI_BASENAME/-//}"
fi

consolelog "launching ec2 off build-ami-id..."
ec2_id=$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 run-instances \
  --user-data "$(tpl::render "${USER_DATA_FILE}")" \
  --image-id "${BUILD_AMI_ID}" \
  --key-name "build-ami@wiGroup" \
  --security-group-ids "${AWS_SGROUPS[@]}" \
  --instance-type c4.large \
  --block-device-mappings "[{\"DeviceName\":\"${EC2_ROOT_DEVICE}\",\"Ebs\":{\"VolumeSize\":${AWS_EBS_SIZE},\"DeleteOnTermination\":true,\"VolumeType\":\"gp2\"}}]" \
  --subnet-id "${AWS_SUBNET_ID}" \
  --iam-instance-profile "Arn=${instance_profile_arn}" \
  --associate-public-ip-address | grep -m1 INSTANCES | cut -f8)

if [[ -z "${ec2_id}" ]]; then
  consolelog "ERROR: unable to retrieve ec2_id" "error"
  exit 1
fi

sleep 60
aws::poll_ec2 "${ec2_id}" "stopped"
sleep 30

consolelog "creating ami..."
if ! ami_id="$(aws::ami_create "${ec2_id}" "${app_ami_name}" "${app_ami_desc}")"; then
  aws::del_ec2 "${ec2_id}"
  consolelog "ERROR: unable to create ami" "error"
  exit 1
fi

aws::tag_ec2 "${ami_id}" "Key=Name,Value=${app_ami_name}"
aws::poll_ami "${ami_id}"

# 6) delete instance
consolelog "deleting build ec2 instance"
aws::del_ec2 "${ec2_id}"

if [[ ! -z "${SHARE_ACCOUNTS}" ]]; then
  consolelog "sharing with accounts:"
  for acc_id in "${SHARE_ACCOUNTS[@]}"; do
    consolelog "* ${acc_id}"
    aws::ami_share "${ami_id}" "${acc_id}"
  done
fi

if [[ ! -z "${JENKINS_HOME}" ]]; then
  echo "APP_AMI_ID=${ami_id}" >> propsfile
fi
consolelog "done!" "success"
