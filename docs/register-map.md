# Programmer’s register map

Addresses are byte offsets relative to the peripheral’s base address. Registers
are aligned 32-bit words. Byte enable `n` controls bits `8*n+7:8*n` on APB4
and AXI4-Lite. All registers and their reserved fields read as listed here.

| Offset | Name | Access | Reset value |
| --- | --- | --- | --- |
| `0x00` | `CTRL` | R/W | `0x00000038` |
| `0x04` | `DIV` | R/W | `0x00000001` |
| `0x08` | `CMD` | W | — |
| `0x0c` | `STATUS` | R | `0x0000000a` |
| `0x10` | `TXDATA` | W | — |
| `0x14` | `RXDATA` | R, pops one word | Empty |
| `0x18` | `LEVEL` | R | `0x00000000` |
| `0x1c` | `IRQ_STATUS` | R/W1C | `0x00000000` |
| `0x20` | `IRQ_ENABLE` | R/W | `0x00000000` |
| `0x24` | `ID` | R | `0x52504701` |

## Transfer configuration

| Register | Bits | Meaning |
| --- | --- | --- |
| `CTRL` | `0` | `CPOL`, SCLK idle level |
| `CTRL` | `1` | `CPHA`, sample on leading edge for 0 or trailing edge for 1 |
| `CTRL` | `2` | `LSB_FIRST`, bit 0 transmitted first when set |
| `CTRL` | `7:3` | `BITS_MINUS_ONE`, encoded frame length of 1–32 bits |
| `CTRL` | `11:8` | `CS_INDEX`, zero-based chip-select index |
| `CTRL` | `31:12` | Reserved, write zero |
| `DIV` | `15:0` | `DIVIDER`, SCLK half-period in `DIVIDER + 1` peripheral clocks |
| `DIV` | `31:16` | Reserved, write zero |

`CTRL` and `DIV` are writable while idle. A byte-enabled write merges with
the stored value. A merged `CS_INDEX` greater than or equal to `NUM_CS` or a
nonzero reserved bit rejects the write with `CMD_ERROR`. The default selects
mode 0, eight bits, MSB first, chip select 0 and SCLK at one-quarter of the
peripheral clock frequency.

## Commands and queue access

| `CMD` value | Action | Preconditions |
| --- | --- | --- |
| `0x00000000` | No operation | Any state |
| `0x00000001` | `START`, pop one TX word and begin one full-duplex frame | Idle, TX nonempty |
| `0x00000002` | `FLUSH_TX`, discard queued transmit words | Idle |
| `0x00000004` | `FLUSH_RX`, discard queued receive words | Idle |
| `0x00000008` | `ABORT`, terminate the active frame | Engine active |

`CMD` is decoded after unstrobed bytes have been set to zero. An unknown
command or a combination of commands sets `CMD_ERROR`. Starting an idle
engine with empty TX sets `TX_UNDERFLOW`. Abort discards the active frame and
preserves words still in either FIFO. Flush preserves pending interrupts and
transfer configuration.

Writing `TXDATA` pushes one word, with unstrobed bytes set to zero. Writing to
a full TX FIFO sets `TX_OVERFLOW`. A successful `RXDATA` read pops the oldest
word. An empty `RXDATA` read returns zero and sets `RX_UNDERFLOW`. Both registers
remain accessible during an active frame. A zero-byte-enable write to a valid
writable register is a successful no-op.

| Register | Bits | Meaning |
| --- | --- | --- |
| `STATUS` | `0` | `BUSY`, from frame start through the clock cycle that commits its result |
| `STATUS` | `1` | `TX_EMPTY` |
| `STATUS` | `2` | `TX_FULL` |
| `STATUS` | `3` | `RX_EMPTY` |
| `STATUS` | `4` | `RX_FULL` |
| `STATUS` | `31:5` | Reserved, reads as zero |
| `LEVEL` | `7:0` | Number of queued TX words |
| `LEVEL` | `15:8` | Number of queued RX words |
| `LEVEL` | `31:16` | Reserved, reads as zero |

## Interrupt status and enable

| Bit | Event | Trigger |
| --- | --- | --- |
| `0` | `DONE` | A frame completed, including when its RX word was dropped |
| `1` | `TX_OVERFLOW` | A write to a full TX FIFO was rejected |
| `2` | `TX_UNDERFLOW` | A `START` on an idle engine with empty TX was rejected |
| `3` | `RX_OVERFLOW` | A completed frame’s RX word was dropped because the FIFO was full |
| `4` | `RX_UNDERFLOW` | A read from an empty RX FIFO was rejected |
| `5` | `ACCESS` | An unmapped, unaligned or wrong-direction access was rejected |
| `6` | `CMD_ERROR` | A command or configuration write was rejected |
| `7` | `ABORTED` | An active frame was aborted by software |
| `31:8` | Reserved | Reads as zero, writes ignored |

Every event sets its `IRQ_STATUS` bit regardless of the corresponding
`IRQ_ENABLE` bit. `irq_o` is high whenever `IRQ_STATUS & IRQ_ENABLE` is
nonzero. Write ones to clear selected status bits in enabled byte lanes.
An event arriving in the same cycle as a clear takes priority for its bit.
`IRQ_ENABLE` accepts byte-enabled writes.

Invalid accesses return an APB `PSLVERR` or AXI4-Lite `SLVERR` response.
Wrong-direction, unmapped and unaligned accesses set `ACCESS`; the error
response for a rejected read carries zero data. A FIFO or command error that
rejects a bus operation sets its specific event. `RX_OVERFLOW` and `ABORTED`
are reported through the sticky status bits. The accepted `ABORT` write
returns a successful bus response.
