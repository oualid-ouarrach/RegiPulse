SHELL := /bin/bash
.DEFAULT_GOAL := check

VERILATOR ?= verilator
IVERILOG ?= iverilog
VVP ?= vvp
YOSYS ?= yosys
PYTHON ?= python3
BUILD_DIR ?= build
JOBS ?= 2

COMPONENT_RTL := rtl/rp_fifo.sv rtl/rp_spi_engine.sv
RTL_SOURCES := $(COMPONENT_RTL) rtl/rp_irq.sv rtl/regipulse_core.sv \
               rtl/rp_apb_bridge.sv rtl/rp_axil_bridge.sv \
               rtl/regipulse_apb.sv rtl/regipulse_axil.sv
ASSERTIONS := assertions/regipulse_properties.sv
COMPONENT_TB := tests/tb_components.sv
DIRECTED_TB := tests/tb_regipulse.sv
VERILATOR_TB_FLAGS := --binary --timing --assert -Wno-TIMESCALEMOD -j $(JOBS)

.PHONY: check lint test test-components test-directed test-iverilog structural waves uvm clean

check: lint test

lint:
	$(VERILATOR) --lint-only -Wall --top-module regipulse_apb $(RTL_SOURCES)
	$(VERILATOR) --lint-only -Wall --top-module regipulse_axil $(RTL_SOURCES)

$(BUILD_DIR):
	mkdir -p "$@"

$(BUILD_DIR)/components/Vtb_components: $(COMPONENT_RTL) $(COMPONENT_TB) Makefile | $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_TB_FLAGS) --top-module tb_components \
		--Mdir "$(BUILD_DIR)/components" $(COMPONENT_RTL) $(COMPONENT_TB)

$(BUILD_DIR)/directed/Vtb_regipulse: $(RTL_SOURCES) $(ASSERTIONS) $(DIRECTED_TB) Makefile | $(BUILD_DIR)
	$(VERILATOR) $(VERILATOR_TB_FLAGS) --trace-vcd --top-module tb_regipulse \
		--Mdir "$(BUILD_DIR)/directed" $(RTL_SOURCES) $(ASSERTIONS) $(DIRECTED_TB)

test: test-components test-directed

test-components: $(BUILD_DIR)/components/Vtb_components
	@set -o pipefail; "$<" | tee "$(BUILD_DIR)/components.log"

test-directed: $(BUILD_DIR)/directed/Vtb_regipulse
	@set -o pipefail; "$<" +vcd="$(BUILD_DIR)/regipulse.vcd" | tee "$(BUILD_DIR)/regipulse.log"

$(BUILD_DIR)/components.vvp: $(COMPONENT_RTL) $(COMPONENT_TB) Makefile | $(BUILD_DIR)
	$(IVERILOG) -g2012 -s tb_components -o "$@" $(COMPONENT_RTL) $(COMPONENT_TB)

$(BUILD_DIR)/directed.vvp: $(RTL_SOURCES) $(DIRECTED_TB) Makefile | $(BUILD_DIR)
	$(IVERILOG) -g2012 -s tb_regipulse -o "$@" $(RTL_SOURCES) $(DIRECTED_TB)

test-iverilog: $(BUILD_DIR)/components.vvp $(BUILD_DIR)/directed.vvp
	@set -o pipefail; $(VVP) "$(BUILD_DIR)/components.vvp" | tee "$(BUILD_DIR)/components-iverilog.log"
	@set -o pipefail; $(VVP) "$(BUILD_DIR)/directed.vvp" | tee "$(BUILD_DIR)/regipulse-iverilog.log"

structural: | $(BUILD_DIR)
	$(YOSYS) -Q -T -l "$(BUILD_DIR)/apb-structural.log" -p \
		'read_verilog -sv $(RTL_SOURCES); hierarchy -check -top regipulse_apb; proc; opt; check -assert; stat'
	$(YOSYS) -Q -T -l "$(BUILD_DIR)/axil-structural.log" -p \
		'read_verilog -sv $(RTL_SOURCES); hierarchy -check -top regipulse_axil; proc; opt; check -assert; stat'

waves: test-directed
	$(PYTHON) scripts/render_waveforms.py "$(BUILD_DIR)/regipulse.vcd" \
		"$(BUILD_DIR)/regipulse.log" --output-dir "$(BUILD_DIR)/waves"

uvm:
	VERILATOR="$(VERILATOR)" BUILD_DIR="$(abspath $(BUILD_DIR))/uvm" \
		UVM_JOBS="$(JOBS)" ./scripts/run_uvm.sh $(RTL_SOURCES)

clean:
	rm -rf "$(BUILD_DIR)"
