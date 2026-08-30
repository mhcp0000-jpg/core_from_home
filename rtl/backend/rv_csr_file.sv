module rv_csr_file #(
  parameter int unsigned XLEN = 32,
  parameter int unsigned PADDR_WIDTH = XLEN,
  parameter bit HAS_SMODE = 1'b0,
  parameter int unsigned PMP_ENTRIES = 8,
  parameter logic [XLEN-1:0] RESET_MTVEC = 'h8000_0000,
  parameter logic [XLEN-1:0] HART_ID = '0,
  localparam int unsigned PMP_ADDR_WIDTH = PADDR_WIDTH - 2
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,

  // A CSR instruction is evaluated only at the ROB head.  csr_commit_i is
  // the architectural commit edge; evaluation alone never changes state.
  input  logic                         csr_valid_i,
  input  logic                         csr_execute_i,
  input  logic                         csr_commit_i,
  input  logic [11:0]                  csr_addr_i,
  input  rv_ooo_pkg::csr_cmd_e         csr_cmd_i,
  input  logic [XLEN-1:0]              csr_operand_i,
  input  logic                         csr_rs1_is_zero_i,
  output logic                         csr_ready_o,
  output logic [XLEN-1:0]              csr_rdata_o,
  output logic                         csr_illegal_o,
  output logic                         csr_write_effect_o,

  // Precise trap and xRET ports.  trap_cause_i contains the low cause code;
  // the interrupt bit is supplied separately and encoded into mcause here.
  input  logic                         trap_valid_i,
  output logic                         trap_ready_o,
  input  logic [XLEN-1:0]              trap_pc_i,
  input  logic [5:0]                   trap_cause_i,
  input  logic [XLEN-1:0]              trap_tval_i,
  input  logic                         trap_is_interrupt_i,
  input  logic [XLEN-1:0]              trap_next_pc_i,
  output logic [XLEN-1:0]              trap_vector_o,

  input  logic                         mret_valid_i,
  input  logic                         mret_commit_i,
  output logic                         mret_ready_o,
  output logic [XLEN-1:0]              mret_pc_o,
  output logic                         mret_illegal_o,

  input  logic                         wfi_valid_i,
  output logic                         wfi_illegal_o,
  output logic                         wfi_wake_o,

  input  logic                         irq_software_i,
  input  logic                         irq_timer_i,
  input  logic                         irq_external_i,
  input  logic [63:0]                  mtime_i,
  output logic                         interrupt_pending_o,
  output logic [5:0]                   interrupt_cause_o,

  input  logic [1:0]                   retire_count_i,
  input  logic                         fflags_accrue_valid_i,
  input  logic [4:0]                   fflags_accrue_i,
  input  logic                         flush_all_i,

  output rv_ooo_pkg::privilege_e       privilege_o,
  output logic [XLEN-1:0]              mstatus_o,
  output logic [XLEN-1:0]              mtvec_o,
  output logic [XLEN-1:0]              mepc_o,
  output logic [2:0]                   frm_o,
  output logic [4:0]                   fflags_o,
  output logic [PMP_ENTRIES-1:0][7:0] pmpcfg_o,
  output logic [PMP_ENTRIES-1:0][PMP_ADDR_WIDTH-1:0] pmpaddr_o
);

  import rv_ooo_pkg::*;

  localparam int unsigned MSTATUS_MIE  = 3;
  localparam int unsigned MSTATUS_MPIE = 7;
  localparam int unsigned MSTATUS_MPP_LO = 11;
  localparam int unsigned MSTATUS_FS_LO = 13;
  localparam int unsigned MSTATUS_MPRV = 17;
  localparam int unsigned MSTATUS_TW   = 21;
  localparam int unsigned MIP_MSIP = 3;
  localparam int unsigned MIP_MTIP = 7;
  localparam int unsigned MIP_MEIP = 11;

  privilege_e current_priv_q;
  logic [XLEN-1:0] mstatus_q;
  logic [XLEN-1:0] mie_q;
  logic [XLEN-1:0] mtvec_q;
  logic [XLEN-1:0] mscratch_q;
  logic [XLEN-1:0] mepc_q;
  logic [XLEN-1:0] mcause_q;
  logic [XLEN-1:0] mtval_q;
  logic [XLEN-1:0] mcounteren_q;
  logic [63:0] mcycle_q;
  logic [63:0] minstret_q;
  logic [4:0] fflags_q;
  logic [2:0] frm_q;
  logic [7:0] pmpcfg_q [0:PMP_ENTRIES-1];
  logic [PMP_ADDR_WIDTH-1:0] pmpaddr_q [0:PMP_ENTRIES-1];
  logic csr_pending_q;
  logic [11:0] csr_pending_addr_q;
  logic csr_pending_write_q;
  logic [XLEN-1:0] csr_pending_wdata_q;

  logic [XLEN-1:0] mip_value;
  logic [XLEN-1:0] misa_value;
  logic [XLEN-1:0] csr_read_value;
  logic [XLEN-1:0] csr_write_value;
  logic [XLEN-1:0] mstatus_read_value;
  logic csr_exists;
  logic csr_counter_access;
  logic csr_read_only;
  logic csr_privilege_ok;
  logic csr_write_intent;
  logic [XLEN-1:0] enabled_interrupts;
  logic interrupt_global_enable;

  function automatic logic [XLEN-1:0] build_misa;
    logic [XLEN-1:0] value;
    value = '0;
    value[2]  = 1'b1; // C
    value[5]  = 1'b1; // F
    value[8]  = 1'b1; // I
    value[12] = 1'b1; // M
    value[20] = 1'b1; // U
    if (HAS_SMODE)
      value[18] = 1'b1;
    value[XLEN-1 -: 2] = (XLEN == 32) ? 2'b01 : 2'b10;
    return value;
  endfunction

  function automatic logic [XLEN-1:0] sanitize_mstatus(
    input logic [XLEN-1:0] value
  );
    logic [XLEN-1:0] result;
    logic [1:0] requested_mpp;
    result = '0;
    result[MSTATUS_MIE] = value[MSTATUS_MIE];
    result[MSTATUS_MPIE] = value[MSTATUS_MPIE];
    requested_mpp = value[MSTATUS_MPP_LO +: 2];
    if (requested_mpp == PRIV_M)
      result[MSTATUS_MPP_LO +: 2] = PRIV_M;
    else if (HAS_SMODE && (requested_mpp == PRIV_S))
      result[MSTATUS_MPP_LO +: 2] = PRIV_S;
    else
      result[MSTATUS_MPP_LO +: 2] = PRIV_U;
    result[MSTATUS_FS_LO +: 2] = value[MSTATUS_FS_LO +: 2];
    result[MSTATUS_MPRV] = value[MSTATUS_MPRV];
    result[MSTATUS_TW] = value[MSTATUS_TW];
    return result;
  endfunction

  function automatic logic pmp_address_locked(input int unsigned index);
    logic locked;
    locked = pmpcfg_q[index][7];
    if ((index + 1) < PMP_ENTRIES)
      locked |= pmpcfg_q[index+1][7] &&
                (pmpcfg_q[index+1][4:3] == 2'b01);
    return locked;
  endfunction

  always_comb begin
    misa_value = build_misa();
    mip_value = '0;
    mip_value[MIP_MSIP] = irq_software_i;
    mip_value[MIP_MTIP] = irq_timer_i;
    mip_value[MIP_MEIP] = irq_external_i;

    mstatus_read_value = mstatus_q;
    if (mstatus_q[MSTATUS_FS_LO +: 2] == 2'b11)
      mstatus_read_value[XLEN-1] = 1'b1;

    csr_exists = 1'b1;
    csr_counter_access = 1'b0;
    csr_read_value = '0;
    case (csr_addr_i)
      12'h001: csr_read_value = XLEN'(fflags_q);
      12'h002: csr_read_value = XLEN'(frm_q);
      12'h003: csr_read_value = XLEN'({frm_q, fflags_q});
      12'h300: csr_read_value = mstatus_read_value;
      12'h301: csr_read_value = misa_value;
      12'h304: csr_read_value = mie_q;
      12'h305: csr_read_value = mtvec_q;
      12'h306: csr_read_value = mcounteren_q;
      12'h340: csr_read_value = mscratch_q;
      12'h341: csr_read_value = mepc_q;
      12'h342: csr_read_value = mcause_q;
      12'h343: csr_read_value = mtval_q;
      12'h344: csr_read_value = mip_value;
      12'hB00: csr_read_value = XLEN'(mcycle_q);
      12'hB02: csr_read_value = XLEN'(minstret_q);
      12'hB80: begin
        csr_exists = (XLEN == 32);
        csr_read_value = XLEN'(mcycle_q[63:32]);
      end
      12'hB82: begin
        csr_exists = (XLEN == 32);
        csr_read_value = XLEN'(minstret_q[63:32]);
      end
      12'hC00: begin
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(mcycle_q);
      end
      12'hC01: begin
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(mtime_i);
      end
      12'hC02: begin
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(minstret_q);
      end
      12'hC80: begin
        csr_exists = (XLEN == 32);
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(mcycle_q[63:32]);
      end
      12'hC81: begin
        csr_exists = (XLEN == 32);
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(mtime_i[63:32]);
      end
      12'hC82: begin
        csr_exists = (XLEN == 32);
        csr_counter_access = 1'b1;
        csr_read_value = XLEN'(minstret_q[63:32]);
      end
      12'hF11, 12'hF12, 12'hF13: csr_read_value = '0;
      12'hF14: csr_read_value = HART_ID;
      default: begin
        csr_exists = 1'b0;
        for (int unsigned cfg_csr = 0; cfg_csr < 4; cfg_csr++) begin
          if (csr_addr_i == (12'h3A0 + cfg_csr)) begin
            csr_exists = (XLEN == 32) || ((cfg_csr & 1) == 0);
            csr_read_value = '0;
            for (int unsigned byte_index = 0;
                 byte_index < (XLEN/8); byte_index++) begin
              int unsigned entry_index;
              entry_index = cfg_csr * 4 + byte_index;
              if (XLEN == 64)
                entry_index = (cfg_csr / 2) * 8 + byte_index;
              if (entry_index < PMP_ENTRIES)
                csr_read_value[byte_index*8 +: 8] = pmpcfg_q[entry_index];
            end
          end
        end
        for (int unsigned entry = 0; entry < PMP_ENTRIES; entry++) begin
          if (csr_addr_i == (12'h3B0 + entry)) begin
            csr_exists = 1'b1;
            csr_read_value = XLEN'(pmpaddr_q[entry]);
          end
        end
      end
    endcase

    csr_write_intent = (csr_cmd_i == CSR_CMD_WRITE) ||
      (((csr_cmd_i == CSR_CMD_SET) || (csr_cmd_i == CSR_CMD_CLEAR)) &&
       !csr_rs1_is_zero_i);
    case (csr_cmd_i)
      CSR_CMD_WRITE: csr_write_value = csr_operand_i;
      CSR_CMD_SET:   csr_write_value = csr_read_value | csr_operand_i;
      CSR_CMD_CLEAR: csr_write_value = csr_read_value & ~csr_operand_i;
      default:       csr_write_value = csr_read_value;
    endcase

    csr_read_only = (csr_addr_i[11:10] == 2'b11);
    csr_privilege_ok = (current_priv_q >= privilege_e'(csr_addr_i[9:8]));
    if (csr_counter_access && (current_priv_q != PRIV_M)) begin
      case (csr_addr_i[7:0])
        8'h00, 8'h80: csr_privilege_ok &= mcounteren_q[0];
        8'h01, 8'h81: csr_privilege_ok &= mcounteren_q[1];
        8'h02, 8'h82: csr_privilege_ok &= mcounteren_q[2];
        default: csr_privilege_ok = 1'b0;
      endcase
    end

    csr_ready_o = 1'b1;
    csr_rdata_o = csr_read_value;
    csr_illegal_o = csr_valid_i &&
      (!csr_exists || !csr_privilege_ok ||
       (csr_read_only && csr_write_intent) ||
       (csr_cmd_i == CSR_CMD_NONE));
    csr_write_effect_o = csr_valid_i && !csr_illegal_o && csr_write_intent;
  end

  always_comb begin
    enabled_interrupts = mie_q & mip_value;
    interrupt_global_enable = (current_priv_q != PRIV_M) ||
                              mstatus_q[MSTATUS_MIE];
    interrupt_pending_o = interrupt_global_enable && (|enabled_interrupts);
    wfi_wake_o = |enabled_interrupts;
    interrupt_cause_o = 6'd0;
    if (enabled_interrupts[MIP_MTIP])
      interrupt_cause_o = 6'd7;
    if (enabled_interrupts[MIP_MSIP])
      interrupt_cause_o = 6'd3;
    if (enabled_interrupts[MIP_MEIP])
      interrupt_cause_o = 6'd11;

    trap_ready_o = 1'b1;
    trap_vector_o = {mtvec_q[XLEN-1:2], 2'b00};
    if (trap_is_interrupt_i && (mtvec_q[1:0] == 2'b01))
      trap_vector_o = {mtvec_q[XLEN-1:2], 2'b00} +
                      (XLEN'(trap_cause_i) << 2);

    mret_ready_o = 1'b1;
    mret_pc_o = {mepc_q[XLEN-1:1], 1'b0};
    mret_illegal_o = mret_valid_i && (current_priv_q != PRIV_M);
    wfi_illegal_o = wfi_valid_i && (current_priv_q != PRIV_M) &&
                    mstatus_q[MSTATUS_TW];
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      current_priv_q <= PRIV_M;
      mstatus_q <= '0;
      mie_q <= '0;
      mtvec_q <= {RESET_MTVEC[XLEN-1:2], 2'b00};
      mscratch_q <= '0;
      mepc_q <= '0;
      mcause_q <= '0;
      mtval_q <= '0;
      mcounteren_q <= '0;
      mcycle_q <= '0;
      minstret_q <= '0;
      fflags_q <= '0;
      frm_q <= '0;
      csr_pending_q <= 1'b0;
      csr_pending_addr_q <= '0;
      csr_pending_write_q <= 1'b0;
      csr_pending_wdata_q <= '0;
      for (int unsigned entry = 0; entry < PMP_ENTRIES; entry++) begin
        pmpcfg_q[entry] <= '0;
        pmpaddr_q[entry] <= '0;
      end
    end else begin
      mcycle_q <= mcycle_q + 1'b1;
      minstret_q <= minstret_q + retire_count_i;
      if (fflags_accrue_valid_i)
        fflags_q <= fflags_q | fflags_accrue_i;

      if (flush_all_i)
        csr_pending_q <= 1'b0;
      else if (csr_valid_i && csr_execute_i && !csr_illegal_o) begin
        csr_pending_q <= 1'b1;
        csr_pending_addr_q <= csr_addr_i;
        csr_pending_write_q <= csr_write_intent;
        csr_pending_wdata_q <= csr_write_value;
      end

      if (trap_valid_i && trap_ready_o) begin
        mepc_q <= trap_is_interrupt_i ?
                  {trap_next_pc_i[XLEN-1:1], 1'b0} :
                  {trap_pc_i[XLEN-1:1], 1'b0};
        mcause_q <= {{(XLEN-6){1'b0}}, trap_cause_i};
        mcause_q[XLEN-1] <= trap_is_interrupt_i;
        mtval_q <= trap_tval_i;
        mstatus_q[MSTATUS_MPIE] <= mstatus_q[MSTATUS_MIE];
        mstatus_q[MSTATUS_MIE] <= 1'b0;
        mstatus_q[MSTATUS_MPP_LO +: 2] <= current_priv_q;
        current_priv_q <= PRIV_M;
      end else if (mret_valid_i && mret_commit_i && !mret_illegal_o) begin
        current_priv_q <= privilege_e'(mstatus_q[MSTATUS_MPP_LO +: 2]);
        mstatus_q[MSTATUS_MIE] <= mstatus_q[MSTATUS_MPIE];
        mstatus_q[MSTATUS_MPIE] <= 1'b1;
        mstatus_q[MSTATUS_MPP_LO +: 2] <= PRIV_U;
        if (mstatus_q[MSTATUS_MPP_LO +: 2] != PRIV_M)
          mstatus_q[MSTATUS_MPRV] <= 1'b0;
      end else if (csr_commit_i && csr_pending_q) begin
        csr_pending_q <= 1'b0;
        if (csr_pending_write_q) case (csr_pending_addr_q)
          12'h001: fflags_q <= csr_pending_wdata_q[4:0];
          12'h002: frm_q <= csr_pending_wdata_q[2:0];
          12'h003: begin
            fflags_q <= csr_pending_wdata_q[4:0];
            frm_q <= csr_pending_wdata_q[7:5];
          end
          12'h300: mstatus_q <= sanitize_mstatus(csr_pending_wdata_q);
          12'h304: begin
            mie_q <= '0;
            mie_q[MIP_MSIP] <= csr_pending_wdata_q[MIP_MSIP];
            mie_q[MIP_MTIP] <= csr_pending_wdata_q[MIP_MTIP];
            mie_q[MIP_MEIP] <= csr_pending_wdata_q[MIP_MEIP];
          end
          12'h305: begin
            mtvec_q <= {csr_pending_wdata_q[XLEN-1:2], 2'b00};
            if (csr_pending_wdata_q[1:0] == 2'b01)
              mtvec_q[1:0] <= 2'b01;
          end
          12'h306: mcounteren_q <= csr_pending_wdata_q & XLEN'(3'b111);
          12'h340: mscratch_q <= csr_pending_wdata_q;
          12'h341: mepc_q <= {csr_pending_wdata_q[XLEN-1:1], 1'b0};
          12'h342: mcause_q <= csr_pending_wdata_q;
          12'h343: mtval_q <= csr_pending_wdata_q;
          12'hB00: mcycle_q <= (XLEN == 32) ?
            {mcycle_q[63:32], csr_pending_wdata_q[31:0]} :
            csr_pending_wdata_q;
          12'hB02: minstret_q <= (XLEN == 32) ?
            {minstret_q[63:32], csr_pending_wdata_q[31:0]} :
            csr_pending_wdata_q;
          12'hB80: if (XLEN == 32)
            mcycle_q[63:32] <= csr_pending_wdata_q[31:0];
          12'hB82: if (XLEN == 32)
            minstret_q[63:32] <= csr_pending_wdata_q[31:0];
          default: begin
            for (int unsigned cfg_csr = 0; cfg_csr < 4; cfg_csr++) begin
              if (csr_pending_addr_q == (12'h3A0 + cfg_csr)) begin
                for (int unsigned byte_index = 0;
                     byte_index < (XLEN/8); byte_index++) begin
                  int unsigned entry_index;
                  logic [7:0] cfg_value;
                  entry_index = cfg_csr * 4 + byte_index;
                  if (XLEN == 64)
                    entry_index = (cfg_csr / 2) * 8 + byte_index;
                  cfg_value = csr_pending_wdata_q[byte_index*8 +: 8];
                  if ((entry_index < PMP_ENTRIES) &&
                      !pmpcfg_q[entry_index][7]) begin
                    // Reserved R=0,W=1 is coerced to no permissions.
                    if (!cfg_value[0] && cfg_value[1])
                      cfg_value[2:0] = 3'b000;
                    pmpcfg_q[entry_index] <= cfg_value;
                  end
                end
              end
            end
            for (int unsigned entry = 0; entry < PMP_ENTRIES; entry++) begin
              if ((csr_pending_addr_q == (12'h3B0 + entry)) &&
                  !pmp_address_locked(entry))
                pmpaddr_q[entry] <= PMP_ADDR_WIDTH'(csr_pending_wdata_q);
            end
          end
        endcase
      end
    end
  end

  assign privilege_o = current_priv_q;
  assign mstatus_o = mstatus_read_value;
  assign mtvec_o = mtvec_q;
  assign mepc_o = mepc_q;
  assign frm_o = frm_q;
  assign fflags_o = fflags_q;
  generate
    for (genvar entry = 0; entry < PMP_ENTRIES; entry++) begin : g_pmp_output
      assign pmpcfg_o[entry] = pmpcfg_q[entry];
      assign pmpaddr_o[entry] = pmpaddr_q[entry];
    end
  endgenerate

`ifndef SYNTHESIS
  property p_no_illegal_csr_write;
    @(posedge clk_i) disable iff (!rst_ni)
      csr_valid_i && csr_commit_i && csr_illegal_o |-> !csr_write_effect_o;
  endproperty
  assert property (p_no_illegal_csr_write);

  property p_trap_enters_machine_mode;
    @(posedge clk_i) disable iff (!rst_ni)
      trap_valid_i && trap_ready_o |=> privilege_o == PRIV_M;
  endproperty
  assert property (p_trap_enters_machine_mode);
`endif

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "CSR file XLEN must be 32 or 64");
    if ((PADDR_WIDTH < 4) || ((PADDR_WIDTH-2) > XLEN))
      $fatal(1, "CSR PMP address width must be in [2, XLEN]");
    if ((PMP_ENTRIES == 0) || (PMP_ENTRIES > 16))
      $fatal(1, "CSR file supports 1..16 PMP entries");
  end

endmodule
