# Incus.
# Klaster zakładamy ręcznie plikami z katalogu preseed/ (patrz README).
# Opcja virtualisation.incus.preseed uruchamia "incus admin init" przy każdym starcie usługi,
# co pasuje do pojedynczego serwera, ale nie do dołączania węzłów tokenem.
#
# Dyski instancji leżą w Ceph (pula "ceph" w preseed/), więc instancja może zostać
# uruchomiona na dowolnym węźle - także automatycznie, gdy jej węzeł padnie.
{ ... }:
{
  virtualisation.incus = {
    enable = true;      # domyślnie pakiet incus-lts
    ui.enable = true;   # panel WWW: https://<adres węzła>:8443
  };

  # Incus podłącza dyski RBD przez moduł jądra (krbd)
  boot.kernelModules = [ "rbd" ];

  # Incus startuje po lokalnych demonach Ceph (sama kolejność, bez twardej zależności -
  # Incus musi wstać także wtedy, gdy Ceph jest zdegradowany)
  systemd.services.incus.after = [ "ceph.target" ];

  # Wymóg modułu Incusa w NixOS (zapora na nftables zamiast iptables)
  networking.nftables.enable = true;

  networking.firewall = {
    allowedTCPPorts = [ 8443 ];               # API i komunikacja w klastrze
    trustedInterfaces = [ "incusbr0" ];       # DHCP/DNS dla instancji na mostku Incusa
  };

  users.users.pawel.extraGroups = [ "incus-admin" ];
}
