module rv_pmp_tb;
  import rv_ooo_pkg::*;

  localparam int unsigned PADDR_WIDTH = 32;
  localparam int unsigned PMP_ENTRIES = 8;
  localparam int unsigned PORTS = 2;

  logic [PMP_ENTRIES-1:0][7:0] pmpcfg;
  logic [PMP_ENTRIES-1:0][PADDR_WIDTH-3:0] pmpaddr;
  logic [PORTS-1:0] valid;
  logic [PORTS-1:0][PADDR_WIDTH-1:0] address;
  logic [PORTS-1:0][2:0] size;
  logic [PORTS-1:0][2:0] access;
  privilege_e [PORTS-1:0] privilege;
  logic [PORTS-1:0] allow;
  logic [PORTS-1:0] matched;
  logic [PORTS-1:0][PADDR_WIDTH-1:0] fault_address;

  rv_pmp #(
    .PADDR_WIDTH(PADDR_WIDTH), .PMP_ENTRIES(PMP_ENTRIES),
    .CHECK_PORTS(PORTS)
  ) u_dut (
    .pmpcfg_i(pmpcfg), .pmpaddr_i(pmpaddr), .check_valid_i(valid),
    .check_address_i(address), .check_size_i(size),
    .check_access_i(access), .check_privilege_i(privilege),
    .allow_o(allow), .matched_o(matched),
    .fault_address_o(fault_address)
  );

  task automatic expect_port(
    input int unsigned port,
    input logic expected_allow,
    input logic expected_matched,
    input string message
  );
    #1;
    if ((allow[port] !== expected_allow) ||
        (matched[port] !== expected_matched))
      $fatal(1, "%s: allow=%0b matched=%0b", message,
             allow[port], matched[port]);
  endtask

  initial begin
    pmpcfg = '0;
    pmpaddr = '0;
    valid = 2'b11;
    address[0] = 32'h0000_1000;
    address[1] = 32'h0000_1000;
    size[0] = 3'd2;
    size[1] = 3'd2;
    access[0] = 3'b001;
    access[1] = 3'b001;
    privilege[0] = PRIV_U;
    privilege[1] = PRIV_M;
    expect_port(0, 1'b0, 1'b0, "U-mode requires a matching PMP entry");
    expect_port(1, 1'b1, 1'b0, "M-mode bypasses an empty PMP table");

    // Entry 0: 4-byte NA4 at 0x1000, read-only and unlocked.
    pmpaddr[0] = 30'(32'h0000_1000 >> 2);
    pmpcfg[0] = 8'b0001_0001; // A=NA4, R=1
    privilege[0] = PRIV_U;
    privilege[1] = PRIV_U;
    access[0] = 3'b001;
    access[1] = 3'b010;
    expect_port(0, 1'b1, 1'b1, "NA4 U-mode read");
    expect_port(1, 1'b0, 1'b1, "NA4 U-mode write permission");

    size[0] = 3'd3;
    expect_port(0, 1'b0, 1'b1, "Partial overlap must fail at first entry");
    size[0] = 3'd2;
    privilege[0] = PRIV_M;
    access[0] = 3'b010;
    expect_port(0, 1'b1, 1'b1, "Unlocked entry does not constrain M-mode");
    pmpcfg[0][7] = 1'b1;
    expect_port(0, 1'b0, 1'b1, "Locked entry constrains M-mode");

    // Entry 1 TOR: [0x2000, 0x3000), execute-only. Entry 0 supplies
    // the lower bound while remaining OFF.
    pmpcfg = '0;
    pmpaddr = '0;
    pmpaddr[0] = 30'(32'h0000_2000 >> 2);
    pmpaddr[1] = 30'(32'h0000_3000 >> 2);
    pmpcfg[1] = 8'b0000_1100; // A=TOR, X=1
    address[0] = 32'h0000_2800;
    address[1] = 32'h0000_2800;
    size[0] = 3'd1;
    size[1] = 3'd1;
    access[0] = 3'b100;
    access[1] = 3'b001;
    privilege[0] = PRIV_U;
    privilege[1] = PRIV_U;
    expect_port(0, 1'b1, 1'b1, "TOR execute permission");
    expect_port(1, 1'b0, 1'b1, "TOR read permission");

    // Entry 0 partially covers an 8-byte access. It must win over a later
    // 16-byte NAPOT entry that would otherwise cover the complete access.
    pmpcfg = '0;
    pmpaddr = '0;
    pmpaddr[0] = 30'(32'h0000_4000 >> 2);
    pmpcfg[0] = 8'b0001_0001; // NA4, R
    pmpaddr[1] = 30'((32'h0000_4000 >> 2) | 1); // 16-byte NAPOT
    pmpcfg[1] = 8'b0001_1111; // NAPOT, RWX
    address[0] = 32'h0000_4000;
    size[0] = 3'd3;
    access[0] = 3'b001;
    privilege[0] = PRIV_U;
    expect_port(0, 1'b0, 1'b1, "Lowest-index partial match has priority");

    // A standalone 16-byte NAPOT region supports contained accesses and
    // rejects an access that crosses its upper boundary.
    pmpcfg = '0;
    pmpaddr = '0;
    pmpaddr[0] = 30'((32'h0000_5000 >> 2) | 1);
    pmpcfg[0] = 8'b0001_1011; // NAPOT, RW
    address[0] = 32'h0000_5000;
    address[1] = 32'h0000_5008;
    size[0] = 3'd4;
    size[1] = 3'd4;
    access[0] = 3'b010;
    access[1] = 3'b001;
    privilege[0] = PRIV_U;
    privilege[1] = PRIV_U;
    expect_port(0, 1'b1, 1'b1, "Complete NAPOT access");
    expect_port(1, 1'b0, 1'b1, "NAPOT boundary crossing");

    valid[1] = 1'b0;
    expect_port(1, 1'b1, 1'b0, "Inactive lookup is benign");
    if (fault_address[0] != address[0])
      $fatal(1, "PMP fault address must preserve the request address");

    $display("rv_pmp_tb PASS");
    $finish;
  end
endmodule
