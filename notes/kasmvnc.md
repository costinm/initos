# KasmVNC

Kasm is a VNC using Websocket and WebRTC for transport. Like all VNCs, it is relies on streaming the compressed content instead of
exposing drawing primitives (as X11 and OpenGL do). Kasm supports 
hardware acceleration - if the 'dri' device is exposed to the 
container.

In chrome, if served over https it can be installed as a 'native' app
which provides better keyboard (no conflicts with the chrome keys), but full screen apps work well inside the browser if they don't conflict with the browser or desktop shortcuts. 

It is IMO one of the best solution for remote desktop. Most other
'VNC' solutions have similar behavior.

## Security 

I am mainly concerned with the websocket/HTTP security - WebRTC
has its own mTLS capabilities.

Kasm works best with a Gateway, with valid TLS certificates and separate FQDNs for each server. 

Storing a public certificate and key on each guest running Kasm would be bad - both managenent and protecting the private keys. It is possible - using ACME - but it would then rely on SNI routing or dedicated IP addresses, so it is really only viable using IPv6.

The other option is to use a 'mesh' style certificate or ambient
mesh (ztunnel, wireguard) with L4 policies combined with a Gateway.



## Local security

It appears there is support for using UDS - it is possible to have a 
sidecar or same-host L7 gateway that handles TLS+auth. 

Using localhost is not viable - if Kasm listens on 127.0.0.1 any local app could connect, and the main point of Kasm is to provide
X11 access to local apps. 

This may works with ztunnel or per-VM daemons - if UDS support was added. 


## Authentication

Kasm is using $HOME/.kasmpasswd - it must be created and shared.

Password managers work well with BASIC auth, and it is not less secure than long-lived JWT tokens or APIkeys.

It is possible to combine it with OAuth2 flow - with some exchange 
at the end, but APIkeys are fine too.