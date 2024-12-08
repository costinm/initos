# Insecure mode

The project primary goal is to simplify the setup of a secure 
linux - with isolated build, signed EFI and images and encrypted disk using TPM for secret storage.

In the absence of a TPM2, using 'c' allows manual unlock, and
is almost equivalent to a TPM for a laptop - there are few theoretical risk (not practical because it needs hardware access - and that may break the TPM2 mode as well).

For older machines used for dev or (encrypted) backup storage or non-sensitive jobs - including running a LLM, testing, etc - it is possible to skip using an encrypted disk. 

Physical access would compromise the data - just like the majority of Linux distros currently in use. 