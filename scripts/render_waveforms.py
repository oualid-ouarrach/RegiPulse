#!/usr/bin/env python3
"""Render selected, annotated waveforms from the directed simulation VCD and log."""

import argparse
from bisect import bisect_left, bisect_right
from dataclasses import dataclass, field
from fractions import Fraction
from html import escape
from math import floor, log10
from pathlib import Path
import re


TOP = "tb_regipulse"
APB = ["psel", "penable", "pwrite", "paddr", "pstrb", "pwdata", "prdata", "pready", "pslverr"]
AXI_WRITE = ["awvalid", "awready", "awaddr", "wvalid", "wready", "wdata", "bvalid", "bready", "bresp"]
AXI_READ = ["arvalid", "arready", "araddr", "rvalid", "rready", "rdata", "rresp"]
SPI = ["csn", "sclk", "mosi", "miso"]
APB_CORE = {"tx_level", "rx_level", "rx_push", "rx_pop", "spi_done"}
SIGNALS = {"clk", "clk_i", "clock"} | {
    f"{bus}_{name}"
    for bus, names in [("apb", APB + SPI + ["irq"]), ("axi", AXI_WRITE + AXI_READ + SPI)]
    for name in names
}
NS = {"s": 10**9, "ms": 10**6, "us": 1000, "ns": 1, "ps": Fraction(1, 1000), "fs": Fraction(1, 10**6)}


@dataclass
class Signal:
    width: int
    times: list = field(default_factory=list)
    values: list = field(default_factory=list)

    def record(self, time, value):
        value = value.lower()
        if self.times and self.times[-1] == time:
            self.values[-1] = value
        elif not self.values or self.values[-1] != value:
            self.times.append(time)
            self.values.append(value)

    def value(self, time, before=False):
        index = (bisect_left if before else bisect_right)(self.times, time) - 1
        return self.values[index] if index >= 0 else "x"

    def number(self, time, before=False):
        value = self.value(time, before)
        return None if re.search("[^01]", value) else int(value, 2)

    def changes(self, start, stop):
        left = bisect_right(self.times, start)
        right = bisect_left(self.times, stop)
        return zip(self.times[left:right], self.values[left:right])


@dataclass
class Trace:
    signals: dict
    ns_per_tick: Fraction
    end: int

    def time_ns(self, tick):
        return f"{float(tick * self.ns_per_tick):g}"

    def get(self, *names):
        for name in names:
            if name in self.signals:
                return self.signals[name]
        raise ValueError(f"missing VCD signal {', '.join(names)} in {TOP}")


def read_vcd(path):
    scope = []
    signals = {}
    by_symbol = {}
    ns_per_tick = None
    time = 0
    header = True
    with path.open(encoding="ascii") as source:
        for line in source:
            fields = line.split()
            if not fields:
                continue
            token = fields[0]
            if header:
                if token == "$scope":
                    scope.append(fields[2])
                elif token == "$upscope":
                    scope.pop()
                elif token == "$timescale":
                    scale = line
                    while "$end" not in scale:
                        scale += next(source)
                    magnitude, unit = re.search(r"(\d+)\s*([fpnum]?s)", scale).groups()
                    ns_per_tick = int(magnitude) * NS[unit]
                elif token == "$var":
                    _, _, width, symbol, name, *_ = fields
                    top_signal = scope and scope[-1] == TOP and name in SIGNALS
                    core_signal = scope[-3:] == [TOP, "dut_apb", "core"] and name in APB_CORE
                    if top_signal or core_signal:
                        if core_signal:
                            name = f"core_{name}"
                        signals[name] = by_symbol.setdefault(symbol, Signal(int(width)))
                elif token == "$enddefinitions":
                    header = False
                continue
            if token.startswith("#"):
                time = int(token[1:])
            elif token[0] in "01xXzZ":
                signal = by_symbol.get(token[1:])
                if signal is not None:
                    signal.record(time, token[0])
            elif token[0] in "bB":
                signal = by_symbol.get(fields[1])
                if signal is not None:
                    signal.record(time, token[1:])
    if header or ns_per_tick is None or not signals:
        raise ValueError(f"incomplete VCD or missing {TOP} scope in {path}")
    return Trace(signals, ns_per_tick, time)


def read_scenarios(path, trace):
    pattern = re.compile(r"^SCENARIO\s+(\w+)\s+t_ns=(\d+(?:\.\d+)?)\b", re.MULTILINE)
    markers = [
        (name, int(Fraction(ns) / trace.ns_per_tick))
        for name, ns in pattern.findall(path.read_text(encoding="utf-8"))
    ]
    if not markers:
        raise ValueError(f"no scenario markers in {path}")
    return {
        name: (time, next_time)
        for (name, time), (_, next_time) in zip(markers, markers[1:] + [("end", trace.end)])
    }


@dataclass
class Panel:
    title: str
    subtitle: str
    start: int
    stop: int
    rows: list
    markers: list = field(default_factory=list)


def rows(trace, bus, names, labels=None):
    labels = labels or [name.upper() for name in names]
    return [(label, trace.get(f"{bus}_{name}")) for name, label in zip(names, labels)]


def select_bit(signal, index):
    selected = Signal(1)
    for time, value in zip(signal.times, signal.values):
        pad = value[0] if value[0] in "xz" else "0"
        selected.record(time, value.rjust(signal.width, pad)[-1 - index])
    return selected


def wire_order_word(signal, samples):
    bits = "".join(signal.value(time, before=True) for time in samples)
    if len(bits) >= 16 and re.fullmatch("[01]+", bits):
        return f"0x{int(bits, 2):0{(len(bits) + 3) // 4}X}"
    return bits


def spi_panels(trace, scenarios):
    cs, sclk, mosi, miso = [trace.get(f"apb_{name}") for name in SPI]
    panels = []
    for mode in range(4):
        start, stop = scenarios[f"apb_mode{mode}"]
        inactive = (1 << cs.width) - 1
        active_start = None
        frames = []
        for time, _ in cs.changes(start, stop):
            level = cs.number(time)
            if level is None:
                continue
            cs_active = inactive ^ level
            if cs_active and active_start is None:
                active_start = time
                cs_index = cs_active.bit_length() - 1
            elif not cs_active and active_start is not None:
                edges = [edge for edge, _ in sclk.changes(active_start, time)]
                if edges and len(edges) % 2 == 0:
                    frames.append((active_start, time, cs_index, edges))
                active_start = None
        if not frames:
            raise ValueError(f"no complete SPI frame in apb_mode{mode}")
        begin, end, cs_index, edges = min(frames, key=lambda frame: abs(len(frame[3]) - 16))
        select = select_bit(cs, cs_index)
        polarity = sclk.number(begin)
        phase = mode & 1
        samples = edges[phase::2]
        leading_to_trailing = edges[1] - edges[0]
        window = (max(start, begin - leading_to_trailing), min(stop, end + leading_to_trailing))
        tx = wire_order_word(mosi, samples)
        rx = wire_order_word(miso, samples)
        marker_stride = 1 if len(samples) <= 12 else (len(samples) + 7) // 8
        markers = [(time, str(index + 1)) for index, time in enumerate(samples) if index % marker_stride == 0]
        if markers[-1][0] != samples[-1]:
            markers.append((samples[-1], str(len(samples))))
        unit = "bit" if len(samples) == 1 else "bits"
        panels.append(Panel(
            f"Mode {mode}   CPOL {polarity} / CPHA {phase}",
            f"{len(samples)} {unit} · MOSI {tx} · MISO {rx} · half-period {trace.time_ns(leading_to_trailing)} ns",
            *window,
            [(f"CS{cs_index}#", select), ("SCLK", sclk), ("MOSI", mosi), ("MISO", miso)],
            markers,
        ))
    return panels


def clock_signal(trace):
    return trace.get("clk", "clk_i", "clock")


def active_cycles(trace, window):
    return [time for time, value in clock_signal(trace).changes(*window) if value == "1"]


def sampled(trace, bus, name, time):
    return trace.get(f"{bus}_{name}").number(time, before=True)


def asserted(trace, bus, names, time):
    return all(sampled(trace, bus, name, time) == 1 for name in names)


def clipped_window(bounds, first, last, period, padding=(2, 2)):
    return max(bounds[0], first - padding[0] * period), min(bounds[1], last + padding[1] * period)


def apb_panels(trace, scenarios):
    window = scenarios["apb_register_access"]
    cycles = active_cycles(trace, window)
    period = cycles[1] - cycles[0]
    good = []
    errors = []
    for time in cycles:
        if asserted(trace, "apb", ["psel", "penable", "pready"], time):
            access = (time, *(sampled(trace, "apb", field, time) for field in ("paddr", "pwrite", "pstrb", "pslverr")))
            (errors if access[4] else good).append(access)
    masked = next((access for access in good if access[2] and 0 < access[3] < 15), None)
    if not masked or not errors:
        raise ValueError("APB scenario requires a successful byte-strobe write and a rejected transaction")
    error = next((access for access in errors if access[1] % 4), errors[0])
    error_title = "Rejected unaligned access" if error[1] % 4 else "Rejected access"
    panels = []
    for title, access in [("Byte-strobe write", masked), (error_title, error)]:
        time, address, write, strobes, failed = access
        operation = "Write" if write else "Read"
        subtitle = (
            f"{operation} at 0x{address:03X} · PSTRB 0x{strobes:X} · "
            f"PSLVERR {failed} at the accepting clock edge"
        )
        panels.append(Panel(
            title, subtitle, *clipped_window(window, time, time, period, (2, 1)),
            [("PCLK", clock_signal(trace))] + rows(trace, "apb", APB),
            [(time, "Transfer")],
        ))
    return panels


def channel_accepts(trace, channel, cycles):
    return [time for time in cycles if asserted(trace, "axi", [f"{channel}valid", f"{channel}ready"], time)]


def channel_stalled(trace, channel, cycles, begin, end):
    return any(
        sampled(trace, "axi", f"{channel}valid", time) == 1 and
        sampled(trace, "axi", f"{channel}ready", time) == 0
        for time in cycles if begin < time < end
    )


def axil_panels(trace, scenarios):
    window = scenarios["axi_channels"]
    cycles = active_cycles(trace, window)
    period = cycles[1] - cycles[0]
    aw, w, b, ar, r = [channel_accepts(trace, channel, cycles) for channel in ("aw", "w", "b", "ar", "r")]
    write = next((
        (aw_time, w_time, b_time) for aw_time, w_time, b_time in zip(aw, w, b)
        if aw_time < w_time and channel_stalled(trace, "b", cycles, w_time, b_time)
    ), None)
    read = next((
        (ar_time, r_time) for ar_time, r_time in zip(ar, r)
        if channel_stalled(trace, "r", cycles, ar_time, r_time)
    ), None)
    if not write or not read:
        raise ValueError("AXI scenario requires an AW-first write and a read with response backpressure")
    aw_time, w_time, b_time = write
    ar_time, r_time = read
    return [
        Panel(
            "Address-first write",
            f"AW is accepted {trace.time_ns(w_time - aw_time)} ns before W · BVALID holds the response until BREADY",
            *clipped_window(window, aw_time, b_time, period, (1, 1)),
            [("ACLK", clock_signal(trace))] + rows(trace, "axi", AXI_WRITE),
            list(zip(write, ["AW", "W", "B"])),
        ),
        Panel(
            "Read response backpressure",
            "RVALID, RDATA and RRESP are visible while RREADY is low",
            *clipped_window(window, ar_time, r_time, period, (1, 1)),
            [("ACLK", clock_signal(trace))] + rows(trace, "axi", AXI_READ),
            [(ar_time, "AR"), (r_time, "R")],
        ),
    ]


def fifo_panels(trace, scenarios):
    window = scenarios["apb_fifo_irq"]
    cycles = active_cycles(trace, window)
    period = cycles[1] - cycles[0]
    irq = trace.get("apb_irq")
    events = []
    clears = []
    for time in cycles:
        if not asserted(trace, "apb", ["psel", "penable", "pready", "pwrite"], time):
            continue
        address = sampled(trace, "apb", "paddr", time)
        if address == 0x10 and sampled(trace, "apb", "pslverr", time) == 1 and irq.number(time) == 1:
            events.append(time)
        if address == 0x1C and irq.number(time, before=True) == 1 and irq.number(time) == 0:
            clears.append(time)
    if not events or not clears:
        raise ValueError("FIFO scenario requires a TX overflow raising IRQ and a W1C write lowering IRQ")
    panels = []
    bus_rows = [("PCLK", clock_signal(trace))] + rows(trace, "apb", [
        "psel", "penable", "pwrite", "paddr", "pwdata", "pslverr", "irq"
    ])
    for title, subtitle, time in [
        ("TX FIFO overflow", "A rejected TXDATA write asserts PSLVERR and raises an enabled interrupt", events[0]),
        ("Interrupt acknowledge", "A write-one-to-clear access to IRQ_STATUS deasserts IRQ", clears[0]),
    ]:
        panels.append(Panel(
            title, subtitle, *clipped_window(window, time, time, period, (2, 2)),
            bus_rows + [("TX_LEVEL", trace.get("core_tx_level"))], [(time, "Transfer")],
        ))

    window = scenarios["apb_rx_full_pop"]
    receive = next((time for time in active_cycles(trace, window) if
        all(trace.get(f"core_{name}").number(time, before=True) == 1 for name in ("spi_done", "rx_push", "rx_pop"))
    ), None)
    if receive is None:
        raise ValueError("RX scenario requires a concurrent FIFO insertion and APB pop")
    rx_level = trace.get("core_rx_level")
    before = rx_level.number(receive, before=True)
    after = rx_level.number(receive)
    data = sampled(trace, "apb", "prdata", receive)
    panels.append(Panel(
        "Concurrent RX replacement",
        f"RXDATA returns oldest word 0x{data:08X} as SPI completion queues a new word · RX level {before} → {after}",
        *clipped_window(window, receive, receive, period, (2, 2)),
        [("PCLK", clock_signal(trace))] + rows(trace, "apb", ["psel", "penable", "paddr", "prdata"])
        + rows(trace, "core", ["spi_done", "rx_pop", "rx_push", "rx_level"]), [(receive, "Transfer")],
    ))
    return panels


def svg_text(x, y, text, role, anchor="start"):
    return f'<text x="{x:.2f}" y="{y:.2f}" class="{role}" text-anchor="{anchor}">{escape(text)}</text>'


def svg_line(x1, y1, x2, y2, role):
    return f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" class="{role}"/>'


def time_ticks(panel, target_count):
    interval = (panel.stop - panel.start) / target_count
    scale = 10 ** floor(log10(interval))
    step = round(min((scale * factor for factor in (1, 2, 2.5, 5, 10)), key=lambda grid: abs(grid - interval)))
    step = max(1, step)
    first = ((panel.start + step - 1) // step) * step
    return range(first, panel.stop + 1, step)


def draw_signal(signal, panel, x_at, y):
    initial = signal.value(panel.start)
    changes = list(signal.changes(panel.start, panel.stop))
    if signal.width == 1:
        levels = {"0": y + 8, "1": y - 8}
        x = x_at(panel.start)
        value = initial
        elements = []
        for time, new_value in changes + [(panel.stop, value)]:
            end = x_at(time)
            level = levels.get(value, y)
            role = "digital" if value in levels else "undefined"
            elements.append(svg_line(x, level, end, level, role))
            if time != panel.stop:
                elements.append(svg_line(end, level, end, levels.get(new_value, y), "digital"))
            x, value = end, new_value
        return elements
    elements = []
    for (time, value), (end, _) in zip([(panel.start, initial)] + changes, changes + [(panel.stop, "")]):
        left, right = x_at(time), x_at(end)
        bevel = min(3, (right - left) / 3)
        points = [(left, y), (left + bevel, y - 8), (right - bevel, y - 8), (right, y),
                  (right - bevel, y + 8), (left + bevel, y + 8)]
        coordinates = " ".join(f"{px:.2f},{py:.2f}" for px, py in points)
        elements.append(f'<polygon points="{coordinates}" class="bus"/>')
        label = f"{int(value, 2):0{(signal.width + 3) // 4}X}" if re.fullmatch("[01]+", value) else value
        if right - left >= 8 * len(label) + 8:
            elements.append(svg_text((left + right) / 2, y + 4, label, "value", "middle"))
    return elements


CSS = """
text { font-family: system-ui, sans-serif; fill: #17273b; }
.canvas { fill: #fff; }
.panel { fill: #f7f9fc; stroke: #d7e1ec; }
.title { font-size: 30px; font-weight: 650; }
.source { font-size: 14px; fill: #465b71; }
.panel-title { font-size: 19px; font-weight: 650; }
.subtitle { font-size: 13px; fill: #40576f; }
.signal, .value, .tick, .annotation { font-family: ui-monospace, monospace; }
.signal { font-size: 13px; font-weight: 600; }
.value, .tick, .annotation { font-size: 11px; }
.tick { fill: #465b71; }
.annotation { fill: #985117; font-weight: 650; }
.grid { stroke: #dce4ef; stroke-width: 1; }
.digital { stroke: #164974; stroke-width: 1.8; }
.undefined { stroke: #647789; stroke-width: 1.5; stroke-dasharray: 3 3; }
.bus { fill: #e8f1fb; stroke: #537798; stroke-width: 1; }
.marker { stroke: #ab6b36; stroke-width: 1; stroke-dasharray: 4 3; }
"""


def draw_document(path, title, subtitle, trace, panels, columns=1):
    width = 1140
    outer, gap = 22, 16
    panel_width = (width - 2 * outer - (columns - 1) * gap) / columns
    row_height = 28
    header = 100
    panel_heights = [118 + row_height * len(panel.rows) for panel in panels]
    row_heights = [max(panel_heights[index:index + columns]) for index in range(0, len(panels), columns)]
    height = header + sum(row_heights) + len(row_heights) * gap
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img">',
        f"<title>{escape(title)}</title>",
        f"<desc>{escape(subtitle)}. Values and timing are derived from the directed simulation VCD.</desc>",
        f"<style>{CSS}</style>",
        '<rect width="100%" height="100%" class="canvas"/>',
        svg_text(outer, 43, title, "title"),
        svg_text(outer, 70, subtitle, "source"),
    ]
    for index, panel in enumerate(panels):
        vertical_index, column = divmod(index, columns)
        x = outer + column * (panel_width + gap)
        y = header + sum(row_heights[:vertical_index]) + vertical_index * gap
        plot_x = x + (91 if columns == 1 else 67)
        plot_right = x + panel_width - 26
        plot_top = y + 68
        plot_bottom = plot_top + len(panel.rows) * row_height
        marker_y = plot_top - 7

        def x_at(time):
            return plot_x + (time - panel.start) / (panel.stop - panel.start) * (plot_right - plot_x)

        svg += [
            f'<rect x="{x:.2f}" y="{y}" width="{panel_width:.2f}" '
            f'height="{panel_heights[index]}" rx="7" class="panel"/>',
            svg_text(x + 15, y + 26, panel.title, "panel-title"),
            svg_text(x + 15, y + 46, panel.subtitle, "subtitle"),
        ]
        for time in time_ticks(panel, 4 if columns == 2 else 8):
            tick_x = x_at(time)
            svg.append(svg_line(tick_x, plot_top, tick_x, plot_bottom, "grid"))
            svg.append(svg_text(tick_x, plot_bottom + 16, trace.time_ns(time), "tick", "middle"))
        svg.append(svg_text(plot_right, plot_bottom + 33, "Simulation time (ns)", "tick", "end"))
        for time, label in panel.markers:
            marker_x = x_at(time)
            svg.append(svg_line(marker_x, plot_top, marker_x, plot_bottom, "marker"))
            svg.append(svg_text(marker_x, marker_y, label, "annotation", "middle"))
        for row, (name, signal) in enumerate(panel.rows):
            signal_y = plot_top + (row + 0.5) * row_height
            svg.append(svg_text(plot_x - 10, signal_y + 4, name, "signal", "end"))
            svg += draw_signal(signal, panel, x_at, signal_y)
    svg.append("</svg>")
    path.write_text("\n".join(svg) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vcd", type=Path, help="VCD from tb_regipulse")
    parser.add_argument("log", type=Path, help="simulation stdout containing scenario markers")
    parser.add_argument("--output-dir", type=Path, default=Path("build/waveforms"))
    args = parser.parse_args()
    try:
        trace = read_vcd(args.vcd)
        scenarios = read_scenarios(args.log, trace)
        hex_vectors = "Directed simulation VCD · bus vectors are hexadecimal"
        documents = [
            (
                "spi-modes.svg", "SPI clock modes",
                "Directed simulation VCD · numbered guides mark sample edges · data shown in wire order",
                spi_panels(trace, scenarios), 2,
            ),
            ("apb-access.svg", "APB register accesses", hex_vectors, apb_panels(trace, scenarios), 1),
            (
                "axil-handshake.svg", "AXI4-Lite handshakes",
                "Directed simulation VCD · guides mark valid/ready handshakes",
                axil_panels(trace, scenarios), 1,
            ),
            ("fifo-interrupt.svg", "FIFO boundaries and interrupt handling", hex_vectors, fifo_panels(trace, scenarios), 1),
        ]
        args.output_dir.mkdir(parents=True, exist_ok=True)
        for filename, title, subtitle, panels, columns in documents:
            output = args.output_dir / filename
            draw_document(output, title, subtitle, trace, panels, columns)
            print(output)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"{parser.prog}: {error}\n")


if __name__ == "__main__":
    main()
