# Bootstrap an AMIX cross toolchain on Linux.
#
# The first working milestone is C -> AMIX m68k ELF relocatable objects.
# The real goal is a sysrooted toolchain that can link AMIX executables with
# GNU ld and, after C links cleanly, build the C++ front end as well.

SHELL := /bin/sh

TARGET ?= m68k-cbm-sysv4
BUILD ?= i686-pc-linux-gnu
HOST ?= $(BUILD)
PREFIX ?= $(HOME)/opt/amix-cross

BINUTILS_VERSION ?= 2.8.1
GCC_VERSION ?= 2.7.2.3

GNU_BASE ?= https://ftp.gnu.org/gnu
BINUTILS_TARBALL := binutils-$(BINUTILS_VERSION).tar.gz
GCC_TARBALL := gcc-$(GCC_VERSION).tar.gz
BINUTILS_URL ?= $(GNU_BASE)/binutils/$(BINUTILS_TARBALL)
GCC_URL ?= $(GNU_BASE)/gcc/$(GCC_TARBALL)
BINUTILS_CONFIGURE_EXTRA ?=
GCC_CONFIGURE_EXTRA ?=
BINUTILS_DISABLE_DIRS ?=
GCC_BUILD_TARGETS ?= xgcc cc1 cccp
GCC_FULL_BUILD_TARGETS ?= LANGUAGES="c c++" all

HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
AMIX_ROOT ?= $(abspath $(HERE)/../..)

DISTDIR ?= $(HERE)/distfiles
SRCDIR ?= $(HERE)/src
BUILDDIR ?= $(HERE)/build

BINUTILS_SRC := $(SRCDIR)/binutils-$(BINUTILS_VERSION)
GCC_SRC := $(SRCDIR)/gcc-$(GCC_VERSION)
BINUTILS_BUILD := $(BUILDDIR)/binutils-$(BINUTILS_VERSION)-$(TARGET)
GCC_BUILD := $(BUILDDIR)/gcc-$(GCC_VERSION)-$(TARGET)

HOST_CC ?= gcc
HOST_CFLAGS ?= -O2 -g -std=gnu89 -fcommon -no-pie
AMIX_MAKEINFO ?= true
override MAKEINFO := $(AMIX_MAKEINFO)
MAKE_JOBS ?= $(shell nproc 2>/dev/null || echo 1)
CONFIG_GUESS ?= /usr/share/misc/config.guess
CONFIG_SUB ?= /usr/share/misc/config.sub

CPUFLAGS ?= -m68020
AMIX_KERNEL_CPPFLAGS ?= -D_KERNEL -DSVR40 -DSVR4
AMIX_KERNEL_INCLUDES ?= -I$(AMIX_ROOT)/usr/include -I$(AMIX_ROOT)/usr/sys -I$(AMIX_ROOT)/usr/sys/amiga/inc
AMIX_KERNEL_CFLAGS ?= -O -traditional -fno-builtin -Dinline=__inline__ $(CPUFLAGS) $(AMIX_KERNEL_CPPFLAGS) $(AMIX_KERNEL_INCLUDES)
SYSROOT ?= $(PREFIX)/$(TARGET)/sysroot
AMIX_USR_LIB ?= $(AMIX_ROOT)/usr/lib
AMIX_CRT_DIR ?= $(SYSROOT)/usr/ccs/lib
AMIX_CRTS ?= crt1.o crti.o crtn.o
AMIX_USER_CFLAGS ?= -O -traditional -fno-builtin $(CPUFLAGS) -I$(SYSROOT)/usr/include

PATH_FOR_BUILD := $(PREFIX)/bin:$(PATH)
TARGET_CC := $(PREFIX)/bin/$(TARGET)-gcc
TARGET_AS := $(PREFIX)/bin/$(TARGET)-as
TARGET_LD := $(PREFIX)/bin/$(TARGET)-ld
TARGET_AR := $(PREFIX)/bin/$(TARGET)-ar
TARGET_RANLIB := $(PREFIX)/bin/$(TARGET)-ranlib
GCC_LIBDIR := $(PREFIX)/lib/gcc-lib/$(TARGET)/$(GCC_VERSION)
GCC_REAL := $(PREFIX)/bin/$(TARGET)-gcc.real

# Host ar/ranlib the target ar/ranlib wrappers delegate to (see
# amix-ar-wrapper.sh and install-target-ar).
HOST_AR ?= ar
HOST_RANLIB ?= ranlib

# Target libgcc: the freestanding libgcc2 helper routines built from the GCC
# 2.7.2.3 source and archived into libgcc.a.  These are the soft-arithmetic
# helpers gcc emits calls to (chiefly the 64-bit DImode integer routines such
# as __udivdi3/__umoddi3/__lshrdi3) plus the DImode<->float conversions.  Every
# routine here is freestanding: it builds and links with no AMIX libc.  Built
# one object per function with -DL<name>, mirroring the stock gcc LIB2FUNCS
# rule, but through the installed wrapper compiler so the SGS->GNU-as fixups are
# applied.  (float->unsigned and XFmode fix routines are intentionally omitted:
# GNU as 2.8.1 rejects their fcmp operand syntax; they are not needed here.)
LIBGCC_A := $(GCC_LIBDIR)/libgcc.a
LIBGCC2_BUILD_DIR := $(GCC_BUILD)/amix-libgcc
LIBGCC2_BUILD_CFLAGS ?= -O2
LIBGCC2_BUILD_INCLUDES := -I$(GCC_BUILD) -I$(GCC_SRC) -I$(GCC_SRC)/config -I$(GCC_SRC)/ginclude
LIBGCC2_FUNCS := _muldi3 _divdi3 _moddi3 _udivdi3 _umoddi3 _negdi2 \
	_lshrdi3 _ashldi3 _ashrdi3 _udiv_w_sdiv _udivmoddi4 _cmpdi2 _ucmpdi2 \
	_floatdidf _floatdisf _floatdixf _fixunsdfdi _fixdfdi _fixunssfdi \
	__gcc_bcmp _clear_cache _shtab _trampoline

.PHONY: all help deps-hint deps download extract binutils install-binutils sysroot validate-sysroot check-runtime github-safety-check gcc install-gcc gcc-full install-gcc-wrapper install-target-ar libgcc install-libgcc env test-random test-hello test-uint64 test-divmod print-vars clean distclean

all: install-binutils sysroot install-gcc install-gcc-wrapper install-target-ar install-libgcc env

help:
	@echo "AMIX cross-toolchain bootstrap"
	@echo ""
	@echo "Common targets:"
	@echo "  make deps-hint       Print LMDE/Debian package hints"
	@echo "  make deps            Run apt-get install for build prerequisites"
	@echo "  make all             Build binutils, import AMIX sysroot, install GCC, write env.sh"
	@echo "  make sysroot         Copy AMIX headers/libs into PREFIX/TARGET/sysroot"
	@echo "  make validate-sysroot Check required user-supplied AMIX runtime files"
	@echo "  make check-runtime   Verify AMIX crt objects needed for Linux-side linking"
	@echo "  make github-safety-check Warn if redistributable repo contains AMIX files"
	@echo "  make gcc-full        Attempt full GCC C/C++ build after ld/runtime are ready"
	@echo "  make test-random     Cross-compile usr/sys/amiga/driver/random.c"
	@echo "  make test-hello      Try to build and link a runnable AMIX user program"
	@echo "  make env             Write env.sh only"
	@echo "  make print-vars      Show the selected versions and paths"
	@echo ""
	@echo "Useful overrides:"
	@echo "  make PREFIX=/opt/amix-cross"
	@echo "  make TARGET=m68k-cbm-sysv4"
	@echo "  make CPUFLAGS=-m68030"

deps-hint:
	@echo "On LMDE/Debian, install prerequisites with:"
	@echo "  sudo apt-get update"
	@echo "  sudo apt-get install build-essential make m4 bison flex texinfo curl wget gzip tar patch file autotools-dev"

deps:
	sudo apt-get update
	sudo apt-get install build-essential make m4 bison flex texinfo curl wget gzip tar patch file autotools-dev

print-vars:
	@echo "TARGET=$(TARGET)"
	@echo "PREFIX=$(PREFIX)"
	@echo "BINUTILS_VERSION=$(BINUTILS_VERSION)"
	@echo "GCC_VERSION=$(GCC_VERSION)"
	@echo "AMIX_ROOT=$(AMIX_ROOT)"
	@echo "AMIX_KERNEL_CFLAGS=$(AMIX_KERNEL_CFLAGS)"
	@echo "SYSROOT=$(SYSROOT)"
	@echo "AMIX_CRT_DIR=$(AMIX_CRT_DIR)"

download: $(DISTDIR)/$(BINUTILS_TARBALL) $(DISTDIR)/$(GCC_TARBALL)

$(DISTDIR):
	mkdir -p $@

$(DISTDIR)/$(BINUTILS_TARBALL): | $(DISTDIR)
	curl -L -o $@ $(BINUTILS_URL) || wget -O $@ $(BINUTILS_URL)

$(DISTDIR)/$(GCC_TARBALL): | $(DISTDIR)
	curl -L -o $@ $(GCC_URL) || wget -O $@ $(GCC_URL)

extract: $(BINUTILS_SRC)/.amix-cross-extracted $(GCC_SRC)/.amix-cross-extracted

$(SRCDIR):
	mkdir -p $@

$(BINUTILS_SRC)/.amix-cross-extracted: $(DISTDIR)/$(BINUTILS_TARBALL) | $(SRCDIR)
	rm -rf $(BINUTILS_SRC)
	rm -rf $(BINUTILS_BUILD)
	cd $(SRCDIR) && tar -xzf $(DISTDIR)/$(BINUTILS_TARBALL)
	$(MAKE) refresh-config TREE=$(BINUTILS_SRC)
	$(MAKE) patch-binutils TREE=$(BINUTILS_SRC)
	$(MAKE) disable-binutils-dirs TREE=$(BINUTILS_SRC)
	touch $@

$(GCC_SRC)/.amix-cross-extracted: $(DISTDIR)/$(GCC_TARBALL) | $(SRCDIR)
	rm -rf $(GCC_SRC)
	rm -rf $(GCC_BUILD)
	cd $(SRCDIR) && tar -xzf $(DISTDIR)/$(GCC_TARBALL)
	$(MAKE) refresh-config TREE=$(GCC_SRC)
	$(MAKE) patch-gcc TREE=$(GCC_SRC)
	touch $@

refresh-config:
	@test -n "$(TREE)" || { echo "TREE is required"; exit 1; }
	@test -f "$(CONFIG_GUESS)" || { echo "Missing $(CONFIG_GUESS). Install autotools-dev or set CONFIG_GUESS=/path/to/config.guess"; exit 1; }
	@test -f "$(CONFIG_SUB)" || { echo "Missing $(CONFIG_SUB). Install autotools-dev or set CONFIG_SUB=/path/to/config.sub"; exit 1; }
	@find "$(TREE)" -name config.guess -exec cp "$(CONFIG_GUESS)" {} \;
	@find "$(TREE)" -name config.sub -exec cp "$(CONFIG_SUB)" {} \;
	@echo "Refreshed config.guess/config.sub under $(TREE)"

disable-binutils-dirs:
	@test -n "$(TREE)" || { echo "TREE is required"; exit 1; }
	@for dir in $(BINUTILS_DISABLE_DIRS); do \
		if test -d "$(TREE)/$$dir" && test ! -d "$(TREE)/$$dir.disabled"; then \
			mv "$(TREE)/$$dir" "$(TREE)/$$dir.disabled"; \
			echo "Disabled binutils subdir $$dir"; \
		fi; \
	done

patch-binutils:
	@test -n "$(TREE)" || { echo "TREE is required"; exit 1; }
	@if test -f "$(TREE)/ld/configure.tgt" && ! grep -q 'm68k-\*-\*sysv4\*' "$(TREE)/ld/configure.tgt"; then \
		sed -i '/m68\*-\*-elf)/i m68k-*-*sysv4*)	targ_emul=m68kelf ;;' "$(TREE)/ld/configure.tgt"; \
		echo "Patched ld/configure.tgt for m68k-*-sysv4"; \
	fi
	@if test -f "$(TREE)/bfd/config.bfd" && ! grep -q 'm68k-\*-\*sysv4\*' "$(TREE)/bfd/config.bfd"; then \
		sed -i '/m68\*-\*-elf)/i m68k-*-*sysv4*)	targ_defvec=bfd_elf32_m68k_vec ;;' "$(TREE)/bfd/config.bfd"; \
		echo "Patched bfd/config.bfd for m68k-*-sysv4"; \
	fi
	@if grep -q 'amix-cross: include write.h before targ-cpu.h' "$(TREE)/gas/config/obj-elf.h"; then \
		sed -i '/amix-cross: include write.h before targ-cpu.h/d; /#include "write.h"/d' "$(TREE)/gas/config/obj-elf.h"; \
	fi
	@if grep -q '^extern struct relax_type md_relax_table\[\];' "$(TREE)/gas/config/tc-m68k.h"; then \
		sed -i 's/^extern struct relax_type md_relax_table\[\];/\/\* amix-cross: declaration removed; struct relax_type is not visible yet. \*\//' "$(TREE)/gas/config/tc-m68k.h"; \
		echo "Patched gas/config/tc-m68k.h for modern host GCC"; \
	fi
	@if ! grep -q 'amix-cross: declare m68k relax table after as.h' "$(TREE)/gas/write.c"; then \
		sed -i '/#include "as.h"/a /* amix-cross: declare m68k relax table after as.h defines relax_typeS. */\
extern relax_typeS md_relax_table[];' "$(TREE)/gas/write.c"; \
		echo "Patched gas/write.c for m68k relax table declaration"; \
	fi

patch-gcc:
	@test -n "$(TREE)" || { echo "TREE is required"; exit 1; }
	@if ! grep -q 'amix-cross: modern libc strerror' "$(TREE)/cccp.c"; then \
		sed -i '/#include "config.h"/a /* amix-cross: modern libc strerror fallback. */\
#include <string.h>' "$(TREE)/cccp.c"; \
		sed -i 's/if (errno < sys_nerr)/if (1)/' "$(TREE)/cccp.c"; \
		sed -i 's/return sys_errlist\[errno\];/return strerror (errno);/' "$(TREE)/cccp.c"; \
		echo "Patched gcc cccp.c for modern libc strerror"; \
	fi
	@if ! grep -q 'amix-cross: modern libc strerror' "$(TREE)/gcc.c"; then \
		sed -i '/#include "config.h"/a /* amix-cross: modern libc strerror fallback. */\
#include <string.h>' "$(TREE)/gcc.c"; \
		sed -i 's/if (e < sys_nerr)/if (1)/g; s/if (errno < sys_nerr)/if (1)/g' "$(TREE)/gcc.c"; \
		sed -i 's/sys_errlist\[e\]/strerror (e)/g; s/sys_errlist\[errno\]/strerror (errno)/g' "$(TREE)/gcc.c"; \
		echo "Patched gcc gcc.c for modern libc strerror"; \
	fi
	@if grep -R -q 'gcc2_compiled%' "$(TREE)"; then \
		find "$(TREE)" -type f -exec sed -i 's/gcc2_compiled%/gcc2_compiled/g' {} \; ; \
		echo "Patched GCC sources for GNU as gcc2_compiled symbol syntax"; \
	fi
	@if grep -R -q 'lcomm.*,%u,%u' "$(TREE)"; then \
		find "$(TREE)" -type f -exec perl -0pi -e 's/((?:\\\\t|\t)?\\.lcomm[^"\\n]*,%[du]),%[du](\\\\n")/$$1$$2/g' {} \; ; \
		echo "Patched GCC .lcomm output for binutils 2.8.1"; \
	fi
	@find "$(TREE)/config" -type f -exec perl -0pi -e 's/fprintf\s*\(\s*\(FILE\)\s*,\s*",%([ud]),%[ud]\\n"\s*,\s*\(?SIZE\)?\s*,\s*\(?ROUNDED\)?\s*\)/fprintf ((FILE), ",%\1\\n", (SIZE))/g; s/fprintf\s*\(\s*\(FILE\)\s*,\s*",%([ud]),%[ud]\\n"\s*,\s*\(?SIZE\)?\s*,\s*\(?ALIGNMENT\)?\s*\/\s*BITS_PER_UNIT\s*\)/fprintf ((FILE), ",%\1\\n", (SIZE))/g; s/fprintf\s*\(\s*\(FILE\)\s*,\s*",%([ud]),%[ud]\\n"\s*,\s*\(?SIZE\)?\s*,\s*\(?ALIGN\)?\s*\/\s*BITS_PER_UNIT\s*\)/fprintf ((FILE), ",%\1\\n", (SIZE))/g; s/fprintf\s*\(\s*\(FILE\)\s*,\s*",%([ud]),%[ud]\\n"\s*,\s*\(?SIZE\)?\s*,\s*\(?ALIGNMENT\)?\s*\)/fprintf ((FILE), ",%\1\\n", (SIZE))/g; s/fprintf\s*\(\s*\(FILE\)\s*,\s*",%([ud]),%[ud]\\n"\s*,\s*\(?SIZE\)?\s*,\s*\(?ALIGN\)?\s*\)/fprintf ((FILE), ",%\1\\n", (SIZE))/g' {} \;
	@if test -f "$(TREE)/c-parse.c"; then touch "$(TREE)/c-parse.c"; fi
	@if test -f "$(TREE)/c-gperf.h"; then touch "$(TREE)/c-gperf.h"; fi

$(BUILDDIR):
	mkdir -p $@

$(BINUTILS_BUILD)/config.status: $(BINUTILS_SRC)/.amix-cross-extracted | $(BUILDDIR)
	mkdir -p $(BINUTILS_BUILD)
	cd $(BINUTILS_BUILD) && CC="$(HOST_CC)" CFLAGS="$(HOST_CFLAGS)" $(BINUTILS_SRC)/configure \
		--target=$(TARGET) \
		--prefix=$(PREFIX) \
		--disable-nls \
		$(BINUTILS_CONFIGURE_EXTRA)

binutils: $(BINUTILS_BUILD)/config.status
	$(MAKE) -C $(BINUTILS_BUILD) -j$(MAKE_JOBS) \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)"

install-binutils: binutils
	$(MAKE) -C $(BINUTILS_BUILD) install \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)"

sysroot:
	mkdir -p $(SYSROOT)/usr
	test -d "$(AMIX_ROOT)/usr/include"
	cp -R "$(AMIX_ROOT)/usr/include" "$(SYSROOT)/usr/"
	if test -d "$(AMIX_ROOT)/usr/sys"; then cp -R "$(AMIX_ROOT)/usr/sys" "$(SYSROOT)/usr/"; fi
	if test -d "$(AMIX_ROOT)/usr/ccs"; then cp -R "$(AMIX_ROOT)/usr/ccs" "$(SYSROOT)/usr/"; fi
	if test -d "$(AMIX_USR_LIB)"; then mkdir -p "$(SYSROOT)/usr/lib"; cp -R "$(AMIX_USR_LIB)"/. "$(SYSROOT)/usr/lib/"; fi
	@for f in libc.so.1 ld.so.1; do \
		if test -f "$(AMIX_USR_LIB)/$$f"; then \
			tmp="$(SYSROOT)/usr/lib/.$$f.tmp"; \
			cp "$(AMIX_USR_LIB)/$$f" "$$tmp"; \
			test -s "$$tmp"; \
			mv "$$tmp" "$(SYSROOT)/usr/lib/$$f"; \
		fi; \
	done

validate-sysroot: sysroot
	@missing=0; \
	for f in \
		usr/include/stdio.h \
		usr/include/sys/types.h \
		usr/lib/libc.so.1 \
		usr/lib/ld.so.1 \
		usr/ccs/lib/crt1.o \
		usr/ccs/lib/crti.o \
		usr/ccs/lib/crtn.o; do \
		if test ! -f "$(SYSROOT)/$$f"; then \
			echo "Missing $(SYSROOT)/$$f"; \
			missing=1; \
		elif test ! -s "$(SYSROOT)/$$f"; then \
			echo "Empty or truncated $(SYSROOT)/$$f"; \
			missing=1; \
		fi; \
	done; \
	test $$missing -eq 0

check-runtime: validate-sysroot
	@missing=0; \
	for f in $(AMIX_CRTS); do \
		if test ! -f "$(AMIX_CRT_DIR)/$$f" && test ! -f "$(SYSROOT)/usr/ccs/lib/$$f" && test ! -f "$(SYSROOT)/usr/lib/$$f"; then \
			echo "Missing AMIX startup object $$f. Copy it from AMIX, usually /usr/ccs/lib or /usr/lib, then set AMIX_CRT_DIR."; \
			missing=1; \
		fi; \
	done; \
	test $$missing -eq 0

github-safety-check:
	@if test -d "$(HERE)/../../usr"; then \
		echo "WARNING: $(HERE)/../../usr exists. Do not publish this AMIX usr tree."; \
		echo "Create the public repository from tools/amix-cross only, or keep /usr ignored."; \
	fi
	@if find "$(HERE)" \( -path '*/sysroot/*' -o -path '*/usr/include/*' -o -path '*/usr/lib/*' -o -name 'libc.so.1' -o -name 'ld.so.1' -o -name 'crt*.o' \) -print -quit | grep . >/dev/null; then \
		echo "WARNING: AMIX sysroot/runtime-looking files found under $(HERE)."; \
		echo "Remove them before publishing, or keep them outside the repo."; \
	else \
		echo "No AMIX sysroot/runtime files found under $(HERE)."; \
	fi

$(GCC_BUILD)/config.status: $(GCC_SRC)/.amix-cross-extracted install-binutils sysroot | $(BUILDDIR)
	mkdir -p $(GCC_BUILD)
	cd $(GCC_BUILD) && PATH="$(PATH_FOR_BUILD)" CC="$(HOST_CC)" CFLAGS="$(HOST_CFLAGS)" $(GCC_SRC)/configure \
		--build=$(BUILD) \
		--host=$(HOST) \
		--target=$(TARGET) \
		--prefix=$(PREFIX) \
		--with-gnu-as \
		--with-gnu-ld \
		$(GCC_CONFIGURE_EXTRA)

gcc: $(GCC_BUILD)/config.status
	@if test ! -f "$(GCC_BUILD)/libgcc1.a" && test ! -f "$(GCC_BUILD)/libgcc1.cross"; then \
		echo "Creating empty target libgcc1.a for compile-only bootstrap"; \
		cd "$(GCC_BUILD)" && "$(TARGET_AR)" rc libgcc1.a; \
		"$(TARGET_RANLIB)" "$(GCC_BUILD)/libgcc1.a" || true; \
	fi
	PATH="$(PATH_FOR_BUILD)" $(MAKE) -C $(GCC_BUILD) -j$(MAKE_JOBS) \
		LANGUAGES=c \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)" \
		$(GCC_BUILD_TARGETS)

install-gcc: gcc
	mkdir -p $(PREFIX)/bin $(GCC_LIBDIR)
	cp $(GCC_BUILD)/xgcc $(PREFIX)/bin/$(TARGET)-gcc
	cp $(GCC_BUILD)/xgcc $(GCC_REAL)
	cp $(GCC_BUILD)/cc1 $(GCC_LIBDIR)/cc1
	cp $(GCC_BUILD)/cccp $(GCC_LIBDIR)/cpp
	PATH="$(PATH_FOR_BUILD)" $(GCC_BUILD)/xgcc -B$(GCC_BUILD)/ -dumpspecs > $(GCC_LIBDIR)/specs
	chmod 755 $(PREFIX)/bin/$(TARGET)-gcc $(GCC_REAL) $(GCC_LIBDIR)/cc1 $(GCC_LIBDIR)/cpp

gcc-full: $(GCC_BUILD)/config.status check-runtime
	PATH="$(PATH_FOR_BUILD)" $(MAKE) -C $(GCC_BUILD) -j$(MAKE_JOBS) \
		CC="$(HOST_CC)" \
		CFLAGS="$(HOST_CFLAGS)" \
		MAKEINFO="$(AMIX_MAKEINFO)" \
		$(GCC_FULL_BUILD_TARGETS)

install-gcc-wrapper: install-gcc
	sed 's/@TARGET@/$(TARGET)/g' $(HERE)/amix-gcc-wrapper.sh > $(PREFIX)/bin/$(TARGET)-gcc
	chmod 755 $(PREFIX)/bin/$(TARGET)-gcc

# Replace the fortify-aborting binutils 2.8.1 ar/ranlib with thin wrappers that
# delegate to the host ar/ranlib (see amix-ar-wrapper.sh for the rationale).
# The shipped ar/ranlib are hardlinked to $(TARGET)/bin/ar etc., so remove the
# target path first to break the link before writing the wrapper in its place.
# Self-contained (the wrappers only need the host ar/ranlib); `all' sequences
# this after install-binutils so it overwrites the binutils-installed ar.
install-target-ar:
	@hostar="$$(command -v $(HOST_AR) 2>/dev/null)"; \
	hostranlib="$$(command -v $(HOST_RANLIB) 2>/dev/null)"; \
	test -n "$$hostar" || { echo "Host '$(HOST_AR)' not found in PATH"; exit 1; }; \
	test -n "$$hostranlib" || { echo "Host '$(HOST_RANLIB)' not found in PATH"; exit 1; }; \
	mkdir -p "$(PREFIX)/bin"; \
	for tool in ar ranlib; do \
		dest="$(PREFIX)/bin/$(TARGET)-$$tool"; \
		sed -e 's/@TARGET@/$(TARGET)/g' \
		    -e "s|@HOST_AR@|$$hostar|g" \
		    -e "s|@HOST_RANLIB@|$$hostranlib|g" \
		    "$(HERE)/amix-ar-wrapper.sh" > "$$dest.amix-tmp"; \
		rm -f "$$dest"; \
		mv "$$dest.amix-tmp" "$$dest"; \
		chmod 755 "$$dest"; \
		echo "Installed $$dest (delegates to host $$tool)"; \
	done

# Build libgcc.a from the freestanding libgcc2 helper routines.  One object per
# function (-DL<name>), compiled through the installed wrapper compiler so the
# assembler fixups apply, then archived with the (now working) target ar.
# libgcc2's soft-arithmetic helpers are freestanding, so this needs no AMIX
# sysroot/libc; it only requires the wrapper compiler + working ar to be
# installed already.  `all' sequences install-gcc-wrapper before this; the
# guards below give a clear error if libgcc is built before that.
libgcc: install-target-ar
	@test -f "$(GCC_SRC)/libgcc2.c" || { echo "Missing $(GCC_SRC)/libgcc2.c; run 'make extract'"; exit 1; }
	@test -f "$(GCC_BUILD)/tm.h" || { echo "Missing $(GCC_BUILD)/tm.h; run 'make install-gcc' first"; exit 1; }
	@grep -q 'amix gcc wrapper' "$(TARGET_CC)" 2>/dev/null || { \
		echo "$(TARGET_CC) is not the AMIX wrapper compiler; run 'make install-gcc-wrapper' first"; exit 1; }
	rm -rf $(LIBGCC2_BUILD_DIR)
	mkdir -p $(LIBGCC2_BUILD_DIR)
	@set -e; objs=""; \
	for name in $(LIBGCC2_FUNCS); do \
		echo "libgcc2: $$name"; \
		PATH="$(PATH_FOR_BUILD)" "$(TARGET_CC)" $(LIBGCC2_BUILD_CFLAGS) $(LIBGCC2_BUILD_INCLUDES) \
			-DL$$name -c "$(GCC_SRC)/libgcc2.c" -o "$(LIBGCC2_BUILD_DIR)/$$name.o"; \
		objs="$$objs $$name.o"; \
	done; \
	cd "$(LIBGCC2_BUILD_DIR)" && rm -f libgcc.a && \
		"$(TARGET_AR)" rc libgcc.a $$objs && \
		"$(TARGET_RANLIB)" libgcc.a
	@echo "Built $(LIBGCC2_BUILD_DIR)/libgcc.a"

install-libgcc: libgcc
	mkdir -p $(GCC_LIBDIR)
	cp $(LIBGCC2_BUILD_DIR)/libgcc.a $(LIBGCC_A)
	"$(TARGET_RANLIB)" $(LIBGCC_A)
	@echo "Installed $(LIBGCC_A)"

env:
	@mkdir -p $(BUILDDIR)
	@printf '%s\n' '# Source this file before cross-compiling for AMIX.' > $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CROSS_TARGET="$(TARGET)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CROSS_PREFIX="$(PREFIX)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export PATH="$(PREFIX)/bin:$$PATH"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_ROOT="$(AMIX_ROOT)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_SYSROOT="$(SYSROOT)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_CRT_DIR="$(AMIX_CRT_DIR)"' >> $(BUILDDIR)/env.sh
	@printf '%s\n' 'export AMIX_KERNEL_CFLAGS="$(AMIX_KERNEL_CFLAGS)"' >> $(BUILDDIR)/env.sh
	@echo "Wrote $(BUILDDIR)/env.sh"

test-random: install-gcc-wrapper env
	mkdir -p $(BUILDDIR)/test
	$(TARGET_CC) -S $(AMIX_KERNEL_CFLAGS) \
		-o $(BUILDDIR)/test/random.s \
		$(AMIX_ROOT)/usr/sys/amiga/driver/random.c
	perl -pi -e 's/^(\s*\.lcomm\s+[^,]+,[^,]+),\d+\s*$$/$$1\n/' $(BUILDDIR)/test/random.s
	$(PREFIX)/bin/$(TARGET)-as -m68020 -o $(BUILDDIR)/test/random.o $(BUILDDIR)/test/random.s
	file $(BUILDDIR)/test/random.o
	$(PREFIX)/bin/$(TARGET)-nm -a $(BUILDDIR)/test/random.o | head

test-hello: all check-runtime
	mkdir -p $(BUILDDIR)/test
	printf '%s\n' '#include <stdio.h>' 'int main(void) { puts("hello from AMIX cross"); return 0; }' > $(BUILDDIR)/test/hello.c
	AMIX_SYSROOT="$(SYSROOT)" AMIX_CRT_DIR="$(AMIX_CRT_DIR)" $(TARGET_CC) $(CPUFLAGS) -o $(BUILDDIR)/test/hello $(BUILDDIR)/test/hello.c
	file $(BUILDDIR)/test/hello

# End-to-end proof that a program using 64-bit integer arithmetic both
# compiles and links: the division/modulo/shift below force calls to
# __udivdi3/__umoddi3/__lshrdi3, which must resolve from the installed
# libgcc.a.  Requires the AMIX crt objects + libc.so.1 in the sysroot (like
# test-hello).  A successful link with no unresolved symbols is the proof.
test-uint64: install-libgcc env
	mkdir -p $(BUILDDIR)/test
	printf '%s\n' \
		'/* Forces the 64-bit soft-integer helpers __udivdi3/__umoddi3/__lshrdi3. */' \
		'unsigned long long udiv(unsigned long long a, unsigned long long b) { return a / b; }' \
		'unsigned long long umod(unsigned long long a, unsigned long long b) { return a % b; }' \
		'unsigned long long shr (unsigned long long a, int n)                { return a >> n; }' \
		'int main(void) {' \
		'	return (int)(udiv(1000000000000ULL, 7ULL) + umod(1000003ULL, 7ULL)' \
		'	           + shr((unsigned long long) 1 << 40, 8));' \
		'}' \
		> $(BUILDDIR)/test/uint64.c
	$(TARGET_CC) $(CPUFLAGS) -o $(BUILDDIR)/test/uint64 $(BUILDDIR)/test/uint64.c
	file $(BUILDDIR)/test/uint64
	@echo "64-bit helpers pulled from libgcc.a (expect T, defined):"
	$(PREFIX)/bin/$(TARGET)-nm $(BUILDDIR)/test/uint64 | grep -E '__udivdi3|__umoddi3|__lshrdi3'

# Regression test for the SGS "tdivs.l/tdivu.l <ea>,%dR:%dQ" assembler fixup
# (see fix_asm in amix-gcc-wrapper.sh).  gcc emits the 68020 32/32 divide-with-
# remainder for every variable-divisor "%"/"/"; GNU as 2.8.1 mis-assembles the
# raw SGS spelling as the 64-bit-dividend "DIVS.L Dr:Dq" (SIZE bit set), which
# overflows and leaves the operands unchanged -> wrong results.  The wrapper
# rewrites it to "divsl.l"/"divul.l" (32-bit dividend, 32r:32q).  This target
# compiles signed+unsigned "%"/"/" through the installed wrapper at both the
# -O0 and -O register shapes and checks the *object code*: every emitted divide
# must disassemble as the 32-bit-dividend form ("divsll"/"divull", SIZE clear,
# both registers preserved) and NONE as the broken 64-bit form ("divsl"/"divul").
#
# Failure mode against the PRE-FIX wrapper (proof this test bites): the modulo
# ops assemble to the 64-bit "divsl"/"divul" form, so the "no broken form" check
# below fails; at -O0 the divides do too, so the "correct form present" check
# also fails.  A pass therefore requires the fixup to be installed.
test-divmod: install-gcc-wrapper env
	mkdir -p $(BUILDDIR)/test
	printf '%s\n' \
		'/* Variable-divisor signed+unsigned % and / force gcc to emit the' \
		'   68020 32/32 divide-with-remainder (SGS tdivs.l/tdivu.l ea,%dR:%dQ).' \
		'   Known answers on target: smod/umod(351,151)=49, sdiv/udiv(351,151)=2.' \
		'   The objdump check in the Makefile is what actually gates the test. */' \
		'int          smod(int a, int b)                   { return a % b; }' \
		'unsigned int umod(unsigned int a, unsigned int b) { return a % b; }' \
		'int          sdiv(int a, int b)                   { return a / b; }' \
		'unsigned int udiv(unsigned int a, unsigned int b) { return a / b; }' \
		'int main(void) {' \
		'	return smod(351,151) + (int)umod(351u,151u)' \
		'	     + sdiv(351,151) + (int)udiv(351u,151u); /* = 102 */' \
		'}' \
		> $(BUILDDIR)/test/divmod.c
	@set -e; status=0; \
	for opt in -O0 -O; do \
		obj="$(BUILDDIR)/test/divmod$$opt.o"; \
		$(TARGET_CC) $(CPUFLAGS) $$opt -c -o "$$obj" $(BUILDDIR)/test/divmod.c; \
		dis="$$($(PREFIX)/bin/$(TARGET)-objdump -d "$$obj")"; \
		echo "==== $$opt ===="; echo "$$dis" | grep -Ew 'divsl|divul|divsll|divull' || true; \
		if ! printf '%s\n' "$$dis" | grep -Ewq 'divsll|divull'; then \
			echo "FAIL$$opt: no 32-bit-dividend divide (divsll/divull) emitted"; status=1; \
		fi; \
		if printf '%s\n' "$$dis" | grep -Ewq 'divsl|divul'; then \
			echo "FAIL$$opt: broken 64-bit-dividend form (divsl/divul) still emitted"; status=1; \
		fi; \
	done; \
	test $$status -eq 0 && echo "test-divmod PASS: both registers preserved, no 64-bit-dividend form"

clean:
	rm -rf $(BUILDDIR)

distclean: clean
	rm -rf $(SRCDIR) $(DISTDIR)
