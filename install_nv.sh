#!/usr/bin/env bash

cd "$(dirname "$0")"

case ":$PATH:" in
  *:$PWD/IncludesLinux/bin:*) ;;
  *) export PATH=$PATH:$PWD/IncludesLinux/bin ;;
esac

is_user_root () { [ "${EUID:-$(id -u)}" -eq 0 ]; }

install_nv=0

for arg in "$@"
do
  if [ "$arg" == "--help" ] || [ "$arg" == "-h" ]; then
    cat << EOF

RainbowMiner Nvidia CUDA Installer v1.1

Commandline options:
  -f, --force           force (re-)install of the most current NVIDIA CUDA package
  -h, --help            displays this help page

EOF
    exit
  elif [ "$arg" == "--force" ] || [ "$arg" == "-f" ]; then
    install_nv=1
  fi
done

if [ "$install_nv" -eq 1 ]; then
  install_nv_params="-f"
else
  install_nv_params=""
fi

./IncludesLinux/bash/libnv.sh $install_nv_params

exit_code=$?

if [ "$exit_code" -eq 0 ] && is_user_root; then
  SUDO=""
  if ! [ -d "/opt/rainbowminer" ]; then
    $SUDO mkdir -p /opt/rainbowminer
    if ! [ -d "/opt/rainbowminer/ocdcmd" ]; then
      $SUDO mkdir -p /opt/rainbowminer/ocdcmd
      $SUDO chmod 777 /opt/rainbowminer/ocdcmd
    fi
  fi

  $SUDO find ./IncludesLinux/lib -type f -exec sh -c 'mkdir -p "/opt/rainbowminer/$(dirname "${1#./IncludesLinux/}")" && cp -f "$1" "/opt/rainbowminer/${1#./IncludesLinux/}"' _ {} \;
fi
