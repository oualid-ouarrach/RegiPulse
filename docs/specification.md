# RegiPulse functional specification

RegiPulse is a single-clock, four-wire SPI master peripheral. Integrate
`regipulse_apb` for APB4 or `regipulse_axil` for AXI4-Lite. Both instances
expose the same [register map](register-map.md) and SPI behavior. See the
[architecture](architecture.md) for bus and block integration details.

## Configuration and interface

| Parameter | Default | Supported values |
| --- | --- | --- |
| `ADDR_WIDTH` | 12 | 6 or more address bits |
| `FIFO_DEPTH` | 8 | 1–255 entries per FIFO, including non-powers of two |
| `NUM_CS` | 4 | 1–16 active-low chip-select outputs |

Bus addresses are peripheral-relative byte offsets. The full address width
participates in register decoding. The software interface exposes two
independent 32-bit FIFOs and one level-sensitive interrupt. Each clocked block
uses the rising edge of `clk_i`. `rst_ni` is active low and is sampled on that
edge. System integration must meet `clk_i` setup and hold timing for reset.

| Signal | Direction | Function |
| --- | --- | --- |
| `sclk_o` | Out | SPI serial clock, with idle level set by `CPOL` |
| `mosi_o` | Out | Master transmit data |
| `miso_i` | In | Slave transmit data, sampled by the SPI engine |
| `cs_no` | Out | Active-low chip selects, one per slave |
| `irq_o` | Out | Level-sensitive masked interrupt |

## Serial transaction

Software queues TX words, programs the frame format and divider, then writes
`START`. An accepted start removes the oldest TX word, captures configuration,
drives exactly one chip select low and begins a full-duplex frame. One command
transfers one frame. Queued words wait for additional `START` commands.
Software may enqueue TX data and drain existing RX data during a frame.

Each frame transfers `BITS_MINUS_ONE + 1` bits. The TX word supplies the low
bits of the selected length. The RX word contains the received bits in the same
positions, with zeroes in the unused upper bits. `LSB_FIRST` selects whether bit
0 or bit `BITS_MINUS_ONE` goes first. The engine holds all unselected chip
selects high during a frame.

| SPI mode | CPOL | CPHA | Leading edge | Sample edge | MOSI changes |
| --- | --- | --- | --- | --- | --- |
| 0 | 0 | 0 | Rising | Rising | At CS assertion for the first bit, then falling |
| 1 | 0 | 1 | Rising | Falling | Rising |
| 2 | 1 | 0 | Falling | Falling | At CS assertion for the first bit, then rising |
| 3 | 1 | 1 | Falling | Rising | Falling |

One SCLK half-period holds `DIVIDER + 1` peripheral cycles. The first leading
edge is one half-period after chip select asserts. Each bit uses one leading and
one trailing edge. SCLK returns to its configured idle level on the final
trailing edge. Chip select stays active for one additional half-period. SCLK is
an output signal. The SPI engine samples `miso_i` on the corresponding
`clk_i` edge and expects external MISO timing to meet setup and hold at that
sample. Board-level I/O and slave timing determine the usable maximum SCLK.

After deasserting chip select, the SPI engine supplies its completed RX word
to the register block. `BUSY` remains asserted until the register block commits
the receive outcome and `DONE` at the next rising edge. A new transfer can then
start. Software can use `BUSY` for polling, and masks and pending events for
interrupt-driven operation.

## Concurrent events and recovery

Operations use queue state preceding the commit edge. A push and a successful
pop together preserve the queue count and return the old head. At full, a
successful pop makes room for a simultaneous push. At empty, a simultaneous
push is retained, and the attempted pop reports underflow. There is no
combinational bypass from incoming to outgoing data.

The single register port serializes bus operations. A completed SPI receive
word can arrive concurrently with a bus access. A receive completion while RX
is full drops the new word and keeps queued data in order, unless the same edge
pops an existing RX word. `DONE` is set in both cases. Any interrupt event on
the same edge as a W1C write takes precedence for its bit.

An accepted `ABORT` ends an active frame on the bus commit edge, restores the
idle SCLK level and deasserts chip select. It sets `ABORTED` without committing
an RX word or setting `DONE` for the interrupted frame. Software should treat
the external slave exchange as incomplete, since an abort can shorten an SCLK
phase. Aborting does not clear queued data or previous interrupt events.

Reset restores default configuration, clears interrupt status and enables,
discards both FIFO contents and cancels any active frame and pending AXI4-Lite
transaction state. The SPI outputs after reset are all chip selects high,
SCLK low and MOSI low. The next transaction starts from the reset state with
no completion event from the aborted frame.
