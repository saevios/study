#!/usr/bin/env bash
#
# set hostname of machine dynamically according to the instance-id
#

set -e

if [[ -z "${1}" ]]; then
  hostname_prefix=""
else
  hostname_prefix="${1}-"
fi

metadata_url="http://169.254.169.254"
#metadata_url="https://metadata-server.com"
hosts_file=/etc/hosts

if curl -sSfi --connect-timeout 3 "${metadata_url}" &> /dev/null; then
  instance_id="$(curl -sSf "${metadata_url}/latest/meta-data/instance-id")"
else
  instance_id=""
fi

new_hostname="${hostname_prefix}${instance_id}"

# we can not (but also do not need to) delete old entries to avoid a limbo state
# where the machine can not resolve its own hostname and slow down certain actions (=sudo)
#if ! grep -q "${new_hostname}" "${hosts_file}"; then
  echo "127.0.1.1 ${new_hostname}" | sudo tee -a "${hosts_file}" > /dev/null
#else
#  sudo sed -i'.bak' "s@.*${new_hostname}.*@127.0.1.1 ${new_hostname}@" "${hosts_file}"
#fi

sudo hostnamectl set-hostname "${new_hostname}"
sudo systemctl restart rsyslog
