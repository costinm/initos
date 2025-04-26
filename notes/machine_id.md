# Machine specific files

A read-only root is a good idea - but some machine local files are required. 

/etc/machine-id is the most important file when cloning a rootfs - br-lan MAC is derived from it.

/.dockerenv is created by docker - some apps check it and behave differntly. For example openrc doesn't set up hardware.

ssh host keys

