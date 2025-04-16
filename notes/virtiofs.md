# Workarounds for VirtioFS

- Intellij - and probably other java apps - seem to crash when trying to access files on a VirtioFS mount. 

According to AI:
This is due to the fact that VirtioFS does not support the `fallocate` syscall. To work around this, you can 
use the `LD_PRELOAD` environment variable to load a library that intercepts the `fallocate` syscall and 
returns an error code. This will cause the java app to fall back to a different method of allocating space for files.
To do this, you can use the `libfallocate.so` library from the `fallocate` package. You can find the library in the 
`/usr/lib64` directory. To use it, you can set the `LD_PRELOAD` environment variable like this...


Another option is to copy the binaries, ~/.cache and ~/.local/share/IntelliJ to a real disk.
