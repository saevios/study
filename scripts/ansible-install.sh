#!/usr/bin/env bash

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"

set -E
trap 'throw_exception' ERR

# get configured roles-path
roles_path="$(grep -F roles_path ansible.cfg | cut -d= -f2)"
# resolve potential tilde
roles_path="${roles_path/#\~/$HOME}"

consolelog "installing requirements"
ansible-galaxy install \
  --force \
  -r "requirements.yml"

# loop through all deps to install sub-deps
while read -r name; do
  if [[ -f "${roles_path}/${name}/requirements.yml" ]]; then
    consolelog "installing found dependencies of ${name}"
    ansible-galaxy install \
      --force \
      -r "${roles_path}/${name}/requirements.yml"
  fi
done < <(grep -F name: requirements.yml | cut -d: -f2)
