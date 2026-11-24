# RegiPulse engineering instructions

- Keep the common register behavior independent of APB4 and AXI4-Lite. Preserve
  software compatibility for existing offsets and field encodings unless a
  change explicitly revises the interface.
- Keep synthesizable SystemVerilog in `rtl/`. Use active-low synchronous reset
  for sequential behavior, one rising-edge peripheral clock, and `_i`, `_o`
  and `_q` signal suffixes. Keep testbench timing and simulation-only constructs
  out of the design sources.
- Treat `docs/specification.md` and `docs/register-map.md` as the behavior
  contract. When an observable behavior changes, update the contract, its
  self-checking scenario and the traceability matrix together.
- Run `make check` for RTL changes. Run `make uvm` when modifying the UVM
  bench or its build. Use `make waves` to regenerate trace evidence after
  changing the corresponding scenarios.
- Use free tools, pin dependencies used by the automated builds, and record
  versions with measured results. Keep generated build outputs and dependency
  checkouts out of Git. Commit curated, reproducible evidence only when it
  illustrates an observed result.
- Keep commits focused and verify each feature branch before publication.
  Preserve existing history. Keep benchmark results, proof assumptions and
  scope limits explicit in the milestone tracker and related report.
- Keep documentation in English. Include only project-relevant technical
  material in public commits and remove credentials and machine-specific paths
  from published traces and reports. Follow the license terms of all inputs.
