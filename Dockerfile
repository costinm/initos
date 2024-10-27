# syntax=docker/dockerfile:1.10

# Build the 'recovery/installer' image.
# Feel free to customize or extend.
#
# Unlike common dockerfiles, there is one RUN for a script - the script can be used independently of Dockerfiles
FROM alpine:edge as recovery
#FROM alpine:3.20.3 as recovery

# Copy the main script. If it changes - will download everything again
#COPY ./recovery/sbin/setup-initos /sbin/

# Rest of the files
COPY ./recovery/sbin/ /sbin/
COPY ./recovery/etc/ /etc/

# This add the 'base' - should be close to the packages on the alpine installer.
RUN  --mount=target=/etc/apk/cache,id=apk,type=cache /sbin/setup-recovery install

