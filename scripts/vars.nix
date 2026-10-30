# Zamienia nodes.nix i cluster.nix na zmienne powłoki dla skryptów:
#   eval "$(nix eval --raw --file scripts/vars.nix)"
let
  nodes = import ../nodes.nix;
  cluster = import ../cluster.nix;
  names = builtins.attrNames nodes;
  perNode = n: ''
    IP_${n}=${nodes.${n}.ip}
    CEPHIP_${n}=${nodes.${n}.cephIp}
    OSD_${n}=${toString nodes.${n}.osdId}
  '';
in
''
  NODES=(${toString names})
  FSID=${cluster.ceph.fsid}
  POOL=${cluster.ceph.pool}
  OSD_DISK=${cluster.ceph.osdDisk}
''
+ builtins.concatStringsSep "" (map perNode names)
