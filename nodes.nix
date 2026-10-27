# Dane węzłów klastra - jedno miejsce, z którego korzysta cała konfiguracja
# (flake.nix tworzy z nich hosty, modules/network.nix adresy i /etc/hosts).
# Adres MAC musi się zgadzać z libvirt/create-vms.sh i libvirt/incuslab.xml.
{
  incus1 = { ip = "192.168.150.11"; mac = "52:54:00:50:00:11"; hostId = "108bcd5e"; };
  incus2 = { ip = "192.168.150.12"; mac = "52:54:00:50:00:12"; hostId = "9e632de2"; };
  incus3 = { ip = "192.168.150.13"; mac = "52:54:00:50:00:13"; hostId = "1f061477"; };
}
