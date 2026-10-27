# Klaster Incus na NixOS

Testowe środowisko: 3 węzły NixOS z Incusem połączone w klaster.
Węzły to maszyny wirtualne KVM na laptopie (`pg`), a cała konfiguracja jest tutaj -
na węzłach nie ma kopii repozytorium, wdraża się je z laptopa.

Jest to repozytorium do nauki.

## Węzły

| Węzeł | Adres | MAC | RAM / vCPU | Dyski |
|---|---|---|---|---|
| `incus1` | 192.168.150.11 | 52:54:00:50:00:11 | 6 GB / 4 | system 30 GB + dane 60 GB |
| `incus2` | 192.168.150.12 | 52:54:00:50:00:12 | 6 GB / 4 | system 30 GB + dane 60 GB |
| `incus3` | 192.168.150.13 | 52:54:00:50:00:13 | 6 GB / 4 | system 30 GB + dane 60 GB |

- Sieć libvirta `incuslab`: 192.168.150.0/24, brama i DNS 192.168.150.1, NAT do internetu przez laptopa.
- Sieć instancji Incusa (`incusbr0`): 10.150.0.0/24, NAT przez węzeł, na którym działa instancja.
- Dysk systemowy (`incus-sys`): ZFS `rpool` **bez szyfrowania**, żeby węzeł sam wstawał po restarcie.
- Dysk danych (`incus-data`): w całości pula ZFS Incusa `local`.

Dyski mają w libvirt numery seryjne, więc na każdym węźle mają tę samą ścieżkę
(`/dev/disk/by-id/virtio-incus-sys`, `/dev/disk/by-id/virtio-incus-data`) i jedna konfiguracja pasuje do wszystkich.

## Struktura repozytorium

```
flake.nix                 # wejścia (nixpkgs, disko) i hosty incus1..3 tworzone z nodes.nix
nodes.nix                 # nazwa, adres IP, MAC, hostId każdego węzła - jedyne miejsce z tymi danymi
modules/
  hardware.nix            # wspólny "hardware-configuration" dla VM (virtio)
  disko.nix               # układ dysku systemowego: ESP + rpool
  base.nix                # boot, ZFS, nix, użytkownik, SSH
  network.nix             # stały adres, /etc/hosts z wszystkimi węzłami
  incus.nix               # Incus, panel WWW, nftables, zapora
libvirt/
  incuslab.xml            # definicja sieci libvirta
  create-vms.sh           # tworzy 3 VM (virt-install)
preseed/
  incus1-bootstrap.yaml   # założenie klastra na incus1
  join.yaml.template      # dołączanie incus2 i incus3
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

### 1c. Sieć `incuslab`

```bash
cd ~/incus-cluster
virsh net-define libvirt/incuslab.xml
virsh net-start incuslab
virsh net-autostart incuslab
virsh net-list --all
```

`virsh` łączy się z `qemu:///system` (zmienna `LIBVIRT_DEFAULT_URI` z `kvm.nix`), więc `sudo` nie jest potrzebne.

### 1d. Maszyny wirtualne

```bash
./libvirt/create-vms.sh
virsh list --all
```

Skrypt tworzy `incus1`, `incus2`, `incus3` i uruchamia je z instalatora.
Istniejące maszyny pomija, więc można go uruchomić ponownie.

> **Pamięć:** 3 × 6 GB + ARC ZFS laptopa (8 GB) + system to ok. 30 GB.
> Nie uruchamiaj jednocześnie VM z Windows albo zmniejsz `RAM_MB` w skrypcie do 4096.

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

nixos-anywhere łączy się przez SSH, uruchamia disko (**kasuje dysk systemowy VM**),
instaluje system z tego repozytorium i odmontowuje pulę. Dysk danych pozostaje pusty.

### 2c. Pierwszy start z dysku

```bash
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
ssh root@192.168.150.11 'hostname; zpool status rpool; systemctl is-active incus'
ssh root@192.168.150.11 passwd pawel       # hasło do konsoli i sudo
```

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
sudo zfs snapshot rpool/vm@wezly-zainstalowane
```

---

# 3. Założenie klastra

Klaster zakładamy ręcznie (raz). Opcja `virtualisation.incus.preseed` w NixOS uruchamia
`incus admin init` przy każdym starcie usługi - to dobre dla pojedynczego serwera,
ale nie dla dołączania węzłów jednorazowym tokenem.

### 3a. Pierwszy węzeł

```bash
cd ~/incus-cluster
ssh root@192.168.150.11 incus admin init --preseed < preseed/incus1-bootstrap.yaml
ssh root@192.168.150.11 incus cluster list
```

### 3b. Dołączenie incus2 i incus3

Dla każdego węzła: token z `incus1`, potem dołączenie z wypełnionym szablonem.

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

### 3c. Pierwsze instancje

Na dowolnym węźle (użytkownik `pawel` należy do grupy `incus-admin`):

```bash
incus launch images:debian/13 c1 --target incus2          # kontener
incus launch images:debian/13 v1 --vm --target incus3     # maszyna wirtualna (wymaga nested)
incus list
```

### 3d. Panel WWW

`https://192.168.150.11:8443` w Firefoksie na laptopie. Panel poprowadzi przez utworzenie certyfikatu
przeglądarki; certyfikat dodaje się do zaufanych poleceniem pokazanym w panelu (`incus config trust add-certificate ...`).

Snapshot po założeniu klastra (przy wyłączonych węzłach): `sudo zfs snapshot rpool/vm@klaster-czysty`.

---

# Codzienna praca

```bash
cd ~/incus-cluster

# po zmianie plików konfiguracji (system budowany na laptopie, kopiowany na węzeł)
git add -A
nixos-rebuild switch --flake .#incus1 --target-host root@192.168.150.11

# wszystkie węzły po kolei
for n in 1 2 3; do
  nixos-rebuild switch --flake .#incus$n --target-host root@192.168.150.1$n || break
done

# aktualizacja
nix flake update
# ...pętla jak wyżej...
git commit -am "Aktualizacja flake.lock" && git push
```

Węzły aktualizuj **po kolei** i sprawdzaj `incus cluster list` - klaster działa dalej, gdy jeden węzeł się restartuje.

Powrót do stanu laboratorium (przy wyłączonych VM):

```bash
zfs list -t snapshot rpool/vm
sudo zfs rollback -r rpool/vm@klaster-czysty
```

> `rollback` cofa cały dataset `rpool/vm`, czyli również obraz Windows 11.

---

# Rozwiązywanie problemów

| Objaw | Rozwiązanie |
|---|---|
| `nix` nie zna `flake` / `run` | `export NIX_CONFIG="experimental-features = nix-command flakes"` |
| Zmiany w plikach są ignorowane | `git add -A` - flake widzi tylko pliki w gicie |
| `ssh`: *REMOTE HOST IDENTIFICATION HAS CHANGED* | po reinstalacji węzła: `ssh-keygen -R <adres>` |
| Węzeł staje na imporcie `rpool` | w konsoli awaryjnej `zpool import -f rpool`, potem `reboot` |
| VM nie startuje: *Access Denied* / Secure Boot | maszyna ma firmware z Secure Boot - utwórz ją ponownie skryptem |
| Węzeł nie ma sieci | MAC w `virsh domiflist <węzeł>` musi się zgadzać z `nodes.nix` |
| `incus launch --vm`: brak `/dev/kvm` | brak zagnieżdżonej wirtualizacji na laptopie (krok 1a) |
| Instancje nie dostają adresu IP | `incusbr0` musi być w `networking.firewall.trustedInterfaces` |
| Dołączanie: *storage pool source* | dysk danych nie jest pusty - `wipefs -a /dev/disk/by-id/virtio-incus-data` |
