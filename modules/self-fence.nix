# Samoogrodzenie (self-fencing) - odpowiednik watchdoga HA z Proxmoxa.
#
# Problem: Incus uznaje węzeł za martwy, gdy ten nie odpowiada na heartbeat i ping w sieci
# zarządzającej, a po cluster.healing_threshold uruchamia jego VM-ki na innych węzłach.
# Jeśli węzeł jest tylko ODCIĘTY (np. padł port przełącznika), a sieć Ceph ma sprawną,
# jego VM-ki dalej piszą na te same dyski RBD -> dwa Windowsy na jednym dysku = zniszczone dane.
# Incus z krbd nie zakłada blokad na obrazach RBD, a Incus 7.0 LTS nie daje jeszcze
# zdarzenia, na które można by zareagować wyłączeniem węzła przed przeniesieniem VM-ek.
#
# Rozwiązanie: każdy węzeł sam pilnuje, czy widzi większość klastra w sieci zarządzającej
# (tej samej, którą ocenia Incus). Gdy przez `timeout` sekund jej nie widzi i ma uruchomione
# VM-ki - natychmiast się restartuje (sysrq 'b', bez sync). Dzieje się to dużo wcześniej,
# niż Incus zacznie przenosić VM-ki (offline 20 s + healing_threshold 60 s).
#
# Zabezpieczenia przed zbędnym restartem:
#  - mechanizm "uzbraja się" dopiero, gdy węzeł raz zobaczy kworum
#    (start pojedynczego węzła albo całego klastra go nie zrestartuje),
#  - węzeł bez uruchomionych VM-ek się nie restartuje (nie ma czego chronić).
#
# Ograniczenie: awaria całej sieci zarządzającej (np. jedynego przełącznika) zrestartuje
# wszystkie węzły z VM-kami - tak samo jak w Proxmox HA. W produkcji: bond do 2 przełączników.
{ lib, pkgs, nodes, nodeName, cluster, ... }:
let
  cfg = cluster.fencing;
  peers = lib.mapAttrsToList (_: n: n.ip) (lib.filterAttrs (name: _: name != nodeName) nodes);
  quorum = (builtins.length (builtins.attrNames nodes)) / 2 + 1;
in
lib.mkIf cfg.enable {
  systemd.services.self-fence = {
    description = "Samoogrodzenie węzła przy utracie kworum w sieci zarządzającej";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = with pkgs; [ iputils procps coreutils ];

    serviceConfig = {
      Restart = "always";
      RestartSec = "5";
    };

    script = ''
      PEERS="${lib.concatStringsSep " " peers}"
      QUORUM=${toString quorum}
      TIMEOUT=${toString cfg.timeout}
      INTERVAL=${toString cfg.interval}

      armed=0
      lost_since=0

      reachable() {
        local n=0 ip
        for ip in $PEERS; do
          ping -c1 -W1 -q "$ip" >/dev/null 2>&1 && n=$((n + 1))
        done
        echo "$n"
      }

      has_vms() { pgrep -f qemu-system-x86_64 >/dev/null 2>&1; }

      echo "self-fence: sąsiedzi: $PEERS, kworum: $QUORUM, limit: $TIMEOUT s"

      while true; do
        seen=$(( $(reachable) + 1 ))      # +1 = ten węzeł

        if [ "$seen" -ge "$QUORUM" ]; then
          if [ "$armed" -eq 0 ]; then
            echo "self-fence: kworum osiągnięte ($seen) - mechanizm uzbrojony"
            armed=1
          fi
          if [ "$lost_since" -ne 0 ]; then
            echo "self-fence: kworum wróciło ($seen)"
            lost_since=0
          fi

        elif [ "$armed" -eq 1 ]; then
          now=$(date +%s)
          if [ "$lost_since" -eq 0 ]; then
            lost_since=$now
            echo "self-fence: UTRATA KWORUM (widzę $seen) - odliczam $TIMEOUT s"
          elif [ $((now - lost_since)) -ge "$TIMEOUT" ]; then
            if has_vms; then
              echo "self-fence: brak kworum od $((now - lost_since)) s, są VM-ki - RESTART WĘZŁA"
              sleep 0.5                    # żeby komunikat zdążył do journala
              echo b > /proc/sysrq-trigger
            else
              echo "self-fence: brak kworum, ale brak VM-ek - nie restartuję"
              lost_since=$now
            fi
          fi
        fi

        sleep "$INTERVAL"
      done
    '';
  };
}
