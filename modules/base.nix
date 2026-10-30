# Ustawienia bazowe węzła: boot, ZFS, nix, użytkownik, SSH.
# Część przeniesiona z modules/common.nix z repo nixos-config (bez pulpitu).
{ config, pkgs, nodes, nodeName, cluster, ... }:
let
  # klucz publiczny z laptopa (pg)
  pgKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlKrUMXtKlnlbGQgiioga7bd/StVWdbAwz+1jJ7+vQO pawel@nixos-pg";
in
{
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" "@wheel" ];
  };

  # Boot + ZFS
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.configurationLimit = 10;
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
  services.zfs.autoScrub.enable = true;
  services.zfs.trim.enable = true;
  zramSwap.enable = true;

  # ZFS jest tu tylko dla systemu - ARC nie może zabierać RAM-u Cephowi i VM-kom
  boot.kernelParams = [ "zfs.zfs_arc_max=536870912" ];   # 512 MiB

  # Jądro 7.2 zamiast domyślnego 6.18: Ceph 20.2.4 uwierzytelnia szyfrem aes256k,
  # który moduł rbd jądra (nim Incus podłącza dyski VM) obsługuje dopiero od Linuksa 7.0.
  # 7.2 to najnowsze jądro wspierane przez ZFS 2.4.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_7_2;

  # Watchdog: systemd "karmi" go co kilka sekund; gdy jądro zawiśnie, VM (lub serwer)
  # zostanie zresetowana. Uzupełnia modules/self-fence.nix, który działa przy żywym jądrze.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "5min";
  };

  # Czas: Ceph odmawia pracy przy rozjeździe zegarów między MON-ami
  services.timesyncd.enable = false;
  services.chrony = {
    enable = true;
    servers = cluster.ntpServers;
  };

  # Powłoka awaryjna w initrd bez hasła (root nie ma hasła, więc bez tego jest zablokowana).
  # Akceptowalne w laboratorium; na prawdziwym serwerze lepiej ustawić hasło roota.
  boot.initrd.systemd.emergencyAccess = true;

  networking.hostName = nodeName;
  networking.hostId = nodes.${nodeName}.hostId;   # wymagane przez ZFS, inne na każdym węźle

  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "pl_PL.UTF-8";
  console.keyMap = "pl2";

  # Sprzątanie
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  # Użytkownik - logowanie tylko kluczem; hasło (do konsoli i sudo) ustawia się po instalacji
  users.users.pawel = {
    isNormalUser = true;
    description = "Paweł Żydek";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ pgKey ];
  };

  # root: dostęp tylko kluczem z laptopa - z niego wdrażamy konfigurację
  users.users.root.openssh.authorizedKeys.keys = [ pgKey ];

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    htop
    btop
    tcpdump
    nvd
    mc
    jq          # skrypty (np. ceph ... -f json)
  ];

  system.stateVersion = "26.05";
}
