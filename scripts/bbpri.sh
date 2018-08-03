#!/usr/bin/env bash
#
# bbpri
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"

set -E
trap 'throw_exception' ERR

params=()

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
bitbucket pullrequest injector

    -h            display this help and exit
    -U STRING     uris to inject (linkname:folder/project)
EOF
}

deploy_job_link() {
  local folder="${1%%/*}"
  local project="${1#*/}"

  echo "${JENKINS_URL}job/${folder}/view/deploys/job/${project}/parambuild/?APP_BUILD_NUMBER=${BUILD_NUMBER}"
}

git_commit_link() {
  echo "https://bitbucket.org/${repositoryOwner}/${repositoryName}/commits/${1}?at=master"
}

OPTIND=1
while getopts "hU:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    U )
      if [[ -z "${JOB_URIS}" ]]; then
        JOB_URIS=()
      fi
      JOB_URIS+=( "${OPTARG}" )
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

required_vars=( \
  repositoryOwner \
  repositoryName \
  destinationRepositoryOwner \
  destinationRepositoryName \
  pullRequestId \
  BUILD_NUMBER \
  GIT_COMMIT \
  JENKINS_URL \
  JOB_URIS \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

# get current PR description
description="$(bitbucket repositories:pullrequests:get:description "${destinationRepositoryOwner}/${destinationRepositoryName}" "${pullRequestId}")"

# remove old cicd/console
description="${description%%## cicd/console*}"
# rtrim (https://stackoverflow.com/a/3352015/567193)
description="${description%"${description##*[![:space:]]}"}"

links=""
for job_uri in "${JOB_URIS[@]}"; do
  link_name="${job_uri%%:*}"
  link_uri="${job_uri#*:}"
  links="$(printf "${links}\n* Deploy [${GIT_COMMIT:0:7}]($(git_commit_link "${GIT_COMMIT}")) to [${link_name}]($(deploy_job_link "${link_uri}"))")"
done

# append new cicd/console
read -r -d '' description <<EOF || true
${description}

## cicd/console
${links}
EOF

bitbucket repositories:pullrequests:update:description "${destinationRepositoryOwner}/${destinationRepositoryName}" "${pullRequestId}" "${description}"
