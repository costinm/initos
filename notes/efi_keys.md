# EFI use

For boot, the critical parts are the 'root of trust' config and the boot loader entries.

To use InitOS, the USB disk or pre-seeded disk is used for to setup the encrypted disk partitions, 
initial hostname and keys and the boot menu entries.

The second step is to use the uEFI settings to 'clear' PK and install the keys provided under initos/KEYS, and enable the 'secure boot'.

## File names

".crt" is a normal PEM certificate. Most UEFI can directly enroll this file (.cer is DER certificate)

".esl" is the 'EFI signature list" file, used to produce the ".auth"

".auth" is an .esl signed by the key. It can be used with UpdateVars EFI


## Signing keys

The original design has the 'PK' (platform key) set by the machine manufacturer, but all current implementations allow user to set it's own. This is the most important step in establishing a root of trust.

The KEK key was supposed to be owned by the OS manufacturer (like Microsoft), and would be signed by each platform vendor. Like PK, it is a "CA" key signing
updates to the DB keys.

You can think of this as a 3-layer TLS certificate.

The DB key is the one that matters - it signs the actual EFI imags. It also includes hashes, but not very useful.

MokUtil and the 'shim' is a separate boot loader, using a separate set of keys - while keeping PK/KEK in place. More complicated, less secure.


# EFItools 

Various programs can be used before turning signature, including scripts using the shell.

```
UpdateVars db db.auth
UpdateVars KEK KEK.auth
UpdateVars PK PK.auth

```

Updating PK should turn secure mode on.

LocDown script can be compiled with the keys built-in.