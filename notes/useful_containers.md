For more security and flexibile, it is best to use containers for most 
applications.

https://docs.linuxserver.io/images/docker-webtop/#version-tags has a set of 
containers with KasmVNC and I3/openbox, they seem to like openbox more (so does pi).
I don't like the NGinx sidecar that is bundled, but other than that it's good as 
a base, with added custom apps.


They use PRoot and have a mechanism to install apps in the host dir:

- /apps/NAME/Dockerfile 
- PA_REPO_FOLDER=/mnt/apps
proot-apps is used to manage them, the /mnt/apps can be mounted ro.

Proot is pulling from docker repo, exports and works with less requirements - 
all that using plain shell/curl/jq to implement the registry protocol.

I prefer 'crane export' for that, and real jails for the apps.

Other conventions:
- entrypoint for the script to start, install for the script to install.


# Gitpod

VSCode - can use continue for autocomplete.

Example dockerfile to extend and install more stuff.

The Gateway needs to do auth.


code-server is linuxcontainers variant.

# Coder 

- build in postgresql
- 
