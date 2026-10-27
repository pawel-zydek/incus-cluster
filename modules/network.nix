# Sieć węzła: stały adres w sieci libvirta "incuslab" (192.168.150.0/24).
# Klaster Incusa źle znosi zmianę adresu członka, dlatego nie polegamy na DHCP.
{ lib, nodes, nodeName, ... }:
let
  node = nodes.${nodeName};
in
{
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.MACAddress = node.mac;     # karta rozpoznana po MAC, nazwa (enp1s0...) bez znaczenia
      address = [ "${node.ip}/24" ];
      gateway = [ "192.168.150.1" ];         # libvirt (NAT do internetu)
      dns = [ "192.168.150.1" ];
      networkConfig.IPv6AcceptRA = false;
    };
  };

  # Wszystkie węzły znają się po nazwie
  networking.hosts = lib.mapAttrs' (name: n: lib.nameValuePair n.ip [ name ]) nodes;
}
