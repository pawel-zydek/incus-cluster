#!/usr/bin/env bash
# Tworzy 3 maszyny wirtualne węzłów klastra na laptopie (pg).
# Uruchamiać z katalogu repozytorium: ./libvirt/create-vms.sh
# Wymaga: datasetu rpool/vm-lab zamontowanego w /var/lib/libvirt/vm-lab (nixos-config),
#         sieci "incuslab", "incuslab-ceph", "incuslab-ot"
#         oraz ISO NixOS w /var/lib/libvirt/images/nixos-minimal.iso
set -euo pipefail

ISO=/var/lib/libvirt/images/nixos-minimal.iso
IMG_DIR=/var/lib/libvirt/vm-lab     # dyski węzłów - osobny dataset ZFS rpool/vm-lab
RAM_MB=8192        # na węzeł: Ceph (MON+MGR+OSD) ok. 2,5 GB + system + VM-ki
VCPUS=4
SYS_GB=30          # dysk systemowy NixOS
DATA_GB=60         # dysk OSD Ceph (qcow2 rośnie w miarę zapisu)

# UEFI bez Secure Boot (systemd-boot nie jest podpisany)
BOOT="uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no"

mountpoint -q "$IMG_DIR" || { echo "$IMG_DIR nie jest zamontowany (README, część 1)"; exit 1; }

for net in incuslab incuslab-ceph incuslab-ot; do
  virsh net-info "$net" &>/dev/null || { echo "Brak sieci $net (README, krok 1b)"; exit 1; }
done

for i in 1 2 3; do
  name="incus$i"
  if virsh dominfo "$name" &>/dev/null; then
    echo "$name już istnieje - pomijam"
    continue
  fi
  # MAC-i muszą się zgadzać z nodes.nix
  virt-install \
    --name "$name" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "$BOOT" \
    --osinfo linux2022 \
    --disk "path=$IMG_DIR/$name-sys.qcow2,size=$SYS_GB,format=qcow2,bus=virtio,serial=incus-sys,discard=unmap" \
    --disk "path=$IMG_DIR/$name-data.qcow2,size=$DATA_GB,format=qcow2,bus=virtio,serial=incus-data,discard=unmap" \
    --network "network=incuslab,model=virtio,mac=52:54:00:50:00:1$i" \
    --network "network=incuslab-ceph,model=virtio,mac=52:54:00:51:00:1$i" \
    --network "network=incuslab-ot,model=virtio,mac=52:54:00:52:00:1$i" \
    --watchdog model=i6300esb,action=reset \
    --cdrom "$ISO" \
    --graphics spice \
    --noautoconsole
  echo "$name utworzona"
done
