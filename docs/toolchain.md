# Reproducing phase-one checks

The baseline is x86-64 Linux with Debian 13, GNU Make 4.4.1, GCC/G++ 14.2
and Python 3.12. The flow uses free tools and requires no EDA license. The
package installer verifies the SHA-256 of each simulator and extracts it into
a directory owned by the current user.

On Debian 13, install Git, Bash, curl, CA certificates, Make, G++, Perl and
Python 3 through the system package manager. The extracted Icarus package also
uses `libreadline8t64`.

```sh
./scripts/install_simulators.sh
export PATH="$PWD/.toolchain/bin:$PATH"
make check
make test-iverilog
make waves
```

| Tool | Pin | Phase-one use |
| --- | --- | --- |
| Verilator | Debian `5.048-1` | Lint, timed RTL simulation, bound SVA and UVM |
| Icarus Verilog | Debian `12.0-2+b1` | Independent four-state simulation of both SystemVerilog testbenches |
| Accellera UVM | `2020.3.1`, commit `78c06547a2a0a29b3dc9dcafae62b75b2ff61544` | APB/SPI smoke |
| OSS CAD Suite, Linux x86-64 | `2026-11-23` | UVM toolchain cross-check and Yosys structural checks |

Developers can use equivalent system-installed tools without the installer.
`VERILATOR`, `IVERILOG`, `VVP`, `PYTHON` and `YOSYS` override the tool
commands. `BUILD_DIR` selects the output directory and `JOBS` controls the
number of C++ build workers. Choose a fresh `BUILD_DIR` when switching tool
versions. Simulation logs and the VCD are under `build/` by default. The
Verilator run enables the bound properties. Icarus runs the procedural
checks without the concurrent SVA.

## UVM compatibility

The runner fetches the pinned Accellera source unless `UVM_HOME` points to
an existing source tree. It uses `--binary --timing --assert` and
`UVM_NO_DPI`. The smoke uses a class-based sequence, a sequencer, an APB
agent, a scoreboard and an independently driven mode-0 SPI slave.

Verilator 5.032 failed to elaborate the minimal UVM probe at
`uvm_coreservice.svh:379` with an unresolved `type_id`.
Icarus 14.0-devel rejected UVM constructs including unpacked structs,
streaming concatenations and pure virtual class methods.
The smoke passes on both the installed Verilator 5.048 package and
Verilator 5.055-devel from the pinned OSS CAD Suite.

```sh
make uvm
```

The UVM compile and simulation logs are in `BUILD_DIR/uvm`.
The smoke suite does not require UVM DPI facilities or functional coverage.
Full UVM regression and coverage collection are later milestones.

## Structural RTL check

Download the Linux x86-64 archive from the
[OSS CAD Suite 2026-11-23 release](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-11-23).
The archive used here had SHA-256
`c01d93f2f9091ba7eeb18540334fa0aaefa843b343cbdd627fd7669391de47ba`.
With its `bin` directory on `PATH`, run the checks with Yosys 0.71+77
(`11d972c20`).

```sh
make structural
```

This elaborates each wrapper, lowers processes and checks connectivity.
Technology mapping, gate-level simulation and physical implementation are
tracked separately. SymbiYosys v0.71-7 was available in the pinned suite.
Formal proofs and an OpenROAD/SKY130 implementation are pending.
