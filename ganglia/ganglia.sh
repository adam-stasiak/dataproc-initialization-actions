#!/bin/bash
#  Copyright 2015 Google, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#  This initialization action installs Ganglia, a distributed monitoring system.

set -euxo pipefail

function err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
  return 1
}

function update_apt_get() {
  for ((i = 0; i < 10; i++)); do
    if apt-get update; then
      return 0
    fi
    sleep 5
  done
  return 1
}

function setup_ganglia_host() {
  # Install dependencies needed for Ganglia host
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    rrdtool \
    gmetad \
    ganglia-webfrontend || err 'Unable to install packages'

  ln -s /etc/ganglia-webfrontend/apache.conf /etc/apache2/sites-enabled/ganglia.conf || echo
  sed -i "s/my cluster/${master_hostname}/" /etc/ganglia/gmetad.conf
  systemctl restart ganglia-monitor gmetad apache2
}

function main() {
  local master_hostname=$(/usr/share/google/get_metadata_value attributes/dataproc-master)
  local cluster_name=$(/usr/share/google/get_metadata_value attributes/dataproc-cluster-name)
  local worker_count=$(/usr/share/google/get_metadata_value attributes/dataproc-worker-count)
  update_apt_get || err 'Unable to update apt-get'
  apt-get install -y ganglia-monitor

  sed -e "/send_metadata_interval = 0 /s/0/5/" -i /etc/ganglia/gmond.conf
  #sed -e "/name = \"unspecified\" /s/unspecified/${cluster_name}/" -i /etc/ganglia/gmond.conf


  sed -e '/mcast_join /s/^  /  #/' -i /etc/ganglia/gmond.conf
  sed -e '/bind /s/^  /  #/' -i /etc/ganglia/gmond.conf
  master_addresses=""
  slave_addresses=""

  if [[ "${HOSTNAME}" == "${master_hostname}" ]]; then
    # Setup Ganglia host only on the master node ("0"-master in HA mode)
    setup_ganglia_host || err 'Setting up Ganglia host failed'
    if [[ ${worker_count} > 0 ]];then
      last_worker=$[$worker_count-1]
      for i in $(seq 0 $last_worker);
      do
        echo $i
        slave_addresses+="${cluster_name}-w-${i} "
      done
    fi
    zookeeper_list=$(grep '^server\.' /etc/zookeeper/conf/zoo.cfg \
      | cut -d '=' -f 2 \
      | cut -d ':' -f 1 \
      | sort \
      | uniq)

    arr=${zookeeper_list}
    for x in $arr
    do
    if [[ "\"${x}\"" == *-m* ]];then
      master_addresses+="${x} "
    fi
    done

    sed -e "/name = \"unspecified\" /s/unspecified/hadoop-masters/" -i /etc/ganglia/gmond.conf
    sed -e "/udp_send_channel {/a\  host = ${cluster_name}-m-0" -i /etc/ganglia/gmond.conf

    echo "data_source 'hadoop-masters' ${master_addresses}" >> /etc/ganglia/gmetad.conf
    echo "data_source 'hadoop-slaves' ${slave_addresses}" >> /etc/ganglia/gmetad.conf
    master_addresses=""
    zookeeper_list=$(grep '^server\.' /etc/zookeeper/conf/zoo.cfg \
      | cut -d '=' -f 2 \
      | cut -d ':' -f 1 \
      | sort \
      | uniq \
      | sed "s/$/:8649/")
    arr=${zookeeper_list}
    for x in $arr
    do
    if [[ "\"${x}\"" == *-m* ]];then
      master_addresses+="${x} "
    fi
    done



  cat <<EOT >> /etc/hadoop/conf/hadoop-metrics.properties
  dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext31
  dfs.period=10
  dfs.servers=${master_addresses}
  mapred.class=org.apache.hadoop.metrics.ganglia.GangliaContext31
  mapred.period=10
  mapred.servers=${master_addresses}
EOT

else

  zookeeper_list=$(grep '^server\.' /etc/zookeeper/conf/zoo.cfg \
    | cut -d '=' -f 2 \
    | cut -d ':' -f 1 \
    | sort \
    | uniq \
    | sed "s/$/:8649/")
  arr=${zookeeper_list}
    for x in $arr
    do
    if [[ "\"${x}\"" == *-m* ]];then
      master_addresses+="${x} "
    fi
    done

  if [[ ${worker_count} > 0 ]];then
    last_worker=$[$worker_count-1]
    for i in $(seq 0 $last_worker);
    do
      echo $i
      slave_addresses+="${cluster_name}-w-${i}:8649 "
    done
  fi

  cat <<EOT >> /etc/hadoop/conf/hadoop-metrics.properties
  dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext31
  dfs.period=10
  dfs.servers=${slave_addresses}
  mapred.class=org.apache.hadoop.metrics.ganglia.GangliaContext31
  mapred.period=10
  mapred.servers=${slave_addresses}
EOT
  slave_addresses=""
  if [[ ${worker_count} > 0 ]];then
     last_worker=$[$worker_count-1]
     for i in $(seq 0 $last_worker);
     do
       slave_addresses+="${cluster_name}-w-${i} "
     done
  fi
  # Configure non-host Ganglia nodes
  sed -e "/name = \"unspecified\" /s/unspecified/hadoop-slaves/" -i /etc/ganglia/gmond.conf
  sed -e "/udp_send_channel {/a\  host = ${cluster_name}-m-0" -i /etc/ganglia/gmond.conf
  sed -e "/deaf = no /s/no/yes/" -i /etc/ganglia/gmond.conf
  sed -i '/udp_recv_channel {/,/}/d' /etc/ganglia/gmond.conf
  systemctl restart ganglia-monitor
  fi
}

main
