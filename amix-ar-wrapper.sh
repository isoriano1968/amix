#!/bin/sh
# Thin archiver/ranlib that delegates to the host ar/ranlib.
#
# The bundled binutils 2.8.1 "ar" aborts under a modern glibc's
# _FORTIFY_SOURCE ("*** buffer overflow detected ***: terminated") and cannot
# create an archive at all, so it cannot build libgcc.a or any target archive.
#
# Archiving relocatable ELF is architecture-neutral: the host ar stores the
# cross-compiled m68k ELF members verbatim and writes a GNU/SVR4 archive symbol
# table (armap) that the cross "ld" reads correctly.  This script is installed
# as both @TARGET@-ar and @TARGET@-ranlib; the invoked leaf name selects which
# host tool to run.
case "${0##*/}" in
*ranlib) exec "@HOST_RANLIB@" "$@" ;;
*)       exec "@HOST_AR@" "$@" ;;
esac
