# Requirements traceability

The table names checks in the [directed integration bench](../tests/tb_regipulse.sv),
[component bench](../tests/tb_components.sv) and [UVM smoke](../verification/uvm/rp_apb_smoke_pkg.sv).
Named assertions are [properties](../assertions/regipulse_properties.sv) bound during
the Verilator integration run. Execution status is in the [milestone tracker](../reports/milestones.md).
For advanced scope, see the [verification plan](verification-plan.md).

| ID | Requirement | Phase 1 check |
| --- | --- | --- |
| BUS-01 | APB4 completes in access with zero wait states and applies each request’s side effect once | `apb_register_access`, `rp_apb_smoke_test` |
| BUS-02 | AXI4-Lite accepts AW and W independently and issues one response per pair | `axi_channels` |
| BUS-03 | AXI4-Lite holds B and R responses stable under backpressure and permits read and write progress independently | `axi_channels`, `hold_write_response`, `hold_read_response` |
| BUS-04 | An AXI4-Lite read and a complete write share the register port without dropping either request | `axi_channels` |
| BUS-05 | Wrappers produce their documented error response and expose the same register behavior | `apb_register_access`, `axi_channels`, `axi_spi` |
| REG-01 | Reset exposes default format, divider, empty FIFO status, cleared interrupts and fixed ID | `apb_register_access`, `apb_abort_reset`, `rp_apb_smoke_test`, `reset_state` |
| REG-02 | Register direction, address alignment and full-width decode are enforced | `apb_register_access`, `axi_channels` |
| REG-03 | Byte strobes merge configuration and write zeroes into unstrobed TX lanes. Zero-strobe writes to writable registers are no-ops | `apb_register_access`, `axi_channels` |
| REG-04 | Illegal configuration and command encoding propagate errors without changing the active configuration | `apb_register_access` |
| REG-05 | Busy rejects incompatible commands and configuration writes, while TX enqueue and RX dequeue remain available | `apb_abort_reset` |
| REG-06 | TX and RX flush discard queued words individually while idle | `apb_fifo_irq` |
| SPI-01 | Every CPOL and CPHA combination has the documented idle, launch and sample edges | `apb_mode0`, `apb_mode1`, `apb_mode2`, `apb_mode3`, `check_frame` |
| SPI-02 | Frame width and bit order select low-word bits, and received data is right-aligned | `apb_mode0`–`apb_mode3`, `check_frame` |
| SPI-03 | Divider controls every half-period and CS setup and hold timing | `apb_mode0`–`apb_mode3`, `check_frame` |
| SPI-04 | An accepted start consumes one queued TX word and selects exactly one valid active-low CS | `apb_fifo_irq`, `check_frame`, `start_requires_data`, `chip_select` |
| SPI-05 | Completion makes one RX result available when space exists, sets DONE, and releases busy | `apb_mode0`–`apb_mode3`, `axi_spi`, `rp_apb_smoke_test`, `completion_is_atomic` |
| FIFO-01 | FIFO words are returned in order, including after pointer wrap, and level and empty/full flags reflect occupancy | `apb_fifo_irq`, `rp_fifo_check` |
| FIFO-02 | Depth 1, non-power-of-two depth 3 and maximum depth 255 operate correctly | `rp_fifo_check` |
| FIFO-03 | Full simultaneous push and pop preserve count and return the old head. Empty simultaneous requests retain the incoming word | `rp_fifo_check` |
| FIFO-04 | An RX completion at full preserves older words unless a simultaneous RX read frees a slot | `apb_fifo_irq`, `apb_rx_full_pop`, `receive_accept`, `receive_overflow` |
| FIFO-05 | An RX read at empty reports underflow and returns zero, including when a new word arrives on the same edge | `apb_fifo_irq`, `apb_rx_empty_pop` |
| FIFO-06 | TX overflow and TX underflow report bus errors with the corresponding IRQ events | `apb_fifo_irq` |
| IRQ-01 | Events are sticky while masked, enabled pending events assert the level-sensitive IRQ and W1C clears selected bits | `apb_fifo_irq`, `rp_apb_smoke_test`, `irq_mask` |
| IRQ-02 | A new event wins over a same-cycle clear of its status bit | `apb_done_w1c`, `event_priority` |
| IRQ-03 | RX overflow and DONE latch together on a dropped receive word | `apb_fifo_irq` |
| IRQ-04 | Rejected accesses, command errors and accepted aborts set their distinct events | `apb_register_access`, `apb_abort_reset` |
| REC-01 | Abort restores idle serial pins, discards the active frame and permits a follow-up transfer | `apb_abort_reset`, `check_abort_and_reset`, `abort_stops_frame` |
| REC-02 | Reset clears active SPI, pending interrupts and queue state, and permits a follow-up transfer | `apb_abort_reset`, `check_abort_and_reset` |
| REC-03 | Reset cancels pending AXI4-Lite captures and responses | `axi_reset`, `reset_channels` |

## Additional verification targets

Each phase 1 scenario samples specific cases. The advanced suite will add
systematic sweeps over address width, FIFO depth, frame length, divider and
chip-select combinations, the full AXI4-Lite backpressure and reset matrix,
and set-versus-clear coincidence checks for every interrupt event.
The [verification plan](verification-plan.md) defines coverage, fault
injection and formal objectives for those extensions.
