# Parametry wspólne dla całego klastra (dane pojedynczych węzłów są w nodes.nix).
{
  ceph = {
    # nowy klaster = nowe UUID (uuidgen)
    fsid = "45bc435d-eec4-4b84-b923-d66303f7eefa";
    network = "10.10.10.0/24";   # public + cluster network (w produkcji można rozdzielić)
    pool = "incus";              # pula RBD na dyski VM, z niej korzysta Incus

    # Dysk OSD - drugi dysk VM ma w libvirt numer seryjny "incus-data",
    # więc ścieżka jest taka sama na każdym węźle.
    osdDisk = "/dev/disk/by-id/virtio-incus-data";

    # RAM na jeden OSD: lab (8 GB na węzeł) 1 GiB, produkcja 4 GiB (domyślne Ceph)
    osdMemoryTarget = "1073741824";
  };

  # Ceph wymaga zsynchronizowanego czasu. Produkcja: serwery NTP zakładu.
  ntpServers = [ "0.pl.pool.ntp.org" "1.pl.pool.ntp.org" "2.pl.pool.ntp.org" ];

  # Samoogrodzenie - patrz modules/self-fence.nix.
  # timeout musi być wyraźnie krótszy niż cluster.healing_threshold Incusa (60 s).
  fencing = {
    enable = true;
    timeout = 20;    # sekundy bez kworum, po których węzeł z VM-kami się restartuje
    interval = 2;
  };
}
