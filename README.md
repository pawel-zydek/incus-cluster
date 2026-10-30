# Klaster Incus + Ceph na NixOS

Testowe środowisko: 3 węzły NixOS z Incusem i Cephem połączone w klaster odporny na awarię
jednego węzła. Docelowo pod VM-ki SCADA (Windows 11 + WinCC) i Windows Server w sieci OT.
Węzły to maszyny wirtualne KVM na laptopie (`pg`), a cała konfiguracja jest tutaj -
na węzłach nie ma kopii repozytorium, wdraża się je z laptopa.

Jest to repozytorium do nauki.

## Jak to działa

- Dyski instancji leżą w **Ceph** (3 kopie, po jednej na węźle). Awaria węzła nie przerywa
  zapisu - Ceph pracuje dalej na dwóch kopiach.
- **Incus** po 60 s od uznania węzła za martwy (`cluster.healing_threshold`) uruchamia jego
  instancje na pozostałych węzłach. Windows i WinCC startują od nowa (to restart, nie migracja).
- **Samoogrodzenie** (`modules/self-fence.nix`): węzeł odcięty od sieci zarządzającej, ale żywy,
  sam się restartuje po 20 s - zanim Incus uruchomi kopie jego VM-ek gdzie indziej. Bez tego
  dwie kopie jednej VM-ki pisałyby na ten sam dysk.
- Sieci OT to **VLAN-y na trunku**, tworzone przez Incus. Incus przenosi tylko instancje, których
  wszystkie urządzenia (dysk, sieć) są dostępne na innych węzłach - mostek zrobiony ręcznie
  w NixOS blokowałby to po cichu.

| czas | co się dzieje po awarii węzła |
|---|---|
| 0 s | węzeł przestaje odpowiadać |
| ~20 s | Incus uznaje węzeł za offline; węzeł tylko odcięty od sieci restartuje się sam |
| ~80 s | instancje startują na pozostałych węzłach |
| +1–3 min | start Windows i WinCC Runtime |

## Węzły

| Węzeł | mgmt0 (zarządzanie) | ceph0 (Ceph) | OSD | RAM / vCPU | Dyski |
|---|---|---|---|---|---|
| `incus1` | 192.168.150.11 | 10.10.10.11 | osd.0 | 8 GB / 4 | system 30 GB + OSD 60 GB |
| `incus2` | 192.168.150.12 | 10.10.10.12 | osd.1 | 8 GB / 4 | system 30 GB + OSD 60 GB |
| `incus3` | 192.168.150.13 | 10.10.10.13 | osd.2 | 8 GB / 4 | system 30 GB + OSD 60 GB |

| Sieć libvirta | Karta węzła | Adresacja | Do czego |
|---|---|---|---|
| `incuslab` | `mgmt0` | 192.168.150.0/24, brama i DNS .1, NAT | SSH, API i panel Incusa, heartbeat klastra |
| `incuslab-ceph` | `ceph0` | 10.10.10.0/24, izolowana | ruch Ceph |
| `incuslab-ot` | `ot0` | trunk, bez IP na węzłach | VLAN 110 `ot-scada`, 120 `ot-srv`, 130 `ot-plc` |

- Sieć instancji testowych (`incusbr0`): 10.150.0.0/24, NAT przez węzeł, na którym działa instancja.
- Dysk systemowy (`incus-sys`): ZFS `rpool` **bez szyfrowania**, żeby węzeł sam wstawał po restarcie.
- Dysk danych (`incus-data`): w całości OSD Ceph (BlueStore).
- Jądro 7.2 zamiast domyślnego 6.18 - Ceph 20 wymaga go do podłączania dysków RBD (szczegóły w `modules/base.nix`).

Karty sieciowe dostają nazwy po adresie MAC (`nodes.nix`), a dyski mają w libvirt numery seryjne,
więc jedna konfiguracja pasuje do wszystkich węzłów.

## Struktura repozytorium

```
flake.nix                 # wejścia (nixpkgs, disko) i hosty incus1..3 tworzone z nodes.nix
nodes.nix                 # IP, MAC-i, hostId, numer OSD każdego węzła - jedyne miejsce z tymi danymi
cluster.nix               # parametry całego klastra: Ceph (fsid, sieć, pula), NTP, samoogrodzenie
modules/
  hardware.nix            # wspólny "hardware-configuration" dla VM (virtio, watchdog)
  disko.nix               # układ dysku systemowego: ESP + rpool
  base.nix                # boot, ZFS, jądro, watchdog, chrony, nix, użytkownik, SSH
  network.nix             # karty mgmt0/ceph0/ot0, adresy, /etc/hosts
  ceph.nix                # MON + MGR + OSD na każdym węźle, ceph.conf
  incus.nix               # Incus, panel WWW, nftables, zapora
  self-fence.nix          # samoogrodzenie węzła po utracie kworum
libvirt/
  incuslab.xml            # sieć zarządzająca (NAT)
  incuslab-ceph.xml       # sieć Ceph
  incuslab-ot.xml         # trunk OT
  create-vms.sh           # tworzy 3 VM (virt-install)
scripts/
  ceph-bootstrap.sh       # jednorazowa inicjalizacja Ceph
  vars.nix                # nodes.nix + cluster.nix -> zmienne dla skryptu
preseed/
  incus1-bootstrap.yaml   # założenie klastra na incus1: pula Ceph, sieci OT, profile Windows
  join.yaml.template      # dołączanie incus2 i incus3
```

---

# 0. Usunięcie poprzedniego klastra

Poprzednie węzły miały jedną kartę i lokalną pulę ZFS - instalujemy je od nowa.

```bash
for n in incus1 incus2 incus3; do
  virsh destroy $n 2>/dev/null
  virsh undefine $n --nvram --remove-all-storage     # usuwa VM RAZEM z dyskami
done
virsh list --all
```

Sieć `incuslab` zostaje bez zmian.

Stare snapshoty (`rpool/vm@wezly-zainstalowane`, `rpool/vm@klaster-czysty`) przywróciłyby
poprzedni klaster. Snapshot obejmuje też obraz Windows 11 - usuń tylko te, których nie potrzebujesz:

```bash
zfs list -t snapshot rpool/vm
sudo zfs destroy rpool/vm@klaster-czysty
sudo zfs destroy rpool/vm@wezly-zainstalowane
```

---

# 1. Przygotowanie laptopa (jednorazowo)

### 1a. Zagnieżdżona wirtualizacja

W repozytorium `nixos-config`, w `modules/kvm.nix` musi być:

```nix
boot.extraModprobeConfig = "options kvm_intel nested=1";
```

Sprawdzenie (po przebudowaniu i restarcie):

```bash
cat /sys/module/kvm_intel/parameters/nested     # ma być Y
```

### 1b. Obraz instalatora

Pobierz *Minimal ISO image* NixOS 26.05 (64-bit Intel/AMD) i skopiuj go pod stałą nazwą:

```bash
sudo cp ~/Pobrane/nixos-minimal-26.05*.iso /var/lib/libvirt/images/nixos-minimal.iso
```

### 1c. Sieci

```bash
cd ~/incus-cluster
virsh net-info incuslab >/dev/null 2>&1 || virsh net-define libvirt/incuslab.xml   # jeśli jeszcze nie ma
for net in incuslab-ceph incuslab-ot; do
  virsh net-define libvirt/$net.xml
done
for net in incuslab incuslab-ceph incuslab-ot; do
  virsh net-start $net 2>/dev/null
  virsh net-autostart $net
done
virsh net-list --all
```

`virsh` łączy się z `qemu:///system` (zmienna `LIBVIRT_DEFAULT_URI` z `kvm.nix`), więc `sudo` nie jest potrzebne.

### 1d. Maszyny wirtualne

```bash
./libvirt/create-vms.sh
virsh list --all
```

Skrypt tworzy `incus1`, `incus2`, `incus3` (3 karty sieciowe, 2 dyski, watchdog) i uruchamia je
z instalatora. Istniejące maszyny pomija, więc można go uruchomić ponownie.

> **Pamięć:** 3 × 8 GB to 24 GB. Do tego ARC ZFS laptopa i system - przy 32 GB jest ciasno.
> Na czas laboratorium nie uruchamiaj Windows 11 na laptopie i ogranicz ARC laptopa, np. do 4 GB
> (`boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ];` w `nixos-config`) albo doraźnie:
> `echo 4294967296 | sudo tee /sys/module/zfs/parameters/zfs_arc_max`.
> 6 GB na węzeł wystarczy dla samego Cepha i Incusa, ale nie zmieści już VM-ki Windows.

---

# 2. Instalacja węzła (dla każdego: incus1, incus2, incus3)

Przykład dla `incus1`; dla pozostałych zmień nazwę i adres.

### 2a. Dostęp SSH do instalatora

W virt-managerze otwórz konsolę `incus1` i ustaw tymczasowe hasło użytkownika instalatora:

```bash
passwd
```

Na laptopie skopiuj swój klucz do instalatora (poda hasło z kroku wyżej):

```bash
ssh-keygen -R 192.168.150.11       # stary klucz hosta z poprzedniego klastra
ssh-copy-id -o StrictHostKeyChecking=no nixos@192.168.150.11
```

### 2b. Instalacja przez nixos-anywhere

```bash
cd ~/incus-cluster
nix run github:nix-community/nixos-anywhere -- \
  --flake .#incus1 \
  --target-host nixos@192.168.150.11 \
  --no-reboot
```

nixos-anywhere łączy się przez SSH, uruchamia disko (**kasuje dysk systemowy VM**)
i instaluje system z tego repozytorium. Dysk OSD pozostaje pusty.

Pierwsza instalacja trwa dłużej: jądro 7.2 i ZFS dla niego mogą nie być jeszcze w cache NixOS
i wtedy budują się na laptopie.

### 2c. Eksport puli i pierwszy start z dysku

Przy `--no-reboot` nixos-anywhere **nie eksportuje** puli `rpool`. Bez eksportu pula zostaje oznaczona
jako używana przez instalator i zainstalowany system odmawia jej importu (start kończy się w trybie awaryjnym).

```bash
ssh nixos@192.168.150.11 'sudo umount -Rl /mnt; sudo zpool export -a; sudo zpool list'
# "no pools available" = pula wyeksportowana
virsh destroy incus1      # wyłączenie instalatora
virsh start incus1        # start już z dysku
```

Jeśli mimo to znów uruchomi się instalator, wysuń płytę i uruchom ponownie:

```bash
virsh domblklist incus1                         # nazwa napędu z ISO, np. sda
virsh change-media incus1 sda --eject --config
virsh destroy incus1 && virsh start incus1
```

### 2d. Sprawdzenie i hasło użytkownika

Adres instalatora i systemu jest ten sam, ale klucz hosta SSH jest inny, więc najpierw usuwamy stary wpis:

```bash
ssh-keygen -R 192.168.150.11
ssh root@192.168.150.11 'hostname; uname -r; ip -br addr; systemctl is-active incus'
ssh -t root@192.168.150.11 passwd pawel       # hasło do konsoli i sudo
```

`ip -br addr` ma pokazać `mgmt0` (192.168.150.11), `ceph0` (10.10.10.11) i `ot0` bez adresu.

Powtórz kroki 2a–2d dla `incus2` (192.168.150.12) i `incus3` (192.168.150.13).

> Wygodniej: dopisz węzły do `~/.ssh/config` na laptopie, wtedy wystarczy `ssh incus1`:
>
> ```
> Host incus1
>   HostName 192.168.150.11
> Host incus2
>   HostName 192.168.150.12
> Host incus3
>   HostName 192.168.150.13
> ```

### 2e. Punkt kontrolny

Obrazy VM leżą na datasecie `rpool/vm` laptopa, więc jeden snapshot zapisuje cały stan laboratorium:

```bash
virsh shutdown incus1; virsh shutdown incus2; virsh shutdown incus3
sudo zfs snapshot rpool/vm@ceph-wezly-zainstalowane
```

---

# 3. Ceph

Wszystkie trzy węzły muszą być uruchomione.

```bash
cd ~/incus-cluster
./scripts/ceph-bootstrap.sh
```

Skrypt (szczegóły w komentarzach w pliku):

1. tworzy klucze i mapę MON-ów (`monmap`) na `incus1` i rozsyła je na pozostałe węzły,
2. inicjalizuje i uruchamia 3 MON-y - czeka na kworum,
3. uruchamia 3 MGR-y,
4. zakłada OSD na dysku `incus-data` każdego węzła (BlueStore),
5. tworzy pulę RBD `incus` (3 kopie, zapis możliwy przy 2).

Usługi Ceph są zdefiniowane w NixOS (`modules/ceph.nix`) od instalacji, ale startują dopiero
wtedy, gdy skrypt utworzy ich klucze. Po restarcie węzła startują już same.

Sprawdzenie:

```bash
ssh root@192.168.150.11 ceph -s          # HEALTH_OK, 3 mon, 3 osd up/in
ssh root@192.168.150.11 ceph osd tree    # każdy OSD pod innym hostem
```

Jeśli dysk OSD ma resztki (np. po poprzedniej puli ZFS): `ZAP=1 ./scripts/ceph-bootstrap.sh`.

---

# 4. Założenie klastra Incus

### 4a. Pierwszy węzeł

Preseed tworzy od razu pulę `ceph`, sieć `incusbr0`, sieci OT i profile `windows-scada` / `windows-server`.

```bash
cd ~/incus-cluster
ssh root@192.168.150.11 incus admin init --preseed < preseed/incus1-bootstrap.yaml
ssh root@192.168.150.11 incus cluster list
```

### 4b. Dołączenie incus2 i incus3

```bash
for n in 2 3; do
  TOKEN=$(ssh root@192.168.150.11 incus cluster add incus$n | tail -n1)
  sed -e "s/NODE_NAME/incus$n/" \
      -e "s/NODE_IP/192.168.150.1$n/" \
      -e "s|TOKEN|$TOKEN|" \
      preseed/join.yaml.template \
    | ssh root@192.168.150.1$n incus admin init --preseed
done

ssh root@192.168.150.11 incus cluster list
```

Wszystkie trzy węzły powinny mieć stan `ONLINE`, a w kolumnie ról `database` (3 węzły = kworum bazy).

### 4c. Automatyczne odtwarzanie instancji

```bash
ssh root@192.168.150.11 incus config set cluster.healing_threshold 60
```

60 s to czas od uznania węzła za offline (domyślnie po 20 s) do uruchomienia jego instancji
na innych węzłach. Musi być wyraźnie dłuższy niż `fencing.timeout` w `cluster.nix` (20 s).

### 4d. Sprawdzenie

```bash
ssh root@192.168.150.11
incus storage list                     # ceph
incus network list                     # incusbr0, ot-scada, ot-srv, ot-plc
incus profile list

incus launch images:debian/13 c1 --target incus2          # kontener na Ceph
incus launch images:debian/13 v1 --vm --target incus3     # VM na Ceph (wymaga nested)
incus list -c nsL4
incus stop v1 && incus move v1 --target incus1 && incus start v1   # przeniesienie bez kopiowania dysku
```

### 4e. Panel WWW

`https://192.168.150.11:8443` w Firefoksie na laptopie. Panel poprowadzi przez utworzenie certyfikatu
przeglądarki; certyfikat dodaje się do zaufanych poleceniem pokazanym w panelu (`incus config trust add-certificate ...`).

Snapshot po założeniu klastra (przy wyłączonych węzłach): `sudo zfs snapshot rpool/vm@ceph-klaster-czysty`.

---

# 5. VM z Windows

Na laptopie przygotuj ISO Windows i
[virtio-win](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)
(sterownik karty sieciowej i agent). Obrazy trafiają do Ceph jako woluminy, więc instalację
widać z każdego węzła.

```bash
scp ~/iso/Win11.iso ~/iso/virtio-win.iso root@192.168.150.11:/var/tmp/

ssh root@192.168.150.11
incus storage volume import ceph /var/tmp/Win11.iso win11-iso --type=iso
incus storage volume import ceph /var/tmp/virtio-win.iso virtio-win --type=iso
rm /var/tmp/*.iso

incus init scada1 --empty --vm --profile windows-scada
incus config device add scada1 install disk pool=ceph source=win11-iso boot.priority=10
incus config device add scada1 virtio  disk pool=ceph source=virtio-win
```

Instalacja z panelu WWW: *Instances → scada1 → Console*, uruchom VM z tego widoku i od razu
naciśnij klawisz (*Press any key to boot from CD*). Jeśli VM wejdzie w powłokę UEFI - restart.

- Dysk jest na NVMe, więc instalator Windows widzi go bez dodatkowych sterowników.
- W OOBE Windows 11 bez sieci: `Shift+F10` → `oobe\bypassnro`.
- Po instalacji: `virtio-win-guest-tools.exe` z płyty virtio-win (sieć, agent), adres IP statycznie
  (sieci OT nie mają DHCP), potem odłącz płyty:
  `incus config device remove scada1 install` i `incus config device remove scada1 virtio`.

Windows Server tak samo, z profilem `windows-server` (sieć `ot-srv`).

**Dostęp z laptopa do VLAN-u** (np. RDP do VM-ki w VLAN 110) - laptop działa wtedy jak stacja
inżynierska wpięta w VLAN (do restartu laptopa):

```bash
sudo ip link add link virbr152 name virbr152.110 type vlan id 110
sudo ip addr add 10.100.110.250/24 dev virbr152.110      # adresacja wg własnej koncepcji
sudo ip link set virbr152.110 up
# usunięcie: sudo ip link del virbr152.110
```

> **Pojemność labu:** na węźle 8 GB zostaje ok. 4–4,5 GB na instancje. Do testów HA wystarczy
> jedna VM Windows 4 GB - po awarii jej węzła musi się zmieścić na jednym z pozostałych.

---

# 6. Testy awarii

Powtarzaj po każdej zmianie konfiguracji. Obserwacja z węzła, który nie jest testowany:

```bash
ssh root@192.168.150.11 'watch -n2 "incus list -c nsL; ceph -s | head -12"'
```

| # | Test | Polecenie (laptop) | Oczekiwany wynik |
|---|---|---|---|
| 1 | twarde wyłączenie węzła | `virsh destroy incus2` | Ceph `HEALTH_WARN` (1 host down), instancje na innych węzłach działają bez przerwy; po ~80 s instancje z incus2 działają na incus1/incus3 |
| 2 | odcięcie sieci zarządzającej (węzeł żyje) | `virsh domif-setlink incus2 52:54:00:50:00:12 down` | po ~20 s incus2 sam się restartuje, po ~80 s jego instancje działają gdzie indziej |
| 3 | planowy serwis | procedura z „Codzienna praca” | VM-ki przeniesione przed restartem i z powrotem, Ceph wraca do `HEALTH_OK` |
| 4 | odcięcie tylko sieci Ceph | `virsh domif-setlink incus2 52:54:00:51:00:12 down` | **znane ograniczenie**: instancje na incus2 zamarzają (brak I/O), Incus ich nie przenosi, bo węzeł jest „online”. W produkcji: redundantna sieć Ceph |

Mierz czas od awarii do działającej wizualizacji.
Test 2: log samoogrodzenia po restarcie - `ssh root@192.168.150.12 journalctl -u self-fence -b -1`.

Po testach:

```bash
virsh domif-setlink incus2 52:54:00:50:00:12 up      # test 2 (test 4: ...:51:00:12)
virsh start incus2                                   # test 1
# węzeł po automatycznym odtworzeniu ma stan EVACUATED - przywrócenie (instancje wracają):
ssh root@192.168.150.11 incus cluster restore incus2
```

---

# Codzienna praca

```bash
cd ~/incus-cluster

# po zmianie plików konfiguracji (system budowany na laptopie, kopiowany na węzeł)
git add -A
nixos-rebuild switch --flake .#incus1 --target-host root@192.168.150.11

# wszystkie węzły po kolei, z kontrolą Ceph
for n in 1 2 3; do
  ssh root@192.168.150.11 ceph health | grep -q HEALTH_OK || { echo "Ceph nie jest OK"; break; }
  nixos-rebuild switch --flake .#incus$n --target-host root@192.168.150.1$n || break
done
```

**Restart węzła (nowe jądro, aktualizacja)** - zawsze jeden węzeł naraz:

```bash
nix flake update                        # aktualizacja - opcjonalnie
nixos-rebuild boot --flake .#incus2 --target-host root@192.168.150.12

ssh root@192.168.150.11 incus cluster evacuate incus2 --force   # instancje: zatrzymanie i start na innych węzłach
ssh root@192.168.150.11 ceph osd set noout                      # Ceph nie przebudowuje danych na czas restartu
ssh root@192.168.150.12 systemctl reboot
# ...po powrocie węzła:
ssh root@192.168.150.11 ceph -s                                 # 3 osd up
ssh root@192.168.150.11 ceph osd unset noout
ssh root@192.168.150.11 incus cluster restore incus2 --force    # instancje wracają
```

Powtórz dla pozostałych węzłów, potem `git commit -am "Aktualizacja flake.lock" && git push`.

Powrót do stanu laboratorium (przy wyłączonych VM):

```bash
zfs list -t snapshot rpool/vm
sudo zfs rollback -r rpool/vm@ceph-klaster-czysty
```

> `rollback` cofa cały dataset `rpool/vm`, czyli również obraz Windows 11.
> Węzły wyłączaj wszystkie razem - snapshot ma być spójny dla całego Cepha.

---

# Przejście na produkcję (szkic)

- `nodes.nix`: adresy i MAC-i fizycznych kart, nowe `hostId`; ścieżki dysków przez
  `/dev/disk/by-id/...` (zamiast wspólnych numerów seryjnych z labu).
- `cluster.nix`: nowe `ceph.fsid` (`uuidgen`), serwery NTP zakładu, `osdMemoryTarget = "4294967296"`.
- `modules/hardware.nix`: wygenerowany na serwerze (`nixos-generate-config --show-hardware-config`),
  watchdog sprzętowy (iTCO / IPMI) zamiast `i6300esb`.
- Sieć: bondy do dwóch przełączników dla `mgmt0` (od niej zależy samoogrodzenie) i `ceph0`,
  Ceph najlepiej 25 GbE. VLAN-y w preseed wg koncepcji segmentacji.
- Pojemność N+1 (dwa węzły unoszą wszystkie VM-ki), kopie zapasowe VM-ek poza Cephem,
  licencje WinCC (ALM) po przeniesieniu VM-ki, pary redundantne na różnych węzłach.

---

# Rozwiązywanie problemów

| Objaw | Rozwiązanie |
|---|---|
| `nix` nie zna `flake` / `run` | `export NIX_CONFIG="experimental-features = nix-command flakes"` |
| Zmiany w plikach są ignorowane | `git add -A` - flake widzi tylko pliki w gicie |
| `ssh`: *REMOTE HOST IDENTIFICATION HAS CHANGED* | po reinstalacji węzła: `ssh-keygen -R <adres>` |
| Węzeł staje na imporcie `rpool` (*Failed to start Import ZFS pool*) | pula nie została wyeksportowana: w menu systemd-boot `e`, dopisz ` zfs_force=1`, Enter (jednorazowo) |
| VM nie startuje: *Access Denied* / Secure Boot | maszyna ma firmware z Secure Boot - utwórz ją ponownie skryptem |
| Brak `mgmt0` / `ceph0` / `ot0` | MAC-i w `virsh domiflist <węzeł>` muszą się zgadzać z `nodes.nix` |
| `incus launch --vm`: brak `/dev/kvm` | brak zagnieżdżonej wirtualizacji na laptopie (krok 1a) |
| Instancje w `incusbr0` nie dostają adresu IP | `incusbr0` musi być w `networking.firewall.trustedInterfaces` |
| `ceph -s`: *clock skew detected* | `chronyc tracking` na węzłach; węzły muszą mieć dostęp do NTP |
| `ceph -s`: *mons are allowing insecure global_id reclaim* | `ceph config set mon auth_allow_insecure_global_id_reclaim false` |
| Instancja nie startuje: błąd mapowania RBD | węzeł nie działa na jądrze 7.x (`uname -r`) - restart po wdrożeniu |
| Instancja po awarii nie przeniosła się | ma urządzenie lokalne (dysk spoza Cepha, sieć niezarządzaną przez Incus, USB) - `journalctl -u incus` na liderze klastra |
| Po awarii węzeł ma stan `EVACUATED` | to normalne po automatycznym odtworzeniu: `incus cluster restore <węzeł>` |
