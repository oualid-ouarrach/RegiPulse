#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=${BUILD_DIR:-"$repo_dir/build/uvm"}
uvm_tag=2020.3.1
uvm_commit=78c06547a2a0a29b3dc9dcafae62b75b2ff61544
rtl_sources=()
while (( $# )) && [[ $1 != -- ]]; do
    rtl_sources+=("$1")
    shift
done
if (( $# )); then shift; fi
if (( ${#rtl_sources[@]} == 0 )); then
    echo 'Usage: run_uvm.sh <ordered RTL sources> [-- <simulation plusargs>]' >&2
    exit 2
fi

mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd)
uvm_home=${UVM_HOME:-"$build_dir/uvm-core"}
if [[ -z ${UVM_HOME:-} ]]; then
    if [[ ! -d $uvm_home/.git ]]; then
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$uvm_tag" \
            https://github.com/accellera-official/uvm-core.git "$uvm_home"
    fi
    if [[ $(git -C "$uvm_home" rev-parse HEAD) != "$uvm_commit" ]]; then
        echo "Expected Accellera UVM $uvm_tag ($uvm_commit) in $uvm_home" >&2
        exit 2
    fi
fi
if [[ ! -f $uvm_home/src/uvm_pkg.sv ]]; then
    echo 'UVM_HOME must point to the Accellera UVM source root' >&2
    exit 2
fi
uvm_home=$(cd "$uvm_home" && pwd)

verilator=${VERILATOR:-verilator}
printf 'Building UVM smoke with %s\n' "$("$verilator" --version)"
if ! "$verilator" --binary --timing --assert \
    -Wno-fatal -j "${UVM_JOBS:-2}" --output-groups 8 -CFLAGS -O0 \
    --timescale 1ns/1ps \
    --top-module rp_uvm_top --Mdir "$build_dir/obj" \
    +define+UVM_NO_DPI "+incdir+$uvm_home/src" \
    "$uvm_home/src/uvm_pkg.sv" "${rtl_sources[@]}" \
    "$repo_dir/verification/uvm/rp_apb_if.sv" \
    "$repo_dir/verification/uvm/rp_apb_pkg.sv" \
    "$repo_dir/verification/uvm/rp_apb_smoke_pkg.sv" \
    "$repo_dir/verification/uvm/rp_uvm_top.sv" > "$build_dir/build.log" 2>&1; then
    tail -n 40 "$build_dir/build.log" >&2
    exit 1
fi

ulimit -c 0
"$build_dir/obj/Vrp_uvm_top" +UVM_TESTNAME=rp_apb_smoke_test "$@" | tee "$build_dir/simulation.log"
