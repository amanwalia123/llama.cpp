#!/bin/bash

# Get the username from the hostname (aman.walia)
HOST_USER="aman.walia"
HOST_HOME="/home/${HOST_USER}"

# Get UID/GID from the host's home directory ownership
HOST_UID=$(stat -c '%u' "/host${HOST_HOME}")
HOST_GID=$(stat -c '%g' "/host${HOST_HOME}")

# Get groups from host
HOST_GROUPS=$(id -Gn -u "$HOST_UID" 2>/dev/null || true)

# Create group if it doesn't exist
if ! getent group "$HOST_GID" > /dev/null 2>&1; then
    groupadd -g "$HOST_GID" "$HOST_USER" 2>/dev/null || true
fi

# Create user if it doesn't exist
if ! getent passwd "$HOST_UID" > /dev/null 2>&1; then
    useradd -m -u "$HOST_UID" -g "$HOST_GID" -s /bin/bash -d "$HOST_HOME" "$HOST_USER" 2>/dev/null || true
fi

# Install sudo and add user to sudo group
export DEBIAN_FRONTEND=noninteractive
export TZ="America/Chicago"
apt-get update && apt-get install -y sudo nvidia-cuda-toolkit
usermod -aG sudo "$HOST_USER"

# Allow passwordless sudo - append to main sudoers file (sudo-rs bug with sudoers.d NOPASSWD)
echo "$HOST_USER ALL=(ALL:ALL) NOPASSWD:ALL" >> /etc/sudoers

# Switch to the user
export HOME="$HOST_HOME"
export USER="$HOST_USER"
export LOGNAME="$HOST_USER"

if [ $# -eq 0 ]; then
    exec su -s /bin/bash "$HOST_USER"
fi
exec su -s /bin/bash "$HOST_USER" -c "$*"
