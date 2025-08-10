
if [ -e /x/home/build/.nix-profile/etc/profile.d/nix.sh ]; then . /x/home/build/.nix-profile/etc/profile.d/nix.sh; fi # added by Nix installer
if [ -z "XDG_RUNTIME_DIR" ]; then 
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
fi

# ~/.profile: executed by the command interpreter for login shells.
# This file is not read by bash(1), if ~/.bash_profile or ~/.bash_login
# exists.
# see /usr/share/doc/bash/examples/startup-files for examples.
# the files are located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask
# for ssh logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
    # include .bashrc if it exists
    if [ -f "$HOME/.bashrc" ]; then
	. "$HOME/.bashrc"
    fi
fi

if [ "$(tty)" == "/dev/tty1" ]; then
  echo "Login on tty1, .profile will start wayland, enter 't' to get a terminal"
  read -t 10 -n 1 key
  if [ "$key" != "t" ]; then
    exec dbus-run-session labwc
  fi
fi


if [ -f "$HOME/.cargo/env"  ]; then 
. "$HOME/.cargo/env"
fi
