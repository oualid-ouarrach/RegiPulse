#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
  echo "This installer targets x86-64 Linux. See docs/toolchain.md for other hosts." >&2
  exit 1
fi

install_dir=$(realpath -m "${1:-.toolchain}")
package_dir="$install_dir/packages"
mkdir -p "$package_dir" "$install_dir/bin"

extract_deb() {
  local url=$1
  local checksum=$2
  local target=$3
  local package="$package_dir/${url##*/}"

  if [[ ! -f $package ]]; then
    curl --fail --silent --show-error --location --retry 3 "$url" -o "$package.part"
    mv "$package.part" "$package"
  fi
  printf '%s  %s\n' "$checksum" "$package" | sha256sum --check --status
  dpkg-deb --extract "$package" "$target"
}

extract_deb 'https://deb.debian.org/debian/pool/main/v/verilator/verilator_5.048-1_amd64.deb' \
  e387099b34343ee76d3322e3cc86b3059d65c716e1d3fb2469fc366d52f9b596 "$install_dir/verilator"
extract_deb 'https://deb.debian.org/debian/pool/main/i/iverilog/iverilog_12.0-2+b1_amd64.deb' \
  febe027d2d3f5a7e570844d55758339ab5490acc09f404f214a8719d89d07056 "$install_dir/iverilog"

cat > "$install_dir/bin/verilator" <<'WRAPPER'
#!/usr/bin/env bash
prefix=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export VERILATOR_ROOT="$prefix/verilator/usr/share/verilator"
exec "$prefix/verilator/usr/bin/verilator" "$@"
WRAPPER
cat > "$install_dir/bin/iverilog" <<'WRAPPER'
#!/usr/bin/env bash
prefix=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$prefix/iverilog/usr/bin/iverilog" -B "$prefix/iverilog/usr/lib/x86_64-linux-gnu/ivl" "$@"
WRAPPER
cat > "$install_dir/bin/vvp" <<'WRAPPER'
#!/usr/bin/env bash
prefix=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec "$prefix/iverilog/usr/bin/vvp" -M "$prefix/iverilog/usr/lib/x86_64-linux-gnu/ivl" "$@"
WRAPPER
chmod +x "$install_dir/bin/verilator" "$install_dir/bin/iverilog" "$install_dir/bin/vvp"
printf 'Add %s/bin to PATH.\n' "$install_dir"
