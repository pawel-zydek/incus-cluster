#!/usr/bin/env bash
# Tworzy 3 maszyny wirtualne węzłów klastra na laptopie (pg).
# Uruchamiać z katalogu repozytorium: ./libvirt/create-vms.sh
# Wymaga: sieci "incuslab" oraz ISO NixOS w /var/lib/libvirt/images/nixos-minimal.iso
set -euo pipefail

ISO=/var/lib/libvirt/images/nixos-minimal.iso
RAM_MB=6144        # na węzeł
VCPUS=4
SYS_GB=30          # dysk systemowy NixOS
DATA_GB=60         # dysk dla puli ZFS Incusa (qcow2 rośnie w miarę zapisu)

# UEFI bez Secure Boot (systemd-boot nie jest podpisany)
BOOT="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no"

for i in 1 2 3; do
  name="incus$i"
  if virsh dominfo "$name" &>/dev/null; then
    echo "$name już istnieje - pomijam"
    continue
  fi
  virt-install \
    --name "$name" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "$BOOT" \
    --osinfo linux2022 \
    --disk "path=/var/lib/libvirt/images/$name-sys.qcow2,size=$SYS_GB,format=qcow2,bus=virtio,serial=incus-sys,discard=unmap" \
    --disk "path=/var/lib/libvirt/images/$name-data.qcow2,size=$DATA_GB,format=qcow2,bus=virtio,serial=incus-data,discard=unmap" \
    --network "network=incuslab,model=virtio,mac=52:54:00:50:00:1$i" \
    --cdrom "$ISO" \
    --graphics spice \
    --noautoconsole
  echo "$name utworzona"
done
