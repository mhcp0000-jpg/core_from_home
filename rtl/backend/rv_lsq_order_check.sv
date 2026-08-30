module rv_lsq_order_check #(
  parameter int unsigned PADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH  = 64,
  parameter int unsigned SQ_ENTRIES  = 16,
  parameter int unsigned AGE_WIDTH   = 6,
  localparam int unsigned SQ_INDEX_WIDTH = $clog2(SQ_ENTRIES + 1)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,
  input  logic                                  load_valid_i,
  input  logic [PADDR_WIDTH-1:0]                load_addr_i,
  input  logic [DATA_WIDTH/8-1:0]               load_mask_i,

  input  logic [SQ_ENTRIES-1:0]                 sq_valid_i,
  input  logic [SQ_ENTRIES-1:0]                 sq_older_than_load_i,
  input  logic [SQ_ENTRIES-1:0]                 sq_addr_valid_i,
  input  logic [SQ_ENTRIES-1:0]                 sq_data_valid_i,
  input  logic [SQ_ENTRIES-1:0][AGE_WIDTH-1:0]  sq_age_i,
  input  logic [SQ_ENTRIES-1:0][PADDR_WIDTH-1:0] sq_addr_i,
  input  logic [SQ_ENTRIES-1:0][DATA_WIDTH/8-1:0] sq_mask_i,
  input  logic [SQ_ENTRIES-1:0][DATA_WIDTH-1:0] sq_data_i,

  // Same-cycle lane0-store to lane1-load bypass. This store is younger than
  // every SQ entry already present and therefore wins a full-cover match.
  input  logic                                  pair_store_valid_i,
  input  logic                                  pair_store_addr_valid_i,
  input  logic                                  pair_store_data_valid_i,
  input  logic [PADDR_WIDTH-1:0]                pair_store_addr_i,
  input  logic [DATA_WIDTH/8-1:0]               pair_store_mask_i,
  input  logic [DATA_WIDTH-1:0]                 pair_store_data_i,

  output logic                                  load_can_issue_o,
  output logic                                  memory_read_o,
  output logic                                  forward_valid_o,
  output logic [DATA_WIDTH-1:0]                 forward_data_o,
  output logic [SQ_INDEX_WIDTH-1:0]             forward_sq_index_o,
  output rv_ooo_pkg::lsq_stall_reason_e         stall_reason_o
);

  import rv_ooo_pkg::*;

  logic any_unknown_addr;
  logic any_partial_overlap;
  logic match_found;
  logic match_data_valid;
  logic [AGE_WIDTH-1:0] youngest_age;
  logic [DATA_WIDTH/8-1:0] overlap_mask;

  // sq_age_i uses distance from store to load: 1 is the youngest older store,
  // and larger values are progressively older. The ROB/LSQ owner computes it
  // with wrap-aware sequence arithmetic.

  always_comb begin
    any_unknown_addr    = 1'b0;
    any_partial_overlap = 1'b0;
    match_found         = 1'b0;
    match_data_valid    = 1'b0;
    youngest_age        = '1;
    forward_data_o      = '0;
    forward_sq_index_o  = '0;

    for (int unsigned entry = 0; entry < SQ_ENTRIES; entry++) begin
      if (sq_valid_i[entry] && sq_older_than_load_i[entry]) begin
        if (!sq_addr_valid_i[entry]) begin
          any_unknown_addr = 1'b1;
        end else if (sq_addr_i[entry][PADDR_WIDTH-1:3] ==
                     load_addr_i[PADDR_WIDTH-1:3]) begin
          overlap_mask = sq_mask_i[entry] & load_mask_i;
          if ((overlap_mask != '0) && (overlap_mask != load_mask_i)) begin
            any_partial_overlap = 1'b1;
          end else if ((overlap_mask == load_mask_i) &&
                       (!match_found || (sq_age_i[entry] < youngest_age))) begin
            match_found        = 1'b1;
            match_data_valid   = sq_data_valid_i[entry];
            youngest_age       = sq_age_i[entry];
            forward_data_o     = sq_data_i[entry];
            forward_sq_index_o = SQ_INDEX_WIDTH'(entry);
          end
        end
      end
    end

    if (pair_store_valid_i) begin
      if (!pair_store_addr_valid_i) begin
        any_unknown_addr = 1'b1;
      end else if (pair_store_addr_i[PADDR_WIDTH-1:3] ==
                   load_addr_i[PADDR_WIDTH-1:3]) begin
        overlap_mask = pair_store_mask_i & load_mask_i;
        if ((overlap_mask != '0) && (overlap_mask != load_mask_i)) begin
          any_partial_overlap = 1'b1;
        end else if (overlap_mask == load_mask_i) begin
          match_found         = 1'b1;
          match_data_valid    = pair_store_data_valid_i;
          youngest_age        = '0;
          forward_data_o      = pair_store_data_i;
          forward_sq_index_o  = SQ_INDEX_WIDTH'(SQ_ENTRIES);
        end
      end
    end

    load_can_issue_o = 1'b0;
    memory_read_o    = 1'b0;
    forward_valid_o  = 1'b0;
    stall_reason_o   = LSQ_STALL_NONE;

    if (load_valid_i) begin
      if (any_unknown_addr) begin
        stall_reason_o = LSQ_STALL_UNKNOWN_ADDR;
      end else if (any_partial_overlap) begin
        stall_reason_o = LSQ_STALL_PARTIAL_OVERLAP;
      end else if (match_found && !match_data_valid) begin
        stall_reason_o = LSQ_STALL_STORE_DATA;
      end else begin
        load_can_issue_o = 1'b1;
        forward_valid_o  = match_found;
        memory_read_o    = !match_found;
      end
    end
  end

`ifndef SYNTHESIS
  property p_unknown_store_blocks_load;
    @(posedge clk_i) disable iff (!rst_ni)
      load_valid_i && (stall_reason_o == LSQ_STALL_UNKNOWN_ADDR)
      |-> !load_can_issue_o && !memory_read_o;
  endproperty
  assert property (p_unknown_store_blocks_load);

  property p_forward_and_memory_are_exclusive;
    @(posedge clk_i) disable iff (!rst_ni)
      load_valid_i |-> !(forward_valid_o && memory_read_o);
  endproperty
  assert property (p_forward_and_memory_are_exclusive);

  property p_no_memory_read_while_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      load_valid_i && (stall_reason_o != LSQ_STALL_NONE)
      |-> !memory_read_o;
  endproperty
  assert property (p_no_memory_read_while_stalled);
`endif

endmodule
