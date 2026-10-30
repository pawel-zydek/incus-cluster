#!/usr/bin/env bash
# Jednorazowa inicjalizacja klastra Ceph na zainstalowanych węzłach.
# Uruchamiać na laptopie z katalogu repozytorium: ./scripts/ceph-bootstrap.sh
# Łączy się z węzłami jako root (klucz z laptopa, jak przy nixos-rebuild).
#
#   ./scripts/ceph-bootstrap.sh          # nowy klaster
#   ZAP=1 ./scripts/ceph-bootstrap.sh    # dodatkowo czyści dyski OSD (np. resztki
#                                        # poprzedniej puli ZFS Incusa) - KASUJE DANE
#
# Kolejność (procedura "manual deployment" z dokumentacji Ceph):
#   1. klucze + monmap ze wszystkimi trzema MON-ami (na pierwszym węźle)
#   2. rozesłanie kluczy, ceph-mon --mkfs i start MON na każdym węźle -> kworum
#   3. MGR na każdym węźle
#   4. OSD (BlueStore na LVM, ceph-volume) na każdym węźle, numer z nodes.nix
#   5. pula RBD dla Incusa
set -euo pipefail
cd "$(dirname "$0")/.."

# NODES, FSID, POOL, OSD_DISK, IP_<węzeł>, CEPHIP_<węzeł>, OSD_<węzeł>
eval "$(nix eval --raw --file scripts/vars.nix)"

ip_of()     { local v="IP_$1";     echo "${!v}"; }
cephip_of() { local v="CEPHIP_$1"; echo "${!v}"; }
osd_of()    { local v="OSD_$1";    echo "${!v}"; }

on() { # on <węzeł> <polecenie...>  - jako root na węźle
  local n="$1"; shift
  ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$(ip_of "$n")" "$@"
}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mBŁĄD: %s\033[0m\n' "$*" >&2; exit 1; }

wait_for() { # wait_for <sekundy> <opis> <polecenie...>
  local timeout="$1" desc="$2" start; shift 2
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) - start > timeout )) && die "przekroczono czas oczekiwania: $desc"
    sleep 3
  done
}

N1="${NODES[0]}"
B=/var/lib/ceph/bootstrap   # katalog roboczy na węzłach

copy_file() { # copy_file <z_węzła> <na_węzeł> <ścieżka> <właściciel> <tryb>
  on "$1" "cat '$3'" | on "$2" "install -d -o ceph -g ceph -m 750 '$(dirname "$3")' && cat > '$3' && chown $4 '$3' && chmod $5 '$3'"
}

# --- 0. kontrola ---------------------------------------------------------------
log "Kontrola węzłów"
for n in "${NODES[@]}"; do
  on "$n" true || die "brak SSH do root@$(ip_of "$n")"
  on "$n" "systemctl cat ceph-mon-$n >/dev/null" || die "$n: brak usługi ceph-mon-$n (czy wdrożono konfigurację z gałęzi ceph?)"
  on "$n" "test ! -e /var/lib/ceph/mon/ceph-$n/keyring" \
    || die "$n: MON już zainicjalizowany - klaster istnieje. Żeby zacząć od zera, przeinstaluj węzły."
  on "$n" "test -b $OSD_DISK" || die "$n: brak dysku OSD $OSD_DISK"
  on "$n" "ping -c1 -W2 $(cephip_of "${NODES[-1]}") >/dev/null" || die "$n: brak łączności w sieci Ceph"
  on "$n" "chronyc tracking | grep -q 'Leap status *: Normal'" \
    || echo "  uwaga: $n - chrony jeszcze nie zsynchronizował czasu"
  echo "  $n - OK"
done

# --- 1. klucze i monmap --------------------------------------------------------
log "Klucze i monmap ($N1)"
monargs=""
for n in "${NODES[@]}"; do
  ip="$(cephip_of "$n")"
  monargs+=" --addv $n '[v2:$ip:3300,v1:$ip:6789]'"
done

on "$N1" bash -s <<EOF
set -euo pipefail
install -d -o ceph -g ceph -m 750 $B /var/lib/ceph/bootstrap-osd

# klucz MON-ów
ceph-authtool --create-keyring $B/ceph.mon.keyring --gen-key -n mon. --cap mon 'allow *'

# administrator klastra (z tego klucza korzysta też Incus)
ceph-authtool --create-keyring /etc/ceph/ceph.client.admin.keyring --gen-key -n client.admin \
  --cap mon 'allow *' --cap osd 'allow *' --cap mds 'allow *' --cap mgr 'allow *'

# klucz do zakładania OSD
ceph-authtool --create-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring --gen-key -n client.bootstrap-osd \
  --cap mon 'profile bootstrap-osd' --cap mgr 'allow r'

ceph-authtool $B/ceph.mon.keyring --import-keyring /etc/ceph/ceph.client.admin.keyring
ceph-authtool $B/ceph.mon.keyring --import-keyring /var/lib/ceph/bootstrap-osd/ceph.keyring

# monmap z adresami v2+v1 wszystkich MON-ów; szyfr aes256k jak w testach NixOS
monmaptool --create --fsid $FSID \
  --auth-allowed-ciphers aes256k --auth-preferred-cipher aes256k --auth-service-cipher aes256k \
  $monargs $B/monmap

chown ceph:ceph $B/ceph.mon.keyring $B/monmap /var/lib/ceph/bootstrap-osd/ceph.keyring
chmod 600 $B/ceph.mon.keyring /var/lib/ceph/bootstrap-osd/ceph.keyring
chown root:ceph /etc/ceph/ceph.client.admin.keyring
chmod 640 /etc/ceph/ceph.client.admin.keyring
EOF

# --- 2. MON-y --------------------------------------------------------------------
log "Rozesłanie kluczy"
for n in "${NODES[@]:1}"; do
  copy_file "$N1" "$n" "$B/ceph.mon.keyring" ceph:ceph 600
  copy_file "$N1" "$n" "$B/monmap" ceph:ceph 644
  copy_file "$N1" "$n" /etc/ceph/ceph.client.admin.keyring root:ceph 640
  copy_file "$N1" "$n" /var/lib/ceph/bootstrap-osd/ceph.keyring ceph:ceph 600
  echo "  $n - OK"
done

log "Inicjalizacja i start MON-ów"
for n in "${NODES[@]}"; do
  on "$n" bash -s <<EOF
set -euo pipefail
runuser -u ceph -- ceph-mon --mkfs -i $n --monmap $B/monmap --keyring $B/ceph.mon.keyring
runuser -u ceph -- touch /var/lib/ceph/mon/ceph-$n/done
systemctl start ceph-mon-$n
EOF
  echo "  $n - uruchomiony"
done

log "Czekam na kworum MON-ów"
wait_for 180 "kworum MON" on "$N1" \
  "timeout 10 ceph quorum_status -f json | jq -e '.quorum_names | length == ${#NODES[@]}'"
on "$N1" "ceph config set mon auth_allow_insecure_global_id_reclaim false"
on "$N1" "ceph mon stat"

# --- 3. MGR-y ------------------------------------------------------------------------
log "MGR-y"
for n in "${NODES[@]}"; do
  on "$n" bash -s <<EOF
set -euo pipefail
install -d -o ceph -g ceph /var/lib/ceph/mgr/ceph-$n
ceph auth get-or-create mgr.$n mon 'allow profile mgr' osd 'allow *' mds 'allow *' \
  > /var/lib/ceph/mgr/ceph-$n/keyring
chown ceph:ceph /var/lib/ceph/mgr/ceph-$n/keyring
chmod 600 /var/lib/ceph/mgr/ceph-$n/keyring
sync
systemctl start ceph-mgr-$n
EOF
  echo "  $n - uruchomiony"
done
wait_for 120 "aktywny MGR" on "$N1" "ceph mgr stat -f json | jq -e '.available == true'"

# --- 4. OSD ------------------------------------------------------------------------
for n in "${NODES[@]}"; do
  id="$(osd_of "$n")"
  log "OSD.$id na $n ($OSD_DISK)"
  on "$n" ZAP="${ZAP:-0}" bash -s <<EOF
set -euo pipefail
dev=\$(readlink -f $OSD_DISK)

if [ "\$ZAP" = 1 ]; then
  echo "czyszczę \$dev"
  ceph-volume lvm zap --destroy "\$dev"
fi

if [ -n "\$(lsblk -no FSTYPE,PTTYPE "\$dev" | tr -d ' \n')" ] || [ "\$(lsblk -no NAME "\$dev" | wc -l)" -gt 1 ]; then
  echo "Dysk \$dev nie jest pusty. Uruchom ponownie z ZAP=1 (skasuje dysk)." >&2
  exit 1
fi

uuid=\$(uuidgen)
ceph-volume lvm prepare --objectstore bluestore --no-systemd --osd-id $id --osd-fsid "\$uuid" --data "\$dev"
# aktywacja bez tmpfs: katalog OSD zostaje na dysku systemowym i przeżywa restart
ceph-volume lvm deactivate $id "\$uuid"
ceph-volume lvm activate --no-tmpfs --no-systemd $id "\$uuid"
sync
systemctl start ceph-osd-$id
EOF
done

log "Czekam na OSD"
wait_for 300 "wszystkie OSD up/in" on "$N1" \
  "ceph osd stat -f json | jq -e '.num_osds == ${#NODES[@]} and .num_up_osds == .num_osds and .num_in_osds == .num_osds'"

# --- 5. pula dla Incusa -------------------------------------------------------------
log "Pula RBD '$POOL'"
on "$N1" bash -s <<EOF
set -euo pipefail
ceph osd pool ls | grep -qx '$POOL' || ceph osd pool create $POOL
ceph osd pool set $POOL size 3
ceph osd pool set $POOL min_size 2
ceph osd pool set $POOL pg_autoscale_mode on
rbd pool init $POOL
EOF

# pliki bootstrapu (monmap, klucz MON) nie są już potrzebne
for n in "${NODES[@]}"; do on "$n" "rm -rf $B"; done

log "Stan klastra (czekam do 5 min na HEALTH_OK)"
for _ in $(seq 60); do
  on "$N1" "ceph health" | grep -q HEALTH_OK && break
  sleep 5
done
on "$N1" "ceph -s"
echo
echo "Następny krok: założenie klastra Incus (README, krok 4)."
