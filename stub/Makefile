#
#  This file is part of gummiboot
#
#  Copyright (C) 2013 Karel Zak <kzak@redhat.com>
#
#  gummiboot is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation; either version 2.1 of the License, or
#  (at your option) any later version.
#
#  gummiboot is distributed in the hope that it will be useful, but
#  WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with systemd; If not, see <http://www.gnu.org/licenses/>.

top_builddir=build
top_srcdir=.

# ------------------------------------------------------------------------------
# EFI compilation -- this part of the build system uses custom make rules and
# bypasses regular automake to provide absolute control on compiler and linker
# flags.
efi_cppflags = \
	$(EFI_CPPFLAGS) \
	-DVERSION=1 \
	-I/usr/include/efi -I/usr/include -I/usr/include/x86_64-linux-gnu \
	-I$(top_builddir) \
	-DMACHINE_TYPE_NAME=\"$(MACHINE_TYPE_NAME)\"

efi_cflags = \
	$(EFI_CFLAGS) \
	-Wall \
	-Wextra \
	-nostdinc \
	-ggdb -O0 \
	-fpic \
	-fshort-wchar \
	-nostdinc \
	-ffreestanding \
	-fno-strict-aliasing \
	-fno-stack-protector \
	-Wsign-compare \
	-mno-sse \
	-mno-mmx

ARCH=x86_64

efi_cflags += \
	-mno-red-zone \
	-DEFI_FUNCTION_WRAPPER \
	-DGNU_EFI_USE_MS_ABI

efi_ldflags = \
	$(EFI_LDLAGS) \
	-T /usr/lib/elf_$(ARCH)_efi.lds \
	-shared \
	-Bsymbolic \
	-nostdlib \
	-znocombreloc \
	-L /usr/lib \
	/usr/lib/crt0-efi-$(ARCH).o

# ------------------------------------------------------------------------------
stub_headers = \
	src/efi/util.h \
	src/efi/pefile.h \
	src/efi/linux.h

stub_sources = \
	src/efi/util.c \
	src/efi/pefile.c \
	src/efi/linux.c \
	src/efi/stub.c

stub_objects = $(addprefix $(top_builddir)/,$(stub_sources:.c=.o))
stub_solib = $(top_builddir)/src/efi/stub.so
stub = linux$(MACHINE_TYPE_NAME).efi.stub

gummibootlib_DATA += $(stub)
CLEANFILES += $(stub_objects) $(stub_solib) $(stub)
EXTRA_DIST += $(stub_sources) $(stub_headers)

$(stub): $(stub_solib)
	$(AM_V_GEN) objcopy -j .text -j .sdata -j .data -j .dynamic \
	  -j .dynsym -j .rel -j .rela -j .reloc \
	  --target=efi-app-$(ARCH) $< $@

$(top_builddir)/src/efi/%.o: $(top_srcdir)/src/efi/%.c $(addprefix $(top_srcdir)/,$(stub_headers))
	mkdir -p  $(top_builddir)/src/efi/
	cc $(efi_cppflags) $(efi_cflags) -c $< -o $@

$(stub_solib): $(stub_objects)
	ld $(efi_ldflags) $(stub_objects) \
		-o $@ -lefi -lgnuefi $(shell $(CC) -print-libgcc-file-name); \
	nm -D -u $@ | grep ' U ' && exit 1 || :
.DELETE_ON_ERROR: $(gummboot_solib)

