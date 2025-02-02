#!/usr/bin/env bash

# shellcheck disable=SC2154
if [[ -n "${TZ}" ]]; then
  echo "Setting timezone to ${TZ}"
  ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone
fi

cd /chia-blockchain || exit 1

# shellcheck disable=SC1091
. ./activate

# shellcheck disable=SC2086
chia ${chia_args} init --fix-ssl-permissions

if [[ -n ${ca} ]]; then
  if ! openssl verify -CAfile "${ca}/private_ca.crt" "${CHIA_ROOT}/config/ssl/harvester/private_harvester.crt" &>/dev/null; then
    echo "initializing from new CA"
    # shellcheck disable=SC2086
    chia ${chia_args} init -c "${ca}"
  else
    echo "using existing CA"
  fi
fi

# Enables whatever the default testnet is for the version of chia that is running
if [[ ${testnet} == 'true' ]]; then
  echo "configure testnet"
  chia configure --testnet true
fi

# Allows using another testnet that isn't the default testnet
if [[ -n ${network} ]]; then
  echo "Setting network name to ${network}"
  yq -i '
    .selected_network = env(network) |
    .seeder.selected_network = env(network) |
    .harvester.selected_network = env(network) |
    .pool.selected_network = env(network) |
    .farmer.selected_network = env(network) |
    .timelord.selected_network = env(network) |
    .full_node.selected_network = env(network) |
    .ui.selected_network = env(network) |
    .introducer.selected_network = env(network) |
    .wallet.selected_network = env(network) |
    .data_layer.selected_network = env(network)
    ' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n ${network_port} ]]; then
  echo "Setting network port to ${network_port}"
  yq -i '
    .seeder.port = env(network_port) |
    .seeder.other_peers_port = env(network_port) |
    .farmer.full_node_peers[0].port = env(network_port) |
    .timelord.full_node_peers[0].port = env(network_port) |
    .full_node.port = env(network_port) |
    .full_node.introducer_peer.port = env(network_port) |
    .introducer.port = env(network_port) |
    .wallet.full_node_peers[0].port = env(network_port) |
    .wallet.introducer_peer.port = env(network_port)
    ' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n ${introducer_address} ]]; then
  echo "Setting introducer to ${introducer_address}"
  yq -i '
    .full_node.introducer_peer.host = env(introducer_address) |
    .wallet.introducer_peer.host = env(introducer_address)
    ' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n ${dns_introducer_address} ]]; then
  echo "Setting network port in config to ${dns_introducer_address}"
  yq -i '
    .full_node.dns_servers = [env(dns_introducer_address)] |
    .wallet.dns_servers = [env(dns_introducer_address)]
    ' "$CHIA_ROOT/config/config.yaml"
fi

if [[ ${keys} == "persistent" ]]; then
  echo "Not touching key directories, key directory likely mounted by volume"
elif [[ ${keys} == "none" ]]; then
  # This is technically redundant to 'keys=persistent', but from a user's readability perspective, it means two different things
  echo "Not touching key directories, no keys needed"
elif [[ ${keys} == "copy" ]]; then
  echo "Setting the keys=copy environment variable has been deprecated. If you're seeing this message, you can simply change the value of the variable keys=none"
elif [[ ${keys} == "generate" ]]; then
  echo "to use your own keys pass the mnemonic as a text file -v /path/to/keyfile:/path/in/container and -e keys=\"/path/in/container\""
  chia keys generate -l ""
else
  chia keys add -f "${keys}" -l ""
fi

for p in ${plots_dir//:/ }; do
  mkdir -p "${p}"
  if [[ ! $(ls -A "$p") ]]; then
    echo "Plots directory '${p}' appears to be empty, try mounting a plot directory with the docker -v command"
  fi
  chia plots add -d "${p}"
done

if [[ ${recursive_plot_scan} == 'true' ]]; then
  yq -i '.harvester.recursive_plot_scan = true' "$CHIA_ROOT/config/config.yaml"
else
  yq -i '.harvester.recursive_plot_scan = false' "$CHIA_ROOT/config/config.yaml"
fi

chia configure --upnp "${upnp}"

if [[ -n "${log_level}" ]]; then
  chia configure --log-level "${log_level}"
fi

if [[ -n "${peer_count}" ]]; then
  chia configure --set-peer-count "${peer_count}"
fi

if [[ -n "${outbound_peer_count}" ]]; then
  chia configure --set_outbound-peer-count "${outbound_peer_count}"
fi

if [[ -n ${farmer_address} && -n ${farmer_port} ]]; then
  chia configure --set-farmer-peer "${farmer_address}:${farmer_port}"
fi

if [[ -n ${crawler_db_path} ]]; then
  chia configure --crawler-db-path "${crawler_db_path}"
fi

if [[ -n ${crawler_minimum_version_count} ]]; then
  chia configure --crawler-minimum-version-count "${crawler_minimum_version_count}"
fi

if [[ -n ${self_hostname} ]]; then
  yq -i '.self_hostname = env(self_hostname)' "$CHIA_ROOT/config/config.yaml"
else
  yq -i '.self_hostname = "127.0.0.1"' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n ${full_node_peer} ]]; then
  echo "Changing full_node_peer settings in config.yaml with value: $full_node_peer"
  full_node_peer_host=$(echo "$full_node_peer" | rev | cut -d ':' -f 2- | rev) \
  full_node_peer_port=$(echo "$full_node_peer" | awk -F: '{print $NF}') \
  yq -i '
  .wallet.full_node_peer.host = env(full_node_peer_host) |
  .wallet.full_node_peer.port = env(full_node_peer_port) |
  .timelord.full_node_peer.host = env(full_node_peer_host) |
  .timelord.full_node_peer.port = env(full_node_peer_port) |
  .farmer.full_node_peer.host = env(full_node_peer_host) |
  .farmer.full_node_peer.port = env(full_node_peer_port)
  ' "$CHIA_ROOT/config/config.yaml"
fi

if [[ ${log_to_file} != 'true' ]]; then
  sed -i 's/log_stdout: false/log_stdout: true/g' "$CHIA_ROOT/config/config.yaml"
else
  sed -i 's/log_stdout: true/log_stdout: false/g' "$CHIA_ROOT/config/config.yaml"
fi

# Compressed plot harvesting settings.
if [[ -n "$parallel_decompressor_count" && "$parallel_decompressor_count" != 0 ]]; then
  yq -i '.harvester.parallel_decompressor_count = env(parallel_decompressor_count)' "$CHIA_ROOT/config/config.yaml"
else
  yq -i '.harvester.parallel_decompressor_count = 0' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n "$decompressor_thread_count" && "$decompressor_thread_count" != 0 ]]; then
  yq -i '.harvester.decompressor_thread_count = env(decompressor_thread_count)' "$CHIA_ROOT/config/config.yaml"
else
  yq -i '.harvester.decompressor_thread_count = 0' "$CHIA_ROOT/config/config.yaml"
fi

if [[ -n "$use_gpu_harvesting" && "$use_gpu_harvesting" == 'true' ]]; then
  yq -i '.harvester.use_gpu_harvesting = True' "$CHIA_ROOT/config/config.yaml"
else
  yq -i '.harvester.use_gpu_harvesting = False' "$CHIA_ROOT/config/config.yaml"
fi

# Install timelord if service variable contains timelord substring
if [ -z "${service##*timelord*}" ]; then
    echo "Installing timelord using install-timelord.sh"

    # install-timelord.sh relies on lsb-release for determining the cmake installation method, and git for building chiavdf
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y lsb-release git

    /bin/sh ./install-timelord.sh
fi

# Map deprecated legacy startup options.
if [[ ${farmer} == "true" ]]; then
  service="farmer-only"
elif [[ ${harvester} == "true" ]]; then
  service="harvester"
fi

if [[ ${service} == "harvester" ]]; then
  if [[ -z ${farmer_address} || -z ${farmer_port} || -z ${ca} ]]; then
    echo "A farmer peer address, port, and ca path are required."
    exit
  fi
fi

exec "$@"
