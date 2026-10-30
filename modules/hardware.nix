# Wspólny "hardware-configuration" dla wszystkich węzłów.
# Węzły są identycznymi VM w KVM, więc nie generujemy osobnego pliku dla każdego.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];   # sterowniki virtio

  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_blk" "sr_mod" ];
  boot.kernelModules = [
    "kvm-intel"   # KVM wewnątrz węzła (zagnieżdżona wirtualizacja)
    "i6300esb"    # watchdog emulowany przez QEMU (libvirt/create-vms.sh) - reset VM, gdy jądro zawiśnie
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
}
