# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

# Use 'nixos-rebuild build --option substitute false --option binary-caches=""' in recovery 

{ config, lib, pkgs, ... }:

{
  #imports =
  #  [ # Include the results of the hardware scan.
  #    ./hardware-configuration.nix
  #  ];
  nix.settings.experimental-features = [ "nix-command" "flakes"];
  nixpkgs.config.allowUnfree = true;

  #This breaks getty and other things - not the right approach
  boot.isContainer = false;
  
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "size=1M" ];  
  } ;
  swapDevices = [];
 
  #systemd.services.systemd-remount-fs.enable = false;
  #systemd.services.systemd-remount-fs.wantedBy = lib.mkForce [ ];
  
  #boot.specialFileSystems = false;
  systemd.mounts = [];
  systemd.automounts = [];
  # Doesn't exist - systemd.debug-shell.enable = true;

  boot.loader.systemd-boot.enable = false;
  boot.loader.grub.enable = false;
  boot.loader.efi.canTouchEfiVariables = false;
  boot.initrd.enable = false;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.enableContainers = true;
  networking.hostName = "host5";

  #systemd.maskedServices = [ "systemd-remount-fs.service" ];



  systemd.tpm2.enable = false;
  boot.initrd.systemd.tpm2.enable = false;
 
  nix.settings.trusted-users = [ "root" "system" ];
  
  services.logind.settings.Login = {
     HandleLidSwitch = "ignore";
  };

  # Configure network connections interactively with nmcli or nmtui.
  networking.networkmanager.enable = false;
  
  systemd.services.xdebug-shell = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.bash}/bin/bash";
      Restart = "always";
      StandardInput = "tty";
      TTYPath = "/dev/tty8";
      TTYReset = "true";
      TTYVHangup = "true";
    };
  };
  #systemd.additionalUpstreamSystemUnits = [ "xdebug-shell.service" ]; 

  # Set your time zone.
  # time.timeZone = "Europe/Amsterdam";

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  #   useXkbConfig = true; # use xkb.options in tty.
  # };

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # services.pulseaudio.enable = true;
  # OR
  # services.pipewire = {
  #   enable = true;
  #   pulse.enable = true;
  # };

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.system = {
     isNormalUser = true;
     extraGroups = [ "wheel" "networkmanager" "video" "audio" ]; # Enable ‘sudo’ for the user.
     openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILKkZBAiTUDYeQNH2YWVBhY2ONSvD80akbrvDqmIiNyF build@devvm.h.webinf.info"
    ];

     packages = with pkgs; [
       tree
     ];
  };
  system.autoUpgrade.enable = false;
  system.autoUpgrade.allowReboot = false;
 

  # Conflicting 
  security.polkit.enable = false;
  #programs.labwc.enable = true;
  #services.seatd.enable = true;

  systemd.defaultUnit = lib.mkForce "multi-user.target";
  systemd.services.systemd-remount-fs.enable = false;


  xdg.portal = {
    enable = false;
    wlr.enable = false;
   extraPortals = [ pkgs.xdg-desktop-portal-wlr ];
  };
  # programs.firefox.enable = true;

  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
   environment.systemPackages = with pkgs; [
     tmux 
     mc
     openssh
     vim 
     wget
     curl
   ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh = {
      enable = true;
      settings = {
       PasswordAuthentication = true;
       PermitRootLogin = "yes";
     };
   };

  

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}

