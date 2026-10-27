# Układ dysku systemowego (identyczny na każdym węźle).
# Dysk ma w libvirt numer seryjny "incus-sys", więc ścieżka jest stała na wszystkich VM.
# Bez szyfrowania - węzeł ma sam wstawać po restarcie.
# Drugi dysk ("incus-data") NIE jest tu opisany: dostaje go w całości Incus na swoją pulę ZFS.
{ ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/disk/by-id/virtio-incus-sys";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = { type = "zfs"; pool = "rpool"; };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options = { ashift = "12"; autotrim = "on"; };
      rootFsOptions = {
        compression = "zstd";
        acltype = "posixacl";
        xattr = "sa";
        relatime = "on";
        dnodesize = "auto";
        mountpoint = "none";
        canmount = "off";
      };
      datasets = {
        root = { type = "zfs_fs"; mountpoint = "/";     options.mountpoint = "legacy"; };
        nix  = { type = "zfs_fs"; mountpoint = "/nix";  options.mountpoint = "legacy"; };
        var  = { type = "zfs_fs"; mountpoint = "/var";  options.mountpoint = "legacy"; };
        home = { type = "zfs_fs"; mountpoint = "/home"; options.mountpoint = "legacy"; };
      };
    };
  };
}
