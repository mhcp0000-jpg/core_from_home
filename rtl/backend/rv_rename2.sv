module rv_rename2 #(
  parameter int unsigned INT_PHYS_REGS = 80,
  parameter int unsigned FP_PHYS_REGS  = 80,
  parameter int unsigned PHYS_TAG_WIDTH = 7,
  parameter int unsigned BR_CHECKPOINTS = 8,
  localparam int unsigned CHECKPOINT_ID_WIDTH = $clog2(BR_CHECKPOINTS),
  localparam int unsigned INT_FREE_COUNT_WIDTH = $clog2(INT_PHYS_REGS + 1),
  localparam int unsigned FP_FREE_COUNT_WIDTH  = $clog2(FP_PHYS_REGS + 1)
) (
  input  logic                                  clk_i,
  input  logic                                  rst_ni,

  input  logic [1:0]                            rename_valid_i,
  input  logic                                  dispatch_accept_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          src0_class_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          src1_class_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          src2_class_i,
  input  logic [1:0][4:0]                       src0_arch_i,
  input  logic [1:0][4:0]                       src1_arch_i,
  input  logic [1:0][4:0]                       src2_arch_i,
  input  logic [1:0]                            writes_destination_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          destination_class_i,
  input  logic [1:0][4:0]                       destination_arch_i,

  output logic                                  rename_can_accept_o,
  output logic                                  rename_fire_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        src0_phys_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        src1_phys_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        src2_phys_o,
  output logic [1:0]                            writes_destination_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        destination_phys_o,
  output logic [1:0][PHYS_TAG_WIDTH-1:0]        stale_phys_o,

  input  logic [1:0]                            commit_valid_i,
  input  logic [1:0]                            commit_writes_destination_i,
  input  rv_ooo_pkg::reg_class_e [1:0]          commit_destination_class_i,
  input  logic [1:0][4:0]                       commit_destination_arch_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        commit_destination_phys_i,
  input  logic [1:0][PHYS_TAG_WIDTH-1:0]        commit_stale_phys_i,

  input  logic                                  recover_committed_i,
  input  logic                                  restore_checkpoint_i,
  input  logic [CHECKPOINT_ID_WIDTH-1:0]        restore_checkpoint_id_i,
  input  logic [1:0]                            checkpoint_save_i,
  input  logic [1:0][CHECKPOINT_ID_WIDTH-1:0]   checkpoint_save_id_i,
  input  logic                                  checkpoint_release_i,
  input  logic [CHECKPOINT_ID_WIDTH-1:0]        checkpoint_release_id_i,
  input  logic [BR_CHECKPOINTS-1:0]             checkpoint_clear_mask_i,
  output logic [BR_CHECKPOINTS-1:0]             checkpoint_valid_o,

  output logic [INT_FREE_COUNT_WIDTH-1:0]       int_free_count_o,
  output logic [FP_FREE_COUNT_WIDTH-1:0]        fp_free_count_o
);

  import rv_ooo_pkg::*;

  logic [PHYS_TAG_WIDTH-1:0] int_rat_q [0:ARCH_INT_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0] int_rrat_q [0:ARCH_INT_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0] fp_rat_q [0:ARCH_FP_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0] fp_rrat_q [0:ARCH_FP_REGS-1];
  logic [INT_PHYS_REGS-1:0] int_free_q;
  logic [FP_PHYS_REGS-1:0] fp_free_q;

  logic [BR_CHECKPOINTS-1:0] checkpoint_valid_q;
  logic [PHYS_TAG_WIDTH-1:0]
    checkpoint_int_rat_q [0:BR_CHECKPOINTS-1][0:ARCH_INT_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0]
    checkpoint_fp_rat_q [0:BR_CHECKPOINTS-1][0:ARCH_FP_REGS-1];
  logic [INT_PHYS_REGS-1:0]
    checkpoint_int_free_q [0:BR_CHECKPOINTS-1];
  logic [FP_PHYS_REGS-1:0]
    checkpoint_fp_free_q [0:BR_CHECKPOINTS-1];

  logic [PHYS_TAG_WIDTH-1:0] int_rat_work [0:ARCH_INT_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0] fp_rat_work [0:ARCH_FP_REGS-1];
  logic [INT_PHYS_REGS-1:0] int_free_base;
  logic [FP_PHYS_REGS-1:0] fp_free_base;
  logic [INT_PHYS_REGS-1:0] int_free_work;
  logic [FP_PHYS_REGS-1:0] fp_free_work;
  logic allocation_ok;
  logic lane_shape_ok;

  logic [PHYS_TAG_WIDTH-1:0]
    checkpoint_int_rat_after_lane [0:1][0:ARCH_INT_REGS-1];
  logic [PHYS_TAG_WIDTH-1:0]
    checkpoint_fp_rat_after_lane [0:1][0:ARCH_FP_REGS-1];
  logic [INT_PHYS_REGS-1:0] checkpoint_int_free_after_lane [0:1];
  logic [FP_PHYS_REGS-1:0] checkpoint_fp_free_after_lane [0:1];

  logic [INT_PHYS_REGS-1:0] committed_int_free;
  logic [FP_PHYS_REGS-1:0] committed_fp_free;

  function automatic logic [PHYS_TAG_WIDTH-1:0] first_free_int(
    input logic [INT_PHYS_REGS-1:0] bitmap
  );
    logic [PHYS_TAG_WIDTH-1:0] selected;
    logic found;
    selected = '0;
    found    = 1'b0;
    for (int unsigned tag = 0; tag < INT_PHYS_REGS; tag++) begin
      if (bitmap[tag] && !found) begin
        selected = PHYS_TAG_WIDTH'(tag);
        found    = 1'b1;
      end
    end
    return selected;
  endfunction

  function automatic logic [PHYS_TAG_WIDTH-1:0] first_free_fp(
    input logic [FP_PHYS_REGS-1:0] bitmap
  );
    logic [PHYS_TAG_WIDTH-1:0] selected;
    logic found;
    selected = '0;
    found    = 1'b0;
    for (int unsigned tag = 0; tag < FP_PHYS_REGS; tag++) begin
      if (bitmap[tag] && !found) begin
        selected = PHYS_TAG_WIDTH'(tag);
        found    = 1'b1;
      end
    end
    return selected;
  endfunction

  function automatic logic [PHYS_TAG_WIDTH-1:0] map_source(
    input reg_class_e source_class,
    input logic [4:0] source_arch,
    input logic [PHYS_TAG_WIDTH-1:0] integer_map [0:ARCH_INT_REGS-1],
    input logic [PHYS_TAG_WIDTH-1:0] fp_map [0:ARCH_FP_REGS-1]
  );
    case (source_class)
      REG_INT: return integer_map[source_arch];
      REG_FP:  return fp_map[source_arch];
      default: return '0;
    endcase
  endfunction

  always_comb begin
    committed_int_free = '1;
    committed_fp_free  = '1;
    for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
      committed_int_free[int_rrat_q[arch]] = 1'b0;
    for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
      committed_fp_free[fp_rrat_q[arch]] = 1'b0;
  end

  // Commit is logically older than same-cycle rename, so a stale physical
  // register released at commit may be allocated immediately by lane0/lane1.
  always_comb begin
    int_free_base = int_free_q;
    fp_free_base  = fp_free_q;
    for (int unsigned lane = 0; lane < 2; lane++) begin
      if (commit_valid_i[lane] && commit_writes_destination_i[lane]) begin
        case (commit_destination_class_i[lane])
          REG_INT: int_free_base[commit_stale_phys_i[lane]] = 1'b1;
          REG_FP:  fp_free_base[commit_stale_phys_i[lane]] = 1'b1;
          default: begin end
        endcase
      end
    end
  end

  always_comb begin
    for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
      int_rat_work[arch] = int_rat_q[arch];
    for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
      fp_rat_work[arch] = fp_rat_q[arch];
    int_free_work = int_free_base;
    fp_free_work  = fp_free_base;

    src0_phys_o            = '0;
    src1_phys_o            = '0;
    src2_phys_o            = '0;
    writes_destination_o   = '0;
    destination_phys_o     = '0;
    stale_phys_o           = '0;
    allocation_ok          = 1'b1;
    lane_shape_ok          = !rename_valid_i[1] || rename_valid_i[0];

    for (int unsigned lane = 0; lane < 2; lane++) begin
      src0_phys_o[lane] = map_source(src0_class_i[lane], src0_arch_i[lane],
                                     int_rat_work, fp_rat_work);
      src1_phys_o[lane] = map_source(src1_class_i[lane], src1_arch_i[lane],
                                     int_rat_work, fp_rat_work);
      src2_phys_o[lane] = map_source(src2_class_i[lane], src2_arch_i[lane],
                                     int_rat_work, fp_rat_work);

      writes_destination_o[lane] = rename_valid_i[lane] &&
        writes_destination_i[lane] &&
        !((destination_class_i[lane] == REG_INT) &&
          (destination_arch_i[lane] == 0));

      if (writes_destination_o[lane]) begin
        case (destination_class_i[lane])
          REG_INT: begin
            if (|int_free_work) begin
              stale_phys_o[lane] = int_rat_work[destination_arch_i[lane]];
              destination_phys_o[lane] = first_free_int(int_free_work);
              int_free_work[destination_phys_o[lane]] = 1'b0;
              int_rat_work[destination_arch_i[lane]] =
                destination_phys_o[lane];
            end else begin
              allocation_ok = 1'b0;
            end
          end
          REG_FP: begin
            if (|fp_free_work) begin
              stale_phys_o[lane] = fp_rat_work[destination_arch_i[lane]];
              destination_phys_o[lane] = first_free_fp(fp_free_work);
              fp_free_work[destination_phys_o[lane]] = 1'b0;
              fp_rat_work[destination_arch_i[lane]] =
                destination_phys_o[lane];
            end else begin
              allocation_ok = 1'b0;
            end
          end
          default: allocation_ok = 1'b0;
        endcase
      end

      for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
        checkpoint_int_rat_after_lane[lane][arch] = int_rat_work[arch];
      for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
        checkpoint_fp_rat_after_lane[lane][arch] = fp_rat_work[arch];
      checkpoint_int_free_after_lane[lane] = int_free_work;
      checkpoint_fp_free_after_lane[lane]  = fp_free_work;
    end

    rename_can_accept_o = allocation_ok && lane_shape_ok &&
                          !recover_committed_i && !restore_checkpoint_i;
    rename_fire_o = rename_can_accept_o && dispatch_accept_i &&
                    (|rename_valid_i);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++) begin
        int_rat_q[arch]  <= PHYS_TAG_WIDTH'(arch);
        int_rrat_q[arch] <= PHYS_TAG_WIDTH'(arch);
      end
      for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++) begin
        fp_rat_q[arch]  <= PHYS_TAG_WIDTH'(arch);
        fp_rrat_q[arch] <= PHYS_TAG_WIDTH'(arch);
      end
      int_free_q <= '0;
      fp_free_q  <= '0;
      for (int unsigned tag = ARCH_INT_REGS; tag < INT_PHYS_REGS; tag++)
        int_free_q[tag] <= 1'b1;
      for (int unsigned tag = ARCH_FP_REGS; tag < FP_PHYS_REGS; tag++)
        fp_free_q[tag] <= 1'b1;
      checkpoint_valid_q <= '0;
      for (int unsigned checkpoint = 0;
           checkpoint < BR_CHECKPOINTS; checkpoint++) begin
        checkpoint_int_free_q[checkpoint] <= '0;
        checkpoint_fp_free_q[checkpoint]  <= '0;
        for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
          checkpoint_int_rat_q[checkpoint][arch] <= '0;
        for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
          checkpoint_fp_rat_q[checkpoint][arch] <= '0;
      end
    end else if (recover_committed_i) begin
      for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
        int_rat_q[arch] <= int_rrat_q[arch];
      for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
        fp_rat_q[arch] <= fp_rrat_q[arch];
      int_free_q <= committed_int_free;
      fp_free_q  <= committed_fp_free;
      checkpoint_valid_q <= '0;
    end else if (restore_checkpoint_i) begin
      for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
        int_rat_q[arch] <=
          checkpoint_int_rat_q[restore_checkpoint_id_i][arch];
      for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
        fp_rat_q[arch] <=
          checkpoint_fp_rat_q[restore_checkpoint_id_i][arch];
      int_free_q <= checkpoint_int_free_q[restore_checkpoint_id_i];
      fp_free_q  <= checkpoint_fp_free_q[restore_checkpoint_id_i];
      checkpoint_valid_q <= checkpoint_valid_q & ~checkpoint_clear_mask_i;
      checkpoint_valid_q[restore_checkpoint_id_i] <= 1'b0;
    end else begin
      int_free_q <= int_free_base;
      fp_free_q  <= fp_free_base;

      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (commit_valid_i[lane] && commit_writes_destination_i[lane]) begin
          case (commit_destination_class_i[lane])
            REG_INT: int_rrat_q[commit_destination_arch_i[lane]] <=
                       commit_destination_phys_i[lane];
            REG_FP:  fp_rrat_q[commit_destination_arch_i[lane]] <=
                       commit_destination_phys_i[lane];
            default: begin end
          endcase
        end
      end

      // Stale tags released by older commits must also become free in every
      // live branch snapshot, otherwise repeated recovery would leak tags.
      for (int unsigned checkpoint = 0;
           checkpoint < BR_CHECKPOINTS; checkpoint++) begin
        if (checkpoint_valid_q[checkpoint]) begin
          for (int unsigned lane = 0; lane < 2; lane++) begin
            if (commit_valid_i[lane] &&
                commit_writes_destination_i[lane]) begin
              case (commit_destination_class_i[lane])
                REG_INT:
                  checkpoint_int_free_q[checkpoint]
                    [commit_stale_phys_i[lane]] <= 1'b1;
                REG_FP:
                  checkpoint_fp_free_q[checkpoint]
                    [commit_stale_phys_i[lane]] <= 1'b1;
                default: begin end
              endcase
            end
          end
        end
      end

      checkpoint_valid_q <= checkpoint_valid_q & ~checkpoint_clear_mask_i;
      if (checkpoint_release_i)
        checkpoint_valid_q[checkpoint_release_id_i] <= 1'b0;

      if (rename_fire_o) begin
        for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
          int_rat_q[arch] <= int_rat_work[arch];
        for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
          fp_rat_q[arch] <= fp_rat_work[arch];
        int_free_q <= int_free_work;
        fp_free_q  <= fp_free_work;

        for (int unsigned lane = 0; lane < 2; lane++) begin
          if (rename_valid_i[lane] && checkpoint_save_i[lane]) begin
            checkpoint_valid_q[checkpoint_save_id_i[lane]] <= 1'b1;
            checkpoint_int_free_q[checkpoint_save_id_i[lane]] <=
              checkpoint_int_free_after_lane[lane];
            checkpoint_fp_free_q[checkpoint_save_id_i[lane]] <=
              checkpoint_fp_free_after_lane[lane];
            for (int unsigned arch = 0; arch < ARCH_INT_REGS; arch++)
              checkpoint_int_rat_q[checkpoint_save_id_i[lane]][arch] <=
                checkpoint_int_rat_after_lane[lane][arch];
            for (int unsigned arch = 0; arch < ARCH_FP_REGS; arch++)
              checkpoint_fp_rat_q[checkpoint_save_id_i[lane]][arch] <=
                checkpoint_fp_rat_after_lane[lane][arch];
          end
        end
      end
    end
  end

  assign checkpoint_valid_o = checkpoint_valid_q;
  assign int_free_count_o =
    INT_FREE_COUNT_WIDTH'($unsigned($countones(int_free_q)));
  assign fp_free_count_o =
    FP_FREE_COUNT_WIDTH'($unsigned($countones(fp_free_q)));

`ifndef SYNTHESIS
  property p_lane1_requires_lane0;
    @(posedge clk_i) disable iff (!rst_ni)
      rename_valid_i[1] |-> rename_valid_i[0];
  endproperty
  assert property (p_lane1_requires_lane0);

  property p_fire_requires_capacity;
    @(posedge clk_i) disable iff (!rst_ni)
      rename_fire_o |-> rename_can_accept_o && dispatch_accept_i;
  endproperty
  assert property (p_fire_requires_capacity);

  property p_restore_uses_valid_checkpoint;
    @(posedge clk_i) disable iff (!rst_ni)
      restore_checkpoint_i |-> checkpoint_valid_q[restore_checkpoint_id_i];
  endproperty
  assert property (p_restore_uses_valid_checkpoint);

  property p_recovery_excludes_commit;
    @(posedge clk_i) disable iff (!rst_ni)
      (recover_committed_i || restore_checkpoint_i) |-> !(|commit_valid_i);
  endproperty
  assert property (p_recovery_excludes_commit);

  property p_distinct_integer_allocations;
    @(posedge clk_i) disable iff (!rst_ni)
      rename_fire_o && writes_destination_o[0] &&
      writes_destination_o[1] &&
      (destination_class_i[0] == REG_INT) &&
      (destination_class_i[1] == REG_INT)
      |-> destination_phys_o[0] != destination_phys_o[1];
  endproperty
  assert property (p_distinct_integer_allocations);

  property p_distinct_fp_allocations;
    @(posedge clk_i) disable iff (!rst_ni)
      rename_fire_o && writes_destination_o[0] &&
      writes_destination_o[1] &&
      (destination_class_i[0] == REG_FP) &&
      (destination_class_i[1] == REG_FP)
      |-> destination_phys_o[0] != destination_phys_o[1];
  endproperty
  assert property (p_distinct_fp_allocations);
`endif

  initial begin : p_parameter_checks
    if ((INT_PHYS_REGS < ARCH_INT_REGS) ||
        (FP_PHYS_REGS < ARCH_FP_REGS))
      $fatal(1, "Physical files must cover all architectural registers");
    if ((INT_PHYS_REGS > (1 << PHYS_TAG_WIDTH)) ||
        (FP_PHYS_REGS > (1 << PHYS_TAG_WIDTH)))
      $fatal(1, "PHYS_TAG_WIDTH cannot represent all physical registers");
    if (BR_CHECKPOINTS < 2)
      $fatal(1, "At least two branch checkpoints are required");
  end

endmodule
