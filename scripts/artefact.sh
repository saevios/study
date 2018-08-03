#!/usr/bin/env bash
#
# create artefact
#

readlink_bin="${READLINK_PATH:-readlink}"
if ! "${readlink_bin}" -f test &> /dev/null; then
  __DIR__="$(dirname "$("${readlink_bin}" "${0}")")"
else
  __DIR__="$(dirname "$("${readlink_bin}" -f "${0}")")"
fi

# required libs
source "${__DIR__}/.bash/functions.shlib"
source "${__DIR__}/.bash/aws.shlib"

set -E
trap 'throw_exception' ERR

required_vars=( \
  BUILD_NUMBER \
  JOB_NAME \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

if [[ -z "${AWS_PROFILE}" ]]; then
  AWS_PROFILE="wi"
fi

if [[ -z "${AWS_S3_BUCKET}" ]]; then
  AWS_S3_BUCKET="wisolutions-xx-artefacts.wigroup.co"
fi

if [[ -z "${AWS_REGION}" ]]; then
  AWS_REGION="$(aws::get_region)"
  if [[ -z "${AWS_REGION}" ]]; then
    AWS_REGION="eu-west-1"
  fi
fi

zipfile="${BUILD_NUMBER}.zip"
s3_target="s3://${AWS_S3_BUCKET}/${JOB_NAME}/${BUILD_NUMBER}.zip"

consolelog "cleaning up composer..."
composer install
composer dump-autoload --classmap-authoritative

consolelog "creating zip..."
zip -q -r "${zipfile}" . -x \
  public/i.php \
  ".git/*" \
  "junit/*" \
  "tests/*" \
  "node_modules/*" \
  "vendor/bower_components/*" \
  storage/framework/cache/**\* \
  storage/framework/sessions/**\* \
  storage/framework/views/**\* \
  storage/logs/**\* \
  storage/meta/**\* \
  .git* \
  .env* \
  propsfile \
  *.md

consolelog "pushing ${zipfile} to ${s3_target}..."
while ! aws \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  s3 cp \
  "${zipfile}" "${s3_target}" \
  > /dev/null; do

  consolelog '* retrying...' 'error'
  sleep 30
done
