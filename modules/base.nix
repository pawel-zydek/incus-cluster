# Ustawienia bazowe węzła: boot, ZFS, nix, użytkownik, SSH.
# Część przeniesiona z modules/common.nix z repo nixos-config (bez pulpitu).
{ config, pkgs, nodes, nodeName, ... }:
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
  ];

  system.stateVersion = "26.05";
}
