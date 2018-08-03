#!/usr/bin/env bash
#
# build the laravel app
#

readlink_bin="${READLINK_PATH:-readlink}"
if ! "${readlink_bin}" -f test &> /dev/null; then
  __DIR__="$(dirname "$("${readlink_bin}" "${0}")")"
else
  __DIR__="$(dirname "$("${readlink_bin}" -f "${0}")")"
fi

# required libs
source "${__DIR__}/.bash/functions.shlib"
source ~/.nvm/nvm.sh

set -E
trap 'throw_exception' ERR

#######################################
# Display Usage Information
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
usage() {
cat <<EOF
Usage: ${0##*/} [OPTIONS]
build the laravel app

    -h          display this help and exit
    -r          cache routes
EOF
}

#######################################
# Composer Install & Optionally Require
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
composer_install() {
  consolelog "Starting task 'Composer'"

  if ! "${COMPOSER_BIN}" install --prefer-dist --no-interaction --no-progress --no-suggest; then
    consolelog "Finished task 'Composer' with result: Error" "error"
    return 1
  fi

  if ! "${COMPOSER_BIN}" update --prefer-dist --no-interaction --no-progress --no-suggest; then
    consolelog "Finished task 'Composer' with result: Error" "error"
    return 1
  fi

  if ! "${COMPOSER_BIN}" dump-autoload --classmap-authoritative; then
    consolelog "Finished task 'Composer' with result: Error" "error"
    return 1
  fi

  consolelog "Finished task 'Composer' with result: Success" "success"
  return 0
}

#######################################
# Check Routes
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
check_routes() {
  consolelog "Starting task 'Check Routes'"

  if ! "${PHP_BIN}" artisan -q -vv route:list; then
    consolelog "Finished task 'Check Routes' with result: Error" "error"
    return 1
  else
    consolelog "Finished task 'Check Routes' with result: Success" "success"
    return 0
  fi
}

#######################################
# Cache Routes
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
cache_routes() {
  consolelog "Starting task 'Cache Routes'"

  if ! "${PHP_BIN}" artisan route:cache -vv; then
    consolelog "Finished task 'Cache Routes' with result: Error" "error"
    return 1
  else
    consolelog "Finished task 'Cache Routes' with result: Success" "success"
    return 0
  fi
}

#######################################
# Run Frontend Pipeline
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
frontend_pipeline() {
  consolelog "Starting task 'Frontend Pipeline'"

  if ! nvm use ||
     ! npm install ||
     ! npm run dev; then
    consolelog "Finished task 'Frontend Pipeline' with result: Error" "error"
    return 1
  else
    consolelog "Finished task 'Frontend Pipeline' with result: Success" "success"
    return 0
  fi
}

#######################################
# Prepare Temporary folder for our background proccess rc's
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
prepare_subpids() {
  if [[ -d .pids_tmp ]]; then
    rm -rf .pids_tmp
  fi
  mkdir .pids_tmp
}

#######################################
# Parse Temporary folder with our background proccess rc's
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
parse_subpids() {
  for file in .pids_tmp/*; do

    # if folder is empty, globing will resolve to a literal "*"
    if [[ ! -f "${file}" ]]; then
      continue
    fi

    consolelog "ERROR!" "error"
    exit 1
  done
}

#
# args
#
OPTIND=1
while getopts "hr" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    r )
      WEBAPP_BUILD_CACHE_ROUTES=1
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

#
# prerequisites
#

# allow custom binary paths for php and composer
if [[ -z "${PHP_BIN}" ]]; then
  PHP_BIN=php
fi

if [[ -z "${COMPOSER_BIN}" ]]; then
  COMPOSER_BIN=composer
fi

# Check if required tools are installed
dependencies=( git "${PHP_BIN}" "${COMPOSER_BIN}" )
for dependency in "${dependencies[@]}"; do
  if ! command -v "${dependency}" &> /dev/null; then
    echo "Please install '${dependency}' first." 1>&2
    exit 1
  fi
done

## try to load the users dotenv
if [[ ! -z "${APP_ENV}" ]] && [[ -f "${__DIR__}/.env.${APP_ENV}" ]]; then
  envfile="${__DIR__}/.env.${APP_ENV}"
else
  envfile="${__DIR__}/.env"
fi

if [[ -s "${envfile}" ]]; then
  source "${envfile}"
fi

consolelog "starting laravel build..."

# pre-checks
if ! "${COMPOSER_BIN}" validate --no-check-all --no-check-publish --no-interaction --quiet; then
  consolelog "ERROR: stale composer.lock" "error"
  exit 1
fi

prepare_subpids
  { composer_install || touch ".pids_tmp/composer_install"; } &
  wait
parse_subpids

prepare_subpids
  { frontend_pipeline || touch ".pids_tmp/frontend_pipeline"; } &
  if [[ ! -z "${WEBAPP_BUILD_CACHE_ROUTES}" ]]; then
    { cache_routes || touch ".pids_tmp/cache_routes"; } &
  fi
  wait
parse_subpids

if [[ ! -z "${ghprbActualCommit}" ]]; then
  echo "${ghprbActualCommit}" > "${__DIR__}/public/version.txt"
elif [[ ! -z "${GIT_COMMIT}" ]]; then
  echo "${GIT_COMMIT}" > "${__DIR__}/public/version.txt"
fi

consolelog "DONE!" "success"
