# Verification plan

The [functional specification](specification.md) and [register map](register-map.md)
define expected behavior. Scenario names in the [traceability matrix](traceability.md)
identify the checks for each requirement. The [milestone tracker](../reports/milestones.md)
records executed runs and observed results.

## Phase 1 suite

| Entry point | Scope | Pass criterion |
| --- | --- | --- |
| `make lint` | Elaborates and lints both full peripheral wrappers | Both tops lint successfully |
| `make test` | Standalone FIFO and SPI engine checks, plus APB4 and AXI4-Lite integration checks with bound SVA | Self-checking benches finish without a mismatch, timeout or assertion failure |
| `make uvm` | Accellera UVM smoke against the APB4 peripheral | UVM test completes with zero errors and fatals |
| `make waves` | Replays integration with tracing enabled and renders waveform figures | The same checks pass and figures are generated from the trace |

The SPI checker uses the external SCLK, CS, MOSI and MISO pins. It compares
observed transitions and transmitted bits with a software-side description of
the frame, drives independent receive data and checks the resulting RX word.
The bus tests check responses and verify effects through subsequent MMIO
reads, queue order and interrupt observations. AXI4-Lite checks independently
vary when AW, W and AR arrive, hold response ready low and compare held data
and responses during stalls. The UVM smoke routes APB transactions from an
active sequence through the driver and uses monitored transactions for
checking. This smoke exercises a serial frame through the actual RTL.

The integration run binds [SVA](../assertions/regipulse_properties.sv) to the
core and AXI4-Lite bridge. The first set checks reset, exclusive chip select,
start and abort preconditions, completion, RX acceptance and overflow,
interrupt set-versus-clear priority and masking, and AXI4-Lite response
stability under backpressure.

Tests must synchronize stimuli and observations to their relevant clock edges.
Use bounded waits on bus handshakes and SPI completion so a hung design gives
a failing result. Build the smoke against the pinned UVM and simulator
versions in the [toolchain guide](toolchain.md) before expanding the UVM suite.

## Regression and coverage plan

Expand the reusable testbench with APB4, AXI4-Lite and SPI agents, bus and SPI
monitors, an independent transaction-level reference model and scoreboard.
The reference model owns configuration, queue contents and interrupt state
and consumes observed register operations in commit order. The SPI monitor
reconstructs frames from pins and publishes individual frame results. Feed
both the register model predictions and observed frames to the scoreboard.

Keep the directed sequences for deterministic reproduction. Add constrained
random sequences for frame configuration and payload, queue occupancy,
long-duration backpressure, invalid commands and resets in flight. Capture the
seed, failing transaction sequence and first mismatch for every failure.
Run the same seed set against both wrappers and add seeds in response to
observed coverage gaps.

| Coverage dimension | Planned bins |
| --- | --- |
| Serial behavior | All four modes, both bit orders, bit widths `1`, `2–7`, `8`, `9–31` and `32`, multiple chip selects and divider minimum, typical and maximum |
| Register operations | Legal read, full-write, partial-write and zero-strobe by register, plus alignment, decode, direction and semantic failures |
| FIFO behavior | Empty, interior and full, each crossed with accepted push, accepted pop, both and rejected operations where reachable |
| AXI4-Lite | AW first, W first and same-cycle arrival, AR overlap, both arbitration preferences and independent B/R backpressure |
| Recovery | Reset and abort during setup, shifting and CS hold, and reset with bus handshakes or responses pending |
| Interrupt behavior | Every event with mask on and off, W1C with zero and one, clear coincident with event, overflow and completion together |

Planned crosses include mode × bit order × width class, mode × divider class,
bus × access result, FIFO state × completion × RX pop, and interrupt event ×
mask state. Publish the covered and reachable bin counts, document impossible
or structurally excluded combinations and target at least 95% of defined
reachable functional bins. Measure line, branch and toggle coverage where
the simulator supports them, and report code coverage separately from
functional coverage.

## Assertions, proofs and fault injection

| Area | Properties to implement and check in the advanced verification milestone |
| --- | --- |
| FIFO | Count and pointers stay in range, accepted requests produce the expected count change, and data order is preserved at wrap and on concurrent operations |
| Register block | Invalid accesses preserve configuration and FIFO state while reporting the documented event, strobes affect only selected lanes, and destructive reads pop once |
| SPI engine | Chip selects are one-hot or inactive, clock phase changes according to the divider, and abort or reset releases CS without committing an interrupted frame |
| Interrupts | Active IRQ equals pending-and-enabled, events latch while masked, and concurrent set wins over W1C |
| Bus protocols | APB side effects occur on access completion, and AXI4-Lite holds valid responses and payload stable during backpressure |

Run SVA in compatible simulation flows. Use SymbiYosys or a compatible open
formal tool for selected FIFO, register, reset, SPI, interrupt and error
properties. Record proof mode, bound, parameters, solver and assumptions.
Start with small FIFO depths and divider values, then extend practical bounds
as justified. Use cover goals to show that relevant boundary conditions are
reachable under the assumptions.

Exercise recovery from injected resets, stalled responses, depleted or
saturated queues and malformed register accesses. Add controlled internal
fault injection only when the injection point, expected effect and recovery
property can be checked independently. Record the observed symptom and
post-recovery transaction in each scenario.
