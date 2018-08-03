#!/usr/bin/env bash
#
# build ami based on ansible playbooks
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"
source "${__DIR__}/libs/functions_aws.shlib"
source "${__DIR__}/libs/functions_waitfor.shlib"

cleanup_ec2=1

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
build ami based on ansible playbooks

    -h            display this help and exit
    -a STRING     base ami id (required)
    -f STRING     comma separated list of security groups
    -F STRING     flavour [debian/ubuntu] (default: ubuntu)
    -g NUMBER     storage size in gb (default: 8gb)
    -m STRING     ami description (required)
    -n STRING     ami name (required)
    -p STRING     aws profile (required)
    -P STRING     name of playbook to run (required)
    -R STRING     aws region (defaults to profile setting)
    -s STRING     subnet id
    -S STRING     list of accounts to grant access
    -u STRING     ec2 ssh keypair (default: build-ami@wiGroup)
    -U STRING     ssh user (default: admin)
EOF
}

OPTIND=1
while getopts "ha:P:f:F:g:m:n:p:R:s:S:u:U:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    a )
      AWS_AMI_ID="${OPTARG}"
      ;;
    P )
      ANSIBLE_BOOK="${OPTARG}"
      ;;
    f )
      AWS_SGROUPS=( ${OPTARG//,/ } )
      ;;
    F )
      FLAVOUR="${OPTARG}"
      ;;
    g )
      AWS_EBS_SIZE="${OPTARG}"
      ;;
    m )
      AWS_AMI_DESC="${OPTARG}"
      ;;
    n )
      AWS_AMI_NAME="${OPTARG}"
      ;;
    p )
      AWS_PROFILE="${OPTARG}"
      ;;
    R )
      AWS_REGION="${OPTARG}"
      ;;
    s )
      AWS_SUBNET_ID="${OPTARG}"
      ;;
    S )
      if [[ -z "${SHARE_ACCOUNTS}" ]]; then
        SHARE_ACCOUNTS=()
      fi
      SHARE_ACCOUNTS+=( "${OPTARG}" )
      ;;
    u )
      AWS_SSH_KEYPAIR="${OPTARG}"
      ;;
    U )
      SSH_USER="${OPTARG}"
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
  AWS_AMI_ID \
  ANSIBLE_BOOK \
  AWS_AMI_DESC \
  AWS_AMI_NAME \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

if [[ -z "${AWS_SSH_KEYPAIR}" ]]; then
  AWS_SSH_KEYPAIR="build-ami@wiGroup"
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
      SSH_USER="admin"
      EC2_ROOT_DEVICE="/dev/xvda"
    fi
    ;;

  ubuntu )
    if [[ -z "${SSH_USER}" ]]; then
      SSH_USER="ubuntu"
      EC2_ROOT_DEVICE="/dev/sda1"
    fi
    ;;

  * )
    consolelog "unknown flavour..." "error"
    usage
    exit 1
    ;;
esac

if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="eu-west-1"
  fi
fi

consolelog "preparing stack..."
if ! aws::cfn_upsert "build-ami" "${__DIR__}/templates/build-ami.yml"; then
  consolelog "happens with conditions?" "error"
fi

# fetch stack values
stack_values=( $(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output json \
  cloudformation describe-stacks \
  --stack-name build-ami \
  | jq -r '.Stacks[].Outputs[] | "\(.Description)=\(.OutputValue)"') )

if [[ -z "${AWS_SUBNET_ID}" ]]; then
  for stack_value in "${stack_values[@]}"; do
    k="${stack_value%%=*}"
    v="${stack_value#*=}"

    if [[ "${k}" == "subnet-a" ]]; then
      AWS_SUBNET_ID="${v}"
      break
    fi
  done
fi

if [[ -z "${AWS_SGROUPS}" ]]; then
  AWS_SGROUPS=()
  for stack_value in "${stack_values[@]}"; do
    k="${stack_value%%=*}"
    v="${stack_value#*=}"

    if [[ "${k}" == ssh-* ]]; then
      AWS_SGROUPS+=( "${v}" )
    fi
  done
fi

# add ec2 keypair
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

if [[ -z "${AWS_SUBNET_ID}" ]]; then
  consolelog "empty AWS_SUBNET_ID" "error"
fi

consolelog "building new ami..."

# 1) launch instance
consolelog "launching new ec2 instance as template"

user_data="$(cat <<EOF
#!/usr/bin/env bash

set -ex

export DEBIAN_FRONTEND=noninteractive

apt-get -q update
apt-get -yq install python
EOF
)"

ec2_id=$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 run-instances \
  --user-data "${user_data}" \
  --image-id "${AWS_AMI_ID}" \
  --key-name "${AWS_SSH_KEYPAIR}" \
  --security-group-ids "${AWS_SGROUPS[@]}" \
  --instance-type c4.large \
  --block-device-mappings "[{\"DeviceName\":\"${EC2_ROOT_DEVICE}\",\"Ebs\":{\"VolumeSize\":${AWS_EBS_SIZE},\"DeleteOnTermination\":true,\"VolumeType\":\"gp2\"}}]" \
  --subnet-id "${AWS_SUBNET_ID}" \
  --associate-public-ip-address | grep -m1 INSTANCES | cut -f8)

if [[ -z "${ec2_id}" ]]; then
  consolelog "ERROR: unable to retrieve ec2_id" "error"
  exit 1
fi

aws::poll_ec2 "${ec2_id}"

ec2_ip=$(aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --output text \
  ec2 describe-instances \
  --instance-ids "${ec2_id}" | grep -m1 ASSOCIATION | cut -f4)

# http://stackoverflow.com/a/13778973/567193
if [[ ! ${ec2_ip} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  consolelog "ERROR: unable to retrieve ec2_ip" "error"
  exit 1
fi

# 2) prepare ssh
waitfor::tcpup "${ec2_ip}" "22"
ssh-keygen -f ~/.ssh/known_hosts -R "${ec2_ip}" &> /dev/null
ssh-keyscan -T 30 -t rsa "${ec2_ip}" >> ~/.ssh/known_hosts

# "waitfor" userdata (since its non-blocking) to finish
sleep 60

# 3) run playbook
consolelog "running playbook: ${ANSIBLE_BOOK}"
ansible-playbook \
  --private-key="${__DIR__}/keypairs/build-ami" \
  --inventory="${ec2_ip}," \
  --user="${SSH_USER}" \
  "${ANSIBLE_BOOK}"

# 4) shutdown instance
consolelog "stopping ec2 template instance"
remote_exec "${SSH_USER}@${ec2_ip}" "{ sleep 2; sudo shutdown -h now; } > /dev/null &" "${__DIR__}/keypairs/build-ami"

aws::poll_ec2 "${ec2_id}" "stopped"

# 5) create ami
consolelog "creating our custom ami"
if ! custom_ami="$(aws::ami_create "${ec2_id}" "${AWS_AMI_NAME}" "${AWS_AMI_DESC}")"; then
  consolelog "ERROR: unable to create custom ami" "error"
  aws::del_ec2 "${ec2_id}"
  exit 1
fi

aws::tag_ec2 "${custom_ami}" "Key=Name,Value=${AWS_AMI_NAME}"
aws::poll_ami "${custom_ami}"

# 6) delete instance
consolelog "deleting template ec2 instance"
aws::del_ec2 "${ec2_id}"

if [[ ! -z "${SHARE_ACCOUNTS}" ]]; then
  consolelog "sharing with accounts:"
  for acc_id in "${SHARE_ACCOUNTS[@]}"; do
    consolelog "* ${acc_id}"
    aws::ami_share "${custom_ami}" "${acc_id}"
  done
fi

if [[ ! -z "${JENKINS_HOME}" ]]; then
  echo "BUILD_AMI_ID=${custom_ami}" >> propsfile
fi
consolelog "SUCCESS: ${custom_ami}" "success"
