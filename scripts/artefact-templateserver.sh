#!/usr/bin/env bash
#
# tool to push built apps (artefacts) to s3
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
create templateserver artefact

    -h          display this help and exit
    -b STRING   target s3 bucket (required)
    -k STRING   s3 object key prefix
    -p STRING   aws profile (required)
EOF
}

createzip() {
  rm -rf artefact
  mkdir -p artefact

  mv app-server/target/*.war artefact/ &
  mv app-server-scripts/target/*.tar.gz artefact/ &
  wait

  # subshell to not change pwd context of parent
  ( cd artefact && zip \
    --quiet \
    --recurse-paths \
    app.zip \
    . )
}

OPTIND=1
while getopts "hb:k:p:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    b )
      AWS_S3_BUCKET="${OPTARG}"
      ;;
    k )
      AWS_S3_PREFIX="${OPTARG}"
      ;;
    p )
      AWS_PROFILE="${OPTARG}"
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
  AWS_S3_BUCKET \
  BUILD_NUMBER \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

consolelog "creating zip..."
createzip

consolelog "pushing to s3..."
aws \
  --profile "${AWS_PROFILE}" \
  s3 cp \
  artefact/app.zip "s3://${AWS_S3_BUCKET}/${AWS_S3_PREFIX}${BUILD_NUMBER}.zip" \
  --quiet
