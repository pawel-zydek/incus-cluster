# Sieć węzła - trzy karty, nazwy nadane po adresie MAC (dane w nodes.nix):
#
#   mgmt0  192.168.150.0/24  zarządzanie: SSH, API/UI Incus, heartbeat klastra (NAT przez laptopa)
#   ceph0  10.10.10.0/24     ruch Ceph - izolowana sieć tylko dla węzłów, bez bramy
#   ot0    trunk VLAN-ów OT  BEZ adresu IP. Interfejsy VLAN (ot0.110...) i mostki tworzy
#                            sam Incus (preseed/), dzięki czemu sieci są "zarządzane przez
#                            Incus" i VM-ki mogą być automatycznie przenoszone między węzłami.
#
# Klaster Incusa źle znosi zmianę adresu członka, dlatego nie polegamy na DHCP.
{ lib, nodes, nodeName, ... }:
let
  node = nodes.${nodeName};

  # Dopasowanie po PermanentMACAddress, nie MACAddress: interfejsy VLAN (ot0.110)
  # dziedziczą MAC karty ot0 i przy MACAddress udev próbowałby je też nazwać "ot0".
  link = name: mac: {
    matchConfig.PermanentMACAddress = mac;
    linkConfig.Name = name;
  };
in
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;

    links = {
      "10-mgmt0" = link "mgmt0" node.mac;
      "10-ceph0" = link "ceph0" node.cephMac;
      "10-ot0" = link "ot0" node.otMac;
    };

    networks = {
      "10-mgmt0" = {
        matchConfig.Name = "mgmt0";
        address = [ "${node.ip}/24" ];
        gateway = [ "192.168.150.1" ];       # libvirt (NAT do internetu)
        dns = [ "192.168.150.1" ];
        networkConfig.IPv6AcceptRA = false;
      };

      "10-ceph0" = {
        matchConfig.Name = "ceph0";
        address = [ "${node.cephIp}/24" ];
        networkConfig = {
          IPv6AcceptRA = false;
          LinkLocalAddressing = "no";
        };
      };

      # trunk: tylko podniesienie interfejsu, żadnych adresów
      "10-ot0" = {
        matchConfig.Name = "ot0";
        networkConfig = {
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
          ConfigureWithoutCarrier = true;
        };
        linkConfig.RequiredForOnline = "no";
      };
    };
  };

  # Wszystkie węzły znają się po nazwie
  networking.hosts = lib.mapAttrs' (name: n: lib.nameValuePair n.ip [ name ]) nodes;
}
