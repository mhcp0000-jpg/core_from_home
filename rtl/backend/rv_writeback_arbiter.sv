module rv_writeback_arbiter #(
  parameter int unsigned XLEN               = 32,
  parameter int unsigned SOURCE_COUNT       = 8,
  parameter int unsigned PHYS_TAG_WIDTH     = 7,
  parameter int unsigned ROB_SEQ_WIDTH      = rv_ooo_pkg::ROB_SEQ_WIDTH,
  parameter int unsigned INT_WRITE_PORTS    = 2,
  parameter int unsigned FP_WRITE_PORTS     = 2,
  parameter int unsigned ROB_COMPLETE_PORTS = 4
) (
  input  logic [SOURCE_COUNT-1:0]                       source_valid_i,
  output logic [SOURCE_COUNT-1:0]                       source_ready_o,
  input  logic [SOURCE_COUNT-1:0]                       source_live_i,
  input  logic [SOURCE_COUNT-1:0][ROB_SEQ_WIDTH-1:0]    source_sequence_i,
  input  logic [SOURCE_COUNT-1:0]                       source_destination_valid_i,
  input  rv_ooo_pkg::reg_class_e [SOURCE_COUNT-1:0]     source_destination_class_i,
  input  logic [SOURCE_COUNT-1:0][PHYS_TAG_WIDTH-1:0]   source_destination_phys_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_data_i,
  input  logic [SOURCE_COUNT-1:0]                       source_exception_valid_i,
  input  rv_ooo_pkg::exception_code_e [SOURCE_COUNT-1:0]
                                                          source_exception_cause_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_exception_tval_i,
  input  logic [SOURCE_COUNT-1:0]                       source_branch_mispredict_i,
  input  logic [SOURCE_COUNT-1:0][XLEN-1:0]             source_branch_target_i,
  input  logic [SOURCE_COUNT-1:0][4:0]                  source_fflags_i,

  input  logic                                           flush_valid_i,
  input  logic                                           flush_all_i,
  input  logic [ROB_SEQ_WIDTH-1:0]                      flush_sequence_i,

  output logic [INT_WRITE_PORTS-1:0]                    int_wb_valid_o,
  output logic [INT_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0]int_wb_phys_o,
  output logic [INT_WRITE_PORTS-1:0][XLEN-1:0]          int_wb_data_o,
  output logic [FP_WRITE_PORTS-1:0]                     fp_wb_valid_o,
  output logic [FP_WRITE_PORTS-1:0][PHYS_TAG_WIDTH-1:0] fp_wb_phys_o,
  output logic [FP_WRITE_PORTS-1:0][31:0]               fp_wb_data_o,

  output logic [ROB_COMPLETE_PORTS-1:0]                 wakeup_valid_o,
  output rv_ooo_pkg::reg_class_e [ROB_COMPLETE_PORTS-1:0]
                                                          wakeup_class_o,
  output logic [ROB_COMPLETE_PORTS-1:0][PHYS_TAG_WIDTH-1:0]
                                                          wakeup_phys_o,

  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_valid_o,
  output logic [ROB_COMPLETE_PORTS-1:0][ROB_SEQ_WIDTH-1:0]
                                                          complete_sequence_o,
  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_exception_valid_o,
  output rv_ooo_pkg::exception_code_e [ROB_COMPLETE_PORTS-1:0]
                                                          complete_exception_cause_o,
  output logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0]       complete_exception_tval_o,
  output logic [ROB_COMPLETE_PORTS-1:0]                 complete_branch_mispredict_o,
  output logic [ROB_COMPLETE_PORTS-1:0][XLEN-1:0]       complete_branch_target_o,
  output logic [ROB_COMPLETE_PORTS-1:0][4:0]            complete_fflags_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned SOURCE_INDEX_WIDTH = $clog2(SOURCE_COUNT);
  function automatic logic sequence_before(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance < 0;
  endfunction

  function automatic logic sequence_after(
    input logic [ROB_SEQ_WIDTH-1:0] lhs,
    input logic [ROB_SEQ_WIDTH-1:0] rhs
  );
    logic signed [ROB_SEQ_WIDTH-1:0] distance;
    distance = $signed(lhs - rhs);
    return distance > 0;
  endfunction

  always_comb begin
    logic [SOURCE_COUNT-1:0] eligible_work;
    logic [SOURCE_COUNT-1:0] selected_work;
    logic [ROB_COMPLETE_PORTS-1:0] select_found_work;
    logic [ROB_COMPLETE_PORTS-1:0][SOURCE_INDEX_WIDTH-1:0]
      select_index_work;
    integer unsigned int_ports_used_work;
    integer unsigned fp_ports_used_work;

    source_ready_o = '0;
    eligible_work = '0;
    for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
      if (source_valid_i[source] &&
          (!source_live_i[source] ||
           (flush_valid_i &&
            (flush_all_i || sequence_after(source_sequence_i[source],
                                           flush_sequence_i))))) begin
        source_ready_o[source] = 1'b1;
      end else begin
        eligible_work[source] =
          source_valid_i[source] && source_live_i[source];
      end
    end

    selected_work = '0;
    select_found_work = '0;
    select_index_work = '0;
    int_ports_used_work = 0;
    fp_ports_used_work = 0;

    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      for (int unsigned source = 0; source < SOURCE_COUNT; source++) begin
        logic needs_int_port;
        logic needs_fp_port;
        logic resource_available;
        needs_int_port = source_destination_valid_i[source] &&
                         !source_exception_valid_i[source] &&
                         (source_destination_class_i[source] == REG_INT);
        needs_fp_port = source_destination_valid_i[source] &&
                        !source_exception_valid_i[source] &&
                        (source_destination_class_i[source] == REG_FP);
        resource_available =
          (!needs_int_port ||
           (int_ports_used_work < INT_WRITE_PORTS)) &&
          (!needs_fp_port || (fp_ports_used_work < FP_WRITE_PORTS));

        if (eligible_work[source] && !selected_work[source] &&
            resource_available &&
            (!select_found_work[slot] ||
             sequence_before(source_sequence_i[source],
                             source_sequence_i[select_index_work[slot]]))) begin
          select_found_work[slot] = 1'b1;
          select_index_work[slot] = SOURCE_INDEX_WIDTH'(source);
        end
      end

      if (select_found_work[slot]) begin
        selected_work[select_index_work[slot]] = 1'b1;
        if (source_destination_valid_i[select_index_work[slot]] &&
            !source_exception_valid_i[select_index_work[slot]]) begin
          if (source_destination_class_i[select_index_work[slot]] == REG_INT)
            int_ports_used_work = int_ports_used_work + 1;
          else if (source_destination_class_i[select_index_work[slot]] == REG_FP)
            fp_ports_used_work = fp_ports_used_work + 1;
        end
      end
    end

    int_wb_valid_o = '0;
    int_wb_phys_o = '0;
    int_wb_data_o = '0;
    fp_wb_valid_o = '0;
    fp_wb_phys_o = '0;
    fp_wb_data_o = '0;
    wakeup_valid_o = '0;
    wakeup_phys_o = '0;
    complete_valid_o = '0;
    complete_sequence_o = '0;
    complete_exception_valid_o = '0;
    complete_exception_tval_o = '0;
    complete_branch_mispredict_o = '0;
    complete_branch_target_o = '0;
    complete_fflags_o = '0;
    int_ports_used_work = 0;
    fp_ports_used_work = 0;
    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      wakeup_class_o[slot] = REG_NONE;
      complete_exception_cause_o[slot] = EXC_ILLEGAL_INSTRUCTION;
    end

    for (int unsigned slot = 0; slot < ROB_COMPLETE_PORTS; slot++) begin
      logic [SOURCE_INDEX_WIDTH-1:0] source;
      source = '0;
      if (select_found_work[slot]) begin
        source = select_index_work[slot];
        source_ready_o[source] = 1'b1;
        complete_valid_o[slot] = 1'b1;
        complete_sequence_o[slot] = source_sequence_i[source];
        complete_exception_valid_o[slot] =
          source_exception_valid_i[source];
        complete_exception_cause_o[slot] =
          source_exception_cause_i[source];
        complete_exception_tval_o[slot] = source_exception_tval_i[source];
        complete_branch_mispredict_o[slot] =
          source_branch_mispredict_i[source];
        complete_branch_target_o[slot] = source_branch_target_i[source];
        complete_fflags_o[slot] = source_fflags_i[source];

        if (source_destination_valid_i[source] &&
            !source_exception_valid_i[source] &&
            (source_destination_class_i[source] != REG_NONE)) begin
          wakeup_valid_o[slot] = 1'b1;
          wakeup_class_o[slot] = source_destination_class_i[source];
          wakeup_phys_o[slot] = source_destination_phys_i[source];
          if (source_destination_class_i[source] == REG_INT) begin
            int_wb_valid_o[int_ports_used_work] = 1'b1;
            int_wb_phys_o[int_ports_used_work] =
              source_destination_phys_i[source];
            int_wb_data_o[int_ports_used_work] = source_data_i[source];
            int_ports_used_work = int_ports_used_work + 1;
          end else if (source_destination_class_i[source] == REG_FP) begin
            fp_wb_valid_o[fp_ports_used_work] = 1'b1;
            fp_wb_phys_o[fp_ports_used_work] =
              source_destination_phys_i[source];
            fp_wb_data_o[fp_ports_used_work] = 32'(source_data_i[source]);
            fp_ports_used_work = fp_ports_used_work + 1;
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_comb begin
    assert ($unsigned($countones(complete_valid_o)) <= ROB_COMPLETE_PORTS);
    assert ($unsigned($countones(int_wb_valid_o)) <= INT_WRITE_PORTS);
    assert ($unsigned($countones(fp_wb_valid_o)) <= FP_WRITE_PORTS);
    for (int unsigned lhs = 0; lhs < INT_WRITE_PORTS; lhs++) begin
      for (int unsigned rhs = lhs + 1; rhs < INT_WRITE_PORTS; rhs++) begin
        if (int_wb_valid_o[lhs] && int_wb_valid_o[rhs])
          assert (int_wb_phys_o[lhs] != int_wb_phys_o[rhs]);
      end
    end
    for (int unsigned lhs = 0; lhs < FP_WRITE_PORTS; lhs++) begin
      for (int unsigned rhs = lhs + 1; rhs < FP_WRITE_PORTS; rhs++) begin
        if (fp_wb_valid_o[lhs] && fp_wb_valid_o[rhs])
          assert (fp_wb_phys_o[lhs] != fp_wb_phys_o[rhs]);
      end
    end
  end
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "Writeback arbiter XLEN must be 32 or 64");
    if ((SOURCE_COUNT < 2) || (ROB_COMPLETE_PORTS < 2) ||
        (INT_WRITE_PORTS == 0) || (FP_WRITE_PORTS == 0))
      $fatal(1, "Writeback arbiter resource dimensions are invalid");
    if (ROB_SEQ_WIDTH < 2)
      $fatal(1, "Writeback arbiter requires wrap-aware sequences");
  end

endmodule
