#!/usr/bin/env bash
# Tworzy 3 maszyny wirtualne węzłów klastra na laptopie (pg).
# Uruchamiać z katalogu repozytorium: ./libvirt/create-vms.sh
# Wymaga: datasetu rpool/vm-lab zamontowanego w /var/lib/libvirt/vm-lab (nixos-config),
#         sieci "incuslab", "incuslab-ceph", "incuslab-ot"
#         oraz ISO NixOS w /var/lib/libvirt/images/nixos-minimal.iso
set -euo pipefail

ISO=/var/lib/libvirt/images/nixos-minimal.iso
IMG_DIR=/var/lib/libvirt/vm-lab     # dyski węzłów - osobny dataset ZFS rpool/vm-lab
RAM_MB=6144        # na węzeł: Ceph + system ok. 3,5 GB, reszta na lekkie VM-ki (Windows: 8192)
VCPUS=4
SYS_GB=30          # dysk systemowy NixOS
DATA_GB=60         # dysk OSD Ceph (qcow2 rośnie w miarę zapisu)

# UEFI bez Secure Boot (systemd-boot nie jest podpisany).
# Kolejność startu ustawiona na urządzeniach (boot.order): płyta, potem dysk systemowy.
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
  # MAC-i muszą się zgadzać z nodes.nix.
  # ISO jako stały napęd CD (--import zamiast --cdrom): przy --cdrom virt-install dołącza płytę
  # tylko na pierwszy start i po pełnym wyłączeniu VM startowałaby z pustego dysku.
  # Po instalacji płytę wysuwa się ręcznie (README, krok 2c).
  virt-install \
    --name "$name" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --machine q35 \
    --boot "$BOOT" \
    --osinfo linux2022 \
    --disk "path=$ISO,device=cdrom,bus=sata,readonly=on,boot.order=1" \
    --disk "path=$IMG_DIR/$name-sys.qcow2,size=$SYS_GB,format=qcow2,bus=virtio,serial=incus-sys,discard=unmap,boot.order=2" \
    --disk "path=$IMG_DIR/$name-data.qcow2,size=$DATA_GB,format=qcow2,bus=virtio,serial=incus-data,discard=unmap" \
    --network "network=incuslab,model=virtio,mac=52:54:00:50:00:1$i" \
    --network "network=incuslab-ceph,model=virtio,mac=52:54:00:51:00:1$i" \
    --network "network=incuslab-ot,model=virtio,mac=52:54:00:52:00:1$i" \
    --watchdog model=i6300esb,action=reset \
    --import \
    --graphics spice \
    --noautoconsole
  echo "$name utworzona"
done
