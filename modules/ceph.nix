# Ceph: na każdym węźle MON + MGR + jeden OSD (BlueStore na całym dysku "incus-data").
#
# NixOS deklaruje ceph.conf i usługi systemd, ale nie inicjalizuje klastra (brak cephadm).
# Jednorazowy bootstrap (klucze, monmap, OSD) robi scripts/ceph-bootstrap.sh.
# Do tego czasu usługi się nie uruchamiają - moduł NixOS ma warunek "istnieje keyring".
{ lib, pkgs, nodes, nodeName, cluster, ... }:
let
  node = nodes.${nodeName};
  names = builtins.attrNames nodes;
  osd = toString node.osdId;

  monAddr = n: "[v2:${nodes.${n}.cephIp}:3300,v1:${nodes.${n}.cephIp}:6789]";
in
{
  services.ceph = {
    enable = true;

    global = {
      fsid = cluster.ceph.fsid;
      monInitialMembers = lib.concatStringsSep "," names;
      monHost = lib.concatMapStringsSep "," monAddr names;
      publicNetwork = cluster.ceph.network;
      clusterNetwork = cluster.ceph.network;
    };

    extraConfig = {
      # 3 kopie, zapis możliwy przy 2 - awaria jednego węzła = praca bez przestoju
      "osd pool default size" = "3";
      "osd pool default min size" = "2";
      "osd memory target" = cluster.ceph.osdMemoryTarget;
      # logi do journala zamiast do /var/log/ceph
      "log to file" = "false";
      "log to stderr" = "true";
      "mon cluster log to file" = "false";
    };

    mon = { enable = true; daemons = [ nodeName ]; };
    mgr = { enable = true; daemons = [ nodeName ]; };
    osd = {
      enable = true;
      daemons = [ osd ];
      # domena awarii = host: każda z 3 kopii na innym węźle
      extraConfig."osd crush chooseleaf type" = "1";
    };

    # narzędzia klienckie (ceph, rbd) w PATH usługi Incus
    client.enable = true;
  };

  # Demony mają wracać zawsze, także po dłuższej awarii sieci
  # (domyślne limity restartów potrafią zostawić je wyłączone na stałe).
  systemd.services = lib.genAttrs [ "ceph-mon-${nodeName}" "ceph-mgr-${nodeName}" "ceph-osd-${osd}" ] (_: {
    serviceConfig = {
      Restart = lib.mkForce "always";
      RestartSec = lib.mkForce "10";
    };
    startLimitIntervalSec = lib.mkForce 0;
  });

  # OSD leży na LVM (ceph-volume) - wolumeny muszą być aktywne przed startem OSD
  services.lvm.enable = true;

  # Sieć Ceph jest izolowana i służy tylko węzłom
  networking.firewall.trustedInterfaces = [ "ceph0" ];

  environment.systemPackages = with pkgs; [ ceph lvm2 ];
}
