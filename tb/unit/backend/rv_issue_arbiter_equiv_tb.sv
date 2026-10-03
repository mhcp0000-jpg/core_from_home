module rv_issue_arbiter_equiv_tb #(
  parameter int unsigned ExecPorts = 5,
  localparam int unsigned PortWidth = $clog2(ExecPorts),
  localparam int unsigned MaskCount = 1 << ExecPorts
);
  logic [1:0] valid;
  logic [1:0][7:0] sequence_id;
  logic [1:0][ExecPorts-1:0] mask;
  logic [ExecPorts-1:0] ready;
  typedef struct packed {
    logic [1:0] grant;
    logic [1:0][PortWidth-1:0] candidate_port;
    logic [ExecPorts-1:0] port_valid;
    logic [ExecPorts-1:0] port_candidate;
    logic [1:0] issue_valid;
    logic [1:0] issue_candidate;
    logic [1:0][PortWidth-1:0] issue_port;
  } result_t;
  result_t result [0:1];
  for (genvar version = 0; version < 2; version++) begin : g_version
    rv_issue_arbiter #(.CANDIDATE_COUNT(2), .EXEC_PORTS(ExecPorts), .ISSUE_WIDTH(2),
      .ROB_SEQ_WIDTH(8), .AGE_ORDERED(version == 1)) u_dut (
      .candidate_valid_i(valid), .candidate_sequence_i(sequence_id),
      .candidate_port_mask_i(mask), .port_ready_i(ready),
      .candidate_grant_o(result[version].grant),
      .candidate_port_o(result[version].candidate_port),
      .port_valid_o(result[version].port_valid),
      .port_candidate_o(result[version].port_candidate),
      .issue_valid_o(result[version].issue_valid),
      .issue_candidate_o(result[version].issue_candidate),
      .issue_port_o(result[version].issue_port));
  end
  initial begin
    if (ExecPorts < 2 || ExecPorts > 6)
      $fatal(1, "Exhaustive test supports 2..6 execution ports");
    valid = '0; mask = '0; ready = '0; sequence_id = '0;
    // All validity/mask/readiness combinations, both straight and wrapped age.
    for (int wrap = 0; wrap < 2; wrap++) begin
      sequence_id[0] = (wrap != 0) ? 8'hff : 8'd42;
      sequence_id[1] = (wrap != 0) ? 8'h00 : 8'd43;
      for (int v = 0; v < 4; v++)
        for (int m0 = 0; m0 < MaskCount; m0++)
          for (int m1 = 0; m1 < MaskCount; m1++)
            for (int r = 0; r < MaskCount; r++) begin
              valid = 2'(v); mask[0] = ExecPorts'(m0);
              mask[1] = ExecPorts'(m1); ready = ExecPorts'(r);
              #1;
              if (result[0] !== result[1])
                $fatal(1, "Issue arbiter mismatch wrap=%0d valid=%b masks=%h ready=%h", wrap, valid, mask, ready);
            end
    end
    $display("Issue arbiter parallel fast path vs generic PASS ports=%0d (%0d exhaustive cases)",
             ExecPorts, 8 * MaskCount * MaskCount * MaskCount);
    $finish;
  end
endmodule
