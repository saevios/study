#!/usr/bin/env bash
#
# self-update wisolution-systools
#

__DIR__="$(dirname "$("${READLINK_PATH:-readlink}" -f "$0")")"

# required libs
source "${__DIR__}/libs/functions.shlib"

set -E
trap 'throw_exception' ERR

usage() {
cat <<EOF
Usage: ${0##*/} [OPTIONS] task
wiSolution systools

Options:

    -h            display this help and exit

Tasks:

    install       install systools and symlink into /usr/local/bin
    update        update systools + symlinks
EOF
}

update() {
  ( cd ~/.wisolutions-systools && git pull -r -q )
  sudo ln -sf ~/.wisolutions-systools/*.sh /usr/local/bin/
  chmod 600 ~/.wisolutions-systools/keypairs/*
}

install() {
  local jq_download_url
  local uname_string="$(uname)"

  if [[ "${uname_string}" == "Linux" ]]; then
    jq_download_url="https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64"
  elif [[ "${uname_string}" == "Darwin" ]]; then
    jq_download_url="https://github.com/stedolan/jq/releases/download/jq-1.5/jq-osx-amd64"
  else
    echo "unsupported system: ${uname_string}"
    exit 1
  fi

  sudo mkdir -p /usr/local/bin/
  sudo -H pip install -qU yq
  sudo curl -sSfL "${jq_download_url}" -o /usr/local/bin/jq
  sudo chmod +x /usr/local/bin/jq

  mkdir -p ~/.wisolutions-systools
  if [[ ! -d ~/.wisolutions-systools/.git ]]; then
    git clone -q git@bitbucket.org:wiGroup/wisolutions-systools.git ~/.wisolutions-systools
  fi
  sudo ln -sf ~/.wisolutions-systools/*.sh /usr/local/bin/
  chmod 600 ~/.wisolutions-systools/keypairs/*
}

# primary options
OPTIND=1
while getopts "hb:k:p:" opt; do
  case "${opt}" in
    h )
      usage
      exit 0
      ;;
    '?' )
      usage >&2
      exit 1
      ;;
  esac
done
shift "$((OPTIND-1))"

# tasks
case "${1}" in
  install )
    install
    ;;

  update )
    update
    ;;

  * )
    usage >&2
    exit 1
esac
