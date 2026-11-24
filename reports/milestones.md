# Milestone tracker

## Phase 1 · RTL foundation

The implementation is tracked on `feat/rtl-foundation`. Use
`git log -1 --oneline` to identify the checked-out revision.

| Area | State | Evidence |
| --- | --- | --- |
| Functional and register specification | Implemented | [Specification](../docs/specification.md), [register map](../docs/register-map.md) |
| APB4 and AXI4-Lite RTL | Validated | Both public tops pass Verilator lint and Yosys structural checks |
| SPI and FIFO components | Validated | Self-checking timing, FIFO and recovery tests passed in two simulators |
| Interrupt, error and reset behavior | Validated | Directed scenarios and 12 bound SVA properties passed |
| UVM toolchain and APB smoke | Validated | Observed transactions and simulator details below |
| Requirements mapping | Implemented | [Traceability matrix](../docs/traceability.md) |
| GitHub Actions | Configured | [Workflow](../.github/workflows/rtl.yml) passed actionlint 1.7.12. Its commands passed in a clean Debian 13 container. A hosted run requires publication. |

### Measurements

- The component test exercised 10 SPI frames, including the maximum clock
  divider, and FIFO depths 1, 3 and 255.
- The directed integration test completed 13 scenarios in 16.270 µs of
  simulated time. It checked independent SPI transmit and receive values,
  bus timing, FIFO boundaries, simultaneous receive and pop, IRQ event
  priority, abort and recovery. Verilator 5.048 and Icarus 12.0 passed both
  this test and the component test.
- Accellera UVM 2020.3.1 on Verilator 5.048 and 5.055-devel observed 13 APB
  transfers and one mode-0 SPI frame in 730 ns with zero UVM errors and zero
  fatals on both simulators.
  The SPI slave captured `0xa6` and returned `0x3d`. In a separate run,
  the deliberately altered expected ID raised one scoreboard error and the
  simulator exited with status 1.
- Yosys 0.71+77 reported zero structural problems for either top. The
  process-lowered design has 327 APB and 373 AXI4-Lite RTLIL cells at default
  parameters. These counts come from the generic frontend before technology
  mapping.
- The [waveform plots](../assets/) derive from the directed simulation VCD.
  Icarus and Verilator produced byte-identical SVG plots.
  `make waves` regenerates them under `build/waves/`.

### Known limitations

- Icarus runs the procedural checks. Verilator executes the bound concurrent
  assertions. Icarus 12 emits a conservative sensitivity-list notice for the
  register decode `always_comb`.
- The UVM smoke exercises one APB-driven mode-0 SPI frame. The AXI4-Lite and
  SPI UVM agents, coverage metrics and formal proofs remain open.
- The pinned UVM library emits two notices about the DPI-disabled build
  and the resulting component-name validation limits.

## Remaining work

| Milestone | Pending validation |
| --- | --- |
| A · UVM regression | AXI4-Lite and SPI agents, reference model, scoreboard extension and multi-seed execution |
| B · Verification depth | Functional, cross and code coverage, documented exclusions, formal properties, fault injection and recovery |
| C · Software integration | Portable C driver, unit tests, real RTL co-simulation and automotive sensor example |
| D · Synthesis and DFT | Technology mapping, gate-level simulation, educational scan and scan-mode tests |
| E · Physical implementation | SKY130 floorplan through routing, STA and physical checks, experimental GDSII, measured PPA trade-offs |
| F · Release | Full regression, reproducibility check, documentation and v1.0 release review |

Milestone A is the next implementation step. Start with an independent
transaction-level SPI model and AXI4-Lite and SPI monitors so the regression
can correlate bus traffic with serial traffic.
