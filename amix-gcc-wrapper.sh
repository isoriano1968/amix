#!/usr/bin/env bash
set -e

target="@TARGET@"
bindir="$(cd "$(dirname "$0")" && pwd)"
prefix="$(cd "$bindir/.." && pwd)"
real="$bindir/$target-gcc.real"
as="$bindir/$target-as"
ld="$bindir/$target-ld"
sysroot="${AMIX_SYSROOT:-$prefix/$target/sysroot}"
crt_dir="${AMIX_CRT_DIR:-$sysroot/usr/ccs/lib}"

common_cflags=(-I"$sysroot/usr/include")
default_lib_dirs=("$sysroot/usr/lib")
tmpfiles=()

cleanup()
{
	rm -f "${tmpfiles[@]}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

fix_asm()
{
	# SGS ".swbeg &N" (emitted before every switch jump table) occupies
	# 4 bytes under the native SGS assembler, and gcc's dispatch is
	# hard-coded around that: "jmp 6(%pc,%d0.w)" expects the table at
	# ext-word+6 = jmp-end+4.  GNU as parses .swbeg but emits ZERO
	# bytes, so every switch case is entered 4 bytes late, skipping its
	# first instruction(s) and branching on stale condition codes.
	# Replace .swbeg with an explicit 4-byte filler to restore the
	# layout the compiler assumed.  (Found via amix-packagemanager
	# contents-fsck: validate_rest's switch misdispatched on the box.)
	perl -pi -e 's/^(\s*)\.swbeg\s+&(\d+)[ \t]*$/$1.long $2/' "$1"

	perl -pi -e 's/^(\s*\.lcomm\s+[^,]+,[^,]+),\d+\s*$/$1\n/' "$1"
	perl -0pi -e '
		sub split_operands {
			my ($s) = @_;
			my $depth = 0;
			for (my $i = 0; $i < length($s); $i++) {
				my $ch = substr($s, $i, 1);
				$depth++ if $ch eq "(";
				$depth-- if $ch eq ")";
				if ($ch eq "," && $depth == 0) {
					return (substr($s, 0, $i), substr($s, $i + 1));
				}
			}
			return;
		}
		s{^(\s*cmp\.[bwl]\s+)([^\n]+)$}{
			my ($prefix, $ops) = ($1, $2);
			my ($left, $right) = split_operands($ops);
			defined $right ? "$prefix$right,$left" : "$prefix$ops";
		}egm;
	' "$1"
}

compile_one()
{
	local src="$1"
	local obj="$2"
	shift 2
	local asmfile

	asmfile="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.s")"
	tmpfiles+=("$asmfile")

	"$real" -S "${common_cflags[@]}" "$@" "$src" -o "$asmfile"
	fix_asm "$asmfile"
	"$as" -m68020 -o "$obj" "$asmfile"
}

resolve_lib()
{
	local name="$1"
	local dir candidate

	test "$name" = c && {
		printf '%s\n' "$sysroot/usr/lib/libc.so.1"
		return 0
	}

	for dir in "${lib_dirs[@]}" "${default_lib_dirs[@]}"; do
		for candidate in "$dir/lib$name.so" "$dir/lib$name.so.1" "$dir/lib$name.a"; do
			test -f "$candidate" && {
				printf '%s\n' "$candidate"
				return 0
			}
		done
	done

	printf 'amix gcc wrapper: cannot resolve -l%s\n' "$name" >&2
	return 1
}

has_c=no
has_S=no
for arg in "$@"; do
	case "$arg" in
		-c) has_c=yes ;;
		-S) has_S=yes ;;
	esac
done

if test "$has_S" = yes; then
	exec "$real" "${common_cflags[@]}" "$@"
fi

compile_flags=()
sources=()
objects=()
ld_flags=()
lib_dirs=()
libs=()
out=a.out
compile_out=
skip=

while test $# -gt 0; do
	arg="$1"
	shift

	if test "$skip" = o; then
		out="$arg"
		compile_out="$arg"
		skip=
		continue
	fi

	case "$arg" in
		-o)
			skip=o
			;;
		-I|-D|-U|-L)
			test $# -gt 0 || { echo "amix gcc wrapper: $arg needs an argument" >&2; exit 1; }
			next="$1"
			shift
			case "$arg" in
				-L) lib_dirs+=("$next") ;;
				*) compile_flags+=("$arg" "$next") ;;
			esac
			;;
		-I*|-D*|-U*|-O*|-m*|-f*|-W*|-g|-traditional)
			compile_flags+=("$arg")
			;;
		-L*)
			lib_dirs+=("${arg#-L}")
			;;
		-l*)
			libs+=("${arg#-l}")
			;;
		*.c)
			sources+=("$arg")
			;;
		*.o|*.a|*.so|*.so.[0-9]*)
			objects+=("$arg")
			;;
		*)
			if [[ "$arg" == -* ]]; then
				ld_flags+=("$arg")
			else
				objects+=("$arg")
			fi
			;;
	esac
done

for input in "${sources[@]}" "${objects[@]}"; do
	if test -n "$input" && test "$out" = "$input"; then
		echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
		exit 1
	fi
done

if test "$has_c" = yes; then
	if test "${#sources[@]}" -eq 0; then
		for input in "${objects[@]}"; do
			if test -n "$input" && test "$compile_out" = "$input"; then
				echo "amix gcc wrapper: refusing to overwrite input file '$input'" >&2
				exit 1
			fi
		done
		exec "$real" "${common_cflags[@]}" -c "${compile_flags[@]}" -o "$compile_out" "${objects[@]}"
	fi
	if test "${#sources[@]}" -gt 1 && test -n "$compile_out"; then
		echo "amix gcc wrapper: -o with -c and multiple sources is not supported" >&2
		exit 1
	fi
	for src in "${sources[@]}"; do
		obj="$compile_out"
		test -n "$obj" || obj="${src%.*}.o"
		compile_one "$src" "$obj" "${compile_flags[@]}"
	done
	exit 0
fi

for src in "${sources[@]}"; do
	obj="$(mktemp "${TMPDIR:-/tmp}/amix-gcc.XXXXXX.o")"
	tmpfiles+=("$obj")
	compile_one "$src" "$obj" "${compile_flags[@]}"
	objects+=("$obj")
done

resolved_libs=()
if test "${#libs[@]}" -eq 0; then
	libs=(c)
fi
for lib in "${libs[@]}"; do
	resolved_libs+=("$(resolve_lib "$lib")")
done

for crt in crt1.o crti.o crtn.o; do
	test -f "$crt_dir/$crt" || {
		echo "amix gcc wrapper: missing $crt_dir/$crt; set AMIX_CRT_DIR" >&2
		exit 1
	}
done

exec "$ld" -o "$out" \
	"$crt_dir/crt1.o" "$crt_dir/crti.o" \
	"${objects[@]}" "${ld_flags[@]}" "${resolved_libs[@]}" \
	"$crt_dir/crtn.o"
