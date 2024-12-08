# Fork for Alpine mkinitrd

Alpine mkinitrd is one of the cleanest - but has a few alpine-specific features and the same 'opaque' design as the others.

Instead:
- break appart each operation, building the filesystem step by step
- each operation is a separate call - very much like a step in dockerfiles.

