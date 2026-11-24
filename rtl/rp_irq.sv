module rp_irq #(
  parameter integer WIDTH = 8
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [WIDTH-1:0] events_i,
  input  logic [WIDTH-1:0] clear_i,
  input  logic             enable_write_i,
  input  logic [WIDTH-1:0] enable_data_i,
  output logic [WIDTH-1:0] status_o,
  output logic [WIDTH-1:0] enable_o,
  output logic             irq_o
);

  assign irq_o = |(status_o & enable_o);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      status_o <= '0;
      enable_o <= '0;
    end else begin
      // An event arriving with a W1C write remains pending.
      status_o <= (status_o & ~clear_i) | events_i;
      if (enable_write_i) begin
        enable_o <= enable_data_i;
      end
    end
  end

endmodule
