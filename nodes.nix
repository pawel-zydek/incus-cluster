# Dane węzłów klastra - jedno miejsce, z którego korzysta cała konfiguracja
# (flake.nix tworzy z nich hosty, modules/network.nix adresy i /etc/hosts,
# modules/ceph.nix i scripts/ceph-bootstrap.sh adresy Ceph i numery OSD).
#
# Każdy węzeł ma 3 karty sieciowe (rozpoznawane po MAC):
#   mac     -> mgmt0  sieć zarządzająca "incuslab" (SSH, Incus, heartbeat klastra)
#   cephMac -> ceph0  sieć Ceph "incuslab-ceph" (izolowana)
#   otMac   -> ot0    trunk VLAN-ów OT "incuslab-ot" (bez adresu IP na węźle)
# Adresy MAC muszą się zgadzać z libvirt/create-vms.sh (52:54:00:5X:00:1N).
{
  incus1 = {
    ip = "192.168.150.11"; mac = "52:54:00:50:00:11"; hostId = "108bcd5e";
    cephIp = "10.10.10.11"; cephMac = "52:54:00:51:00:11";
    otMac = "52:54:00:52:00:11";
    osdId = 0;
  };
  incus2 = {
    ip = "192.168.150.12"; mac = "52:54:00:50:00:12"; hostId = "9e632de2";
    cephIp = "10.10.10.12"; cephMac = "52:54:00:51:00:12";
    otMac = "52:54:00:52:00:12";
    osdId = 1;
  };
  incus3 = {
    ip = "192.168.150.13"; mac = "52:54:00:50:00:13"; hostId = "1f061477";
    cephIp = "10.10.10.13"; cephMac = "52:54:00:51:00:13";
    otMac = "52:54:00:52:00:13";
    osdId = 2;
  };
}
