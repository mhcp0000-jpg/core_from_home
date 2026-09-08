module rv_commit_trace_logger #(
  parameter int unsigned XLEN = 32
) (
  input logic                         clk_i,
  input logic                         rst_ni,
  input logic [1:0]                   trace_valid_i,
  input logic [1:0][XLEN-1:0]         trace_pc_i,
  input logic [1:0][31:0]             trace_instr_i,
  input logic [1:0][4:0]              trace_rd_i,
  input logic [1:0]                   trace_rd_write_i,
  input logic [1:0]                   trace_rd_fp_i,
  input logic [1:0][XLEN-1:0]         trace_rd_wdata_i,
  input logic [1:0]                   trace_trap_i,
  input logic [1:0][5:0]              trace_cause_i,
  input logic [1:0][XLEN-1:0]         trace_tval_i,
  // CSR instructions retire only in lane 0. These inputs describe the saved
  // evaluation transaction at its commit edge, never the current decode.
  input logic                        csr_commit_valid_i,
  input logic                        csr_commit_write_i,
  input logic [11:0]                 csr_commit_addr_i,
  input logic [XLEN-1:0]             csr_commit_wdata_i,
  output logic                        last_commit_valid_o,
  output logic [63:0]                 retire_order_o,
  output logic [63:0]                 cycle_o,
  output logic [63:0]                 cycles_since_commit_o,
  output logic [XLEN-1:0]             last_commit_pc_o,
  output logic [31:0]                 last_commit_instr_o
  );

  integer trace_fd;
  string trace_path;
  longint unsigned retire_order_q;
  longint unsigned cycle_q;
  longint unsigned cycles_since_commit_q;
  logic last_commit_valid_q;
  logic [XLEN-1:0] last_commit_pc_q;
  logic [31:0] last_commit_instr_q;
  logic [1:0] csr_valid, csr_we;
  logic [1:0][11:0] csr_addr;
  logic [1:0][XLEN-1:0] csr_wdata;

  // Human-readable debug aid. The architectural comparison must continue to
  // use the raw instruction bits; this name is intentionally not fed back
  // into the core. ROB stores the original 16-bit C encoding (zero-extended)
  // and the original 32-bit encoding, so decode both forms here.
  function automatic string compressed_mnemonic(input logic [15:0] insn);
    if (insn == 16'h0000)
      return "C.ILLEGAL";
    case (insn[1:0])
      2'b00: begin
        case (insn[15:13])
          3'b000: return "C.ADDI4SPN";
          3'b010: return "C.LW";
          3'b011: return (XLEN == 32) ? "C.FLW" : "C.LD";
          3'b110: return "C.SW";
          3'b111: return (XLEN == 32) ? "C.FSW" : "C.SD";
          default: return "C.ILLEGAL";
        endcase
      end
      2'b01: begin
        case (insn[15:13])
          3'b000: return (insn[11:7] == 0 && insn[12] == 0 &&
                          insn[6:2] == 0) ? "C.NOP" : "C.ADDI";
          3'b001: return (XLEN == 32) ? "C.JAL" : "C.ADDIW";
          3'b010: return "C.LI";
          3'b011: return (insn[11:7] == 5'd2) ? "C.ADDI16SP" : "C.LUI";
          3'b100: begin
            case (insn[11:10])
              2'b00: return "C.SRLI";
              2'b01: return "C.SRAI";
              2'b10: return "C.ANDI";
              default: begin
                if (!insn[12]) begin
                  case (insn[6:5])
                    2'b00: return "C.SUB";
                    2'b01: return "C.XOR";
                    2'b10: return "C.OR";
                    default: return "C.AND";
                  endcase
                end
                if (XLEN == 64) begin
                  case (insn[6:5])
                    2'b00: return "C.SUBW";
                    2'b01: return "C.ADDW";
                    default: return "C.ILLEGAL";
                  endcase
                end
                return "C.ILLEGAL";
              end
            endcase
          end
          3'b101: return "C.J";
          3'b110: return "C.BEQZ";
          3'b111: return "C.BNEZ";
          default: return "C.ILLEGAL";
        endcase
      end
      2'b10: begin
        case (insn[15:13])
          3'b000: return "C.SLLI";
          3'b010: return "C.LWSP";
          3'b011: return (XLEN == 32) ? "C.FLWSP" : "C.LDSP";
          3'b100: begin
            if (!insn[12])
              return (insn[6:2] == 0) ? "C.JR" : "C.MV";
            if ((insn[11:7] == 0) && (insn[6:2] == 0))
              return "C.EBREAK";
            return (insn[6:2] == 0) ? "C.JALR" : "C.ADD";
          end
          3'b110: return "C.SWSP";
          3'b111: return (XLEN == 32) ? "C.FSWSP" : "C.SDSP";
          default: return "C.ILLEGAL";
        endcase
      end
      default: return "C.ILLEGAL";
    endcase
  endfunction

  function automatic string instruction_mnemonic(input logic [31:0] insn);
    logic [6:0] funct7;
    logic [2:0] funct3;
    logic [4:0] rs2;
    if (insn[1:0] != 2'b11)
      return compressed_mnemonic(insn[15:0]);
    funct7 = insn[31:25];
    funct3 = insn[14:12];
    rs2 = insn[24:20];
    case (insn[6:0])
      7'b0110111: return "LUI";
      7'b0010111: return "AUIPC";
      7'b1101111: return "JAL";
      7'b1100111: return "JALR";
      7'b1100011: begin
        case (funct3)
          3'b000: return "BEQ";  3'b001: return "BNE";
          3'b100: return "BLT";  3'b101: return "BGE";
          3'b110: return "BLTU"; 3'b111: return "BGEU";
          default: return "ILLEGAL";
        endcase
      end
      7'b0000011: begin
        case (funct3)
          3'b000: return "LB";  3'b001: return "LH";
          3'b010: return "LW";  3'b011: return "LD";
          3'b100: return "LBU"; 3'b101: return "LHU";
          3'b110: return "LWU"; default: return "ILLEGAL";
        endcase
      end
      7'b0100011: begin
        case (funct3)
          3'b000: return "SB"; 3'b001: return "SH";
          3'b010: return "SW"; 3'b011: return "SD";
          default: return "ILLEGAL";
        endcase
      end
      7'b0010011: begin
        case (funct3)
          3'b000: return "ADDI";  3'b010: return "SLTI";
          3'b011: return "SLTIU"; 3'b100: return "XORI";
          3'b110: return "ORI";   3'b111: return "ANDI";
          3'b001: return "SLLI";
          3'b101: return insn[30] ? "SRAI" : "SRLI";
          default: return "ILLEGAL";
        endcase
      end
      7'b0110011: begin
        if (funct7 == 7'b0000001) begin
          case (funct3)
            3'b000: return "MUL";    3'b001: return "MULH";
            3'b010: return "MULHSU"; 3'b011: return "MULHU";
            3'b100: return "DIV";    3'b101: return "DIVU";
            3'b110: return "REM";    3'b111: return "REMU";
          endcase
        end
        case (funct3)
          3'b000: return insn[30] ? "SUB" : "ADD";
          3'b001: return "SLL";  3'b010: return "SLT";
          3'b011: return "SLTU"; 3'b100: return "XOR";
          3'b101: return insn[30] ? "SRA" : "SRL";
          3'b110: return "OR";   3'b111: return "AND";
        endcase
      end
      7'b0011011: begin
        case (funct3)
          3'b000: return "ADDIW";
          3'b001: return "SLLIW";
          3'b101: return insn[30] ? "SRAIW" : "SRLIW";
          default: return "ILLEGAL";
        endcase
      end
      7'b0111011: begin
        if (funct7 == 7'b0000001) begin
          case (funct3)
            3'b000: return "MULW"; 3'b100: return "DIVW";
            3'b101: return "DIVUW"; 3'b110: return "REMW";
            3'b111: return "REMUW"; default: return "ILLEGAL";
          endcase
        end
        case (funct3)
          3'b000: return insn[30] ? "SUBW" : "ADDW";
          3'b001: return "SLLW";
          3'b101: return insn[30] ? "SRAW" : "SRLW";
          default: return "ILLEGAL";
        endcase
      end
      7'b0001111: begin
        case (funct3)
          3'b000: return "FENCE"; 3'b001: return "FENCE.I";
          default: return "ILLEGAL";
        endcase
      end
      7'b1110011: begin
        if (funct3 == 0) begin
          case (insn[31:20])
            12'h000: return "ECALL";  12'h001: return "EBREAK";
            12'h102: return "SRET";   12'h302: return "MRET";
            12'h105: return "WFI";    default: return "SYSTEM";
          endcase
        end
        case (funct3)
          3'b001: return "CSRRW";  3'b010: return "CSRRS";
          3'b011: return "CSRRC";  3'b101: return "CSRRWI";
          3'b110: return "CSRRSI"; 3'b111: return "CSRRCI";
          default: return "ILLEGAL";
        endcase
      end
      7'b0000111: return (funct3 == 3'b010) ? "FLW" : "ILLEGAL";
      7'b0100111: return (funct3 == 3'b010) ? "FSW" : "ILLEGAL";
      7'b1000011: return "FMADD.S";
      7'b1000111: return "FMSUB.S";
      7'b1001011: return "FNMSUB.S";
      7'b1001111: return "FNMADD.S";
      7'b1010011: begin
        case (funct7)
          7'b0000000: return "FADD.S";  7'b0000100: return "FSUB.S";
          7'b0001000: return "FMUL.S";  7'b0001100: return "FDIV.S";
          7'b0101100: return "FSQRT.S";
          7'b0010000: begin
            case (funct3)
              3'b000: return "FSGNJ.S"; 3'b001: return "FSGNJN.S";
              3'b010: return "FSGNJX.S"; default: return "ILLEGAL";
            endcase
          end
          7'b0010100: return funct3[0] ? "FMAX.S" : "FMIN.S";
          7'b1010000: begin
            case (funct3)
              3'b000: return "FLE.S"; 3'b001: return "FLT.S";
              3'b010: return "FEQ.S"; default: return "ILLEGAL";
            endcase
          end
          7'b1100000: begin
            case (rs2)
              0: return "FCVT.W.S"; 1: return "FCVT.WU.S";
              2: return "FCVT.L.S"; 3: return "FCVT.LU.S";
              default: return "ILLEGAL";
            endcase
          end
          7'b1101000: begin
            case (rs2)
              0: return "FCVT.S.W"; 1: return "FCVT.S.WU";
              2: return "FCVT.S.L"; 3: return "FCVT.S.LU";
              default: return "ILLEGAL";
            endcase
          end
          7'b1110000: return funct3[0] ? "FCLASS.S" : "FMV.X.W";
          7'b1111000: return "FMV.W.X";
          default: return "ILLEGAL";
        endcase
      end
      default: return "ILLEGAL";
    endcase
  endfunction

  always_comb begin
    csr_valid = '0;
    csr_we = '0;
    csr_addr = '0;
    csr_wdata = '0;
    csr_valid[0] = trace_valid_i[0] && !trace_trap_i[0] && csr_commit_valid_i;
    csr_we[0] = csr_valid[0] && csr_commit_write_i;
    if (csr_valid[0]) csr_addr[0] = csr_commit_addr_i;
    if (csr_we[0]) csr_wdata[0] = csr_commit_wdata_i;
  end

  assign last_commit_valid_o = last_commit_valid_q;
  assign retire_order_o = retire_order_q;
  assign cycle_o = cycle_q;
  assign cycles_since_commit_o = cycles_since_commit_q;
  assign last_commit_pc_o = last_commit_pc_q;
  assign last_commit_instr_o = last_commit_instr_q;

  initial begin
    trace_fd = 0;
    if ($value$plusargs("trace_file=%s", trace_path)) begin
      trace_fd = $fopen(trace_path, "w");
      if (trace_fd == 0)
        $fatal(1, "Unable to open commit trace file: %s", trace_path);
      $fdisplay(trace_fd,
        "order,cycle,lane,pc,instruction,rd_write,rd_fp,rd,wdata,trap,cause,tval,gpr_we,fpr_we,csr_valid,csr_we,csr_addr,csr_wdata,mnemonic");
      $fflush(trace_fd);
      $display("[COMMIT][%0t] trace file opened: %s", $time, trace_path);
    end
    $display("[COMMIT][%0t] live logger enabled: every retired instruction",
             $time);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      retire_order_q <= 0;
      cycle_q <= 0;
      cycles_since_commit_q <= 0;
      last_commit_valid_q <= 1'b0;
      last_commit_pc_q <= '0;
      last_commit_instr_q <= '0;
    end else begin
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (trace_valid_i[lane]) begin
          if (trace_fd != 0) begin
            $fdisplay(trace_fd,
              "%0d,%0d,%0d,%x,%08x,%0d,%0d,%0d,%x,%0d,%0d,%x,%0d,%0d,%0d,%0d,%03x,%x,%s",
              retire_order_q + ((lane == 1) && trace_valid_i[0]), cycle_q, lane,
              trace_pc_i[lane], trace_instr_i[lane],
              trace_rd_write_i[lane], trace_rd_fp_i[lane], trace_rd_i[lane],
              trace_rd_wdata_i[lane], trace_trap_i[lane],
              trace_cause_i[lane], trace_tval_i[lane],
              trace_rd_write_i[lane] && !trace_rd_fp_i[lane],
              trace_rd_write_i[lane] && trace_rd_fp_i[lane],
              csr_valid[lane], csr_we[lane], csr_addr[lane], csr_wdata[lane],
              instruction_mnemonic(trace_instr_i[lane]));
          end
          $display("[COMMIT][%0t] order=%0d cycle=%0d lane=%0d pc=%08h instr=%08h rd_we=%b rd_fp=%b rd=%0d wdata=%08h trap=%b cause=%0d tval=%08h gpr_we=%b fpr_we=%b csr_valid=%b csr_we=%b csr_addr=%03h csr_wdata=%08h mnemonic=%s",
            $time, retire_order_q + ((lane == 1) && trace_valid_i[0]),
            cycle_q, lane, trace_pc_i[lane], trace_instr_i[lane],
            trace_rd_write_i[lane], trace_rd_fp_i[lane], trace_rd_i[lane],
            trace_rd_wdata_i[lane], trace_trap_i[lane],
            trace_cause_i[lane], trace_tval_i[lane],
            trace_rd_write_i[lane] && !trace_rd_fp_i[lane],
            trace_rd_write_i[lane] && trace_rd_fp_i[lane],
            csr_valid[lane], csr_we[lane], csr_addr[lane], csr_wdata[lane],
            instruction_mnemonic(trace_instr_i[lane]));
        end
      end
      if (|trace_valid_i) begin
        cycles_since_commit_q <= 0;
        last_commit_valid_q <= 1'b1;
        if (trace_valid_i[1]) begin
          last_commit_pc_q <= trace_pc_i[1];
          last_commit_instr_q <= trace_instr_i[1];
        end else begin
          last_commit_pc_q <= trace_pc_i[0];
          last_commit_instr_q <= trace_instr_i[0];
        end
      end else begin
        cycles_since_commit_q <= cycles_since_commit_q + 1'b1;
      end
      retire_order_q <= retire_order_q +
                        $unsigned(trace_valid_i[0]) +
                        $unsigned(trace_valid_i[1]);
      cycle_q <= cycle_q + 1'b1;
      // If the core stops retiring, periodically flush the last CSV records so
      // the file remains useful even before the simulation reaches timeout.
      if ((trace_fd != 0) && (cycle_q[9:0] == 10'b0))
        $fflush(trace_fd);
    end
  end

  final begin
    if (trace_fd != 0)
      $fclose(trace_fd);
  end

endmodule
