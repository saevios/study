#!/usr/bin/env bash

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} OPTIONS
create database pool in glassfish

    -h            display this help and exit
    -d STRING     db name (required)
    -H STRING     db host (required)
    -n STRING     pool name (required)
    -u STRING     db username (required)
    -p STRING     db password
    -P STRING     db port (default: 3306)
    -t STRING     db table
EOF
}

OPTIND=1
while getopts "hd:H:n:u:p:P:t:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    d )
      DB_DATABASE="${OPTARG}"
      ;;
    H )
      DB_HOST="${OPTARG}"
      ;;
    n )
      DB_POOLNAME="${OPTARG}"
      ;;
    u )
      DB_USERNAME="${OPTARG}"
      ;;
    p )
      DB_PASSWORD="${OPTARG}"
      ;;
    P )
      DB_PORT="${OPTARG}"
      ;;
    t )
      DB_TABLE="${OPTARG}"
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

required_vars=( \
  DB_DATABASE \
  DB_HOST \
  DB_POOLNAME \
  DB_USERNAME \
)
for required_var in "${required_vars[@]}"; do
  if [[ -z "${!required_var}" ]]; then
    echo "required var missing (${required_var})" 1>&2
    exit 2
  fi
done

if [[ -z "${ASADMIN}" ]]; then
  ASADMIN="/usr/local/bin/glassfish-asadmin"
fi

if [[ -z "${DB_PORT}" ]]; then
  DB_PORT="3306"
fi

"${ASADMIN}" create-jdbc-connection-pool \
  --datasourceclassname com.mysql.jdbc.jdbc2.optional.MysqlConnectionPoolDataSource \
  --restype javax.sql.ConnectionPoolDataSource \
  --property "User=${DB_USERNAME}:Password=${DB_PASSWORD}:URL=jdbc\:mysql\://${DB_HOST}\:${DB_PORT}/${DB_DATABASE}" \
  "${DB_POOLNAME}"

# Set defaults to allow auto-connect if the db connection is lost
"${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.ping=true"
"${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.connection-creation-retry-attempts=86400"
"${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.connection-creation-retry-interval-in-seconds=1"
if [[ ! -z "${DB_TABLE}" ]]; then
  "${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.validation-table-name=${DB_TABLE}"
  "${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.is-connection-validation-required=true"
  "${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.connection-validation-method=auto-commit"
  "${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.validate-atmost-once-period-in-seconds=60"
fi
"${ASADMIN}" set "domain.resources.jdbc-connection-pool.${DB_POOLNAME}.fail-all-connections=true"

"${ASADMIN}" create-jdbc-resource --connectionpoolid "${DB_POOLNAME}" "jdbc/${DB_POOLNAME}"
consolelog "testing..."
"${ASADMIN}" ping-connection-pool "${DB_POOLNAME}"
