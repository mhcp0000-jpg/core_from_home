module rv_c_expander #(
  parameter int unsigned XLEN = 32
) (
  input  logic [15:0] compressed_i,
  output logic [31:0] instruction_o,
  output logic        illegal_o
);

  function automatic logic [31:0] enc_i(
    input logic [11:0] imm,
    input logic [4:0]  rs1,
    input logic [2:0]  funct3,
    input logic [4:0]  rd,
    input logic [6:0]  opcode
  );
    return {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_r(
    input logic [6:0] funct7,
    input logic [4:0] rs2,
    input logic [4:0] rs1,
    input logic [2:0] funct3,
    input logic [4:0] rd,
    input logic [6:0] opcode
  );
    return {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_s(
    input logic [11:0] imm,
    input logic [4:0]  rs2,
    input logic [4:0]  rs1,
    input logic [2:0]  funct3,
    input logic [6:0]  opcode
  );
    return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
  endfunction

  function automatic logic [31:0] enc_b(
    input logic [12:0] imm,
    input logic [4:0]  rs2,
    input logic [4:0]  rs1,
    input logic [2:0]  funct3,
    input logic [6:0]  opcode
  );
    return {imm[12], imm[10:5], rs2, rs1, funct3,
            imm[4:1], imm[11], opcode};
  endfunction

  function automatic logic [31:0] enc_u(
    input logic [19:0] imm,
    input logic [4:0]  rd,
    input logic [6:0]  opcode
  );
    return {imm, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_j(
    input logic [20:0] imm,
    input logic [4:0]  rd,
    input logic [6:0]  opcode
  );
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
  endfunction

  logic [1:0] quadrant;
  logic [2:0] funct3;
  logic [4:0] rd_rs1;
  logic [4:0] rd_prime;
  logic [4:0] rs1_prime;
  logic [4:0] rs2_prime;
  logic [4:0] rs2;
  logic [11:0] imm12;
  logic [12:0] branch_imm;
  logic [20:0] jump_imm;

  always_comb begin
    quadrant = compressed_i[1:0];
    funct3 = compressed_i[15:13];
    rd_rs1 = compressed_i[11:7];
    rd_prime = {2'b01, compressed_i[4:2]};
    rs1_prime = {2'b01, compressed_i[9:7]};
    rs2_prime = {2'b01, compressed_i[4:2]};
    rs2 = compressed_i[6:2];
    imm12 = '0;
    branch_imm = '0;
    jump_imm = '0;
    instruction_o = 32'h0000_0013;
    illegal_o = 1'b0;

    case (quadrant)
      2'b00: begin
        case (funct3)
          3'b000: begin // C.ADDI4SPN
            imm12 = {2'b00, compressed_i[10:7], compressed_i[12:11],
                     compressed_i[5], compressed_i[6], 2'b00};
            instruction_o = enc_i(imm12, 5'd2, 3'b000, rd_prime, 7'b0010011);
            illegal_o = (imm12 == 0);
          end
          3'b010: begin // C.LW
            imm12 = {5'b0, compressed_i[5], compressed_i[12:10],
                     compressed_i[6], 2'b00};
            instruction_o = enc_i(imm12, rs1_prime, 3'b010, rd_prime,
                                    7'b0000011);
          end
          3'b011: begin // C.FLW (RV32) / C.LD (RV64)
            if (XLEN == 32) begin
              imm12 = {5'b0, compressed_i[5], compressed_i[12:10],
                       compressed_i[6], 2'b00};
              instruction_o = enc_i(imm12, rs1_prime, 3'b010, rd_prime,
                                      7'b0000111);
            end else begin
              imm12 = {4'b0, compressed_i[6:5], compressed_i[12:10],
                       3'b000};
              instruction_o = enc_i(imm12, rs1_prime, 3'b011, rd_prime,
                                      7'b0000011);
            end
          end
          3'b110: begin // C.SW
            imm12 = {5'b0, compressed_i[5], compressed_i[12:10],
                     compressed_i[6], 2'b00};
            instruction_o = enc_s(imm12, rs2_prime, rs1_prime, 3'b010,
                                    7'b0100011);
          end
          3'b111: begin // C.FSW (RV32) / C.SD (RV64)
            if (XLEN == 32) begin
              imm12 = {5'b0, compressed_i[5], compressed_i[12:10],
                       compressed_i[6], 2'b00};
              instruction_o = enc_s(imm12, rs2_prime, rs1_prime, 3'b010,
                                      7'b0100111);
            end else begin
              imm12 = {4'b0, compressed_i[6:5], compressed_i[12:10],
                       3'b000};
              instruction_o = enc_s(imm12, rs2_prime, rs1_prime, 3'b011,
                                      7'b0100011);
            end
          end
          default: illegal_o = 1'b1;
        endcase
      end

      2'b01: begin
        case (funct3)
          3'b000: begin // C.ADDI / C.NOP
            imm12 = {{6{compressed_i[12]}}, compressed_i[12], compressed_i[6:2]};
            instruction_o = enc_i(imm12, rd_rs1, 3'b000, rd_rs1, 7'b0010011);
          end
          3'b001: begin
            if (XLEN == 32) begin // C.JAL
              jump_imm = {{9{compressed_i[12]}}, compressed_i[12],
                          compressed_i[8], compressed_i[10:9],
                          compressed_i[6], compressed_i[7],
                          compressed_i[2], compressed_i[11],
                          compressed_i[5:3], 1'b0};
              instruction_o = enc_j(jump_imm, 5'd1, 7'b1101111);
            end else begin // C.ADDIW
              imm12 = {{6{compressed_i[12]}}, compressed_i[12], compressed_i[6:2]};
              instruction_o = enc_i(imm12, rd_rs1, 3'b000, rd_rs1,
                                      7'b0011011);
              illegal_o = (rd_rs1 == 0);
            end
          end
          3'b010: begin // C.LI
            imm12 = {{6{compressed_i[12]}}, compressed_i[12], compressed_i[6:2]};
            instruction_o = enc_i(imm12, 5'd0, 3'b000, rd_rs1, 7'b0010011);
            illegal_o = (rd_rs1 == 0);
          end
          3'b011: begin
            if (rd_rs1 == 5'd2) begin // C.ADDI16SP
              imm12 = {{2{compressed_i[12]}}, compressed_i[12],
                       compressed_i[4:3], compressed_i[5], compressed_i[2],
                       compressed_i[6], 4'b0000};
              instruction_o = enc_i(imm12, 5'd2, 3'b000, 5'd2, 7'b0010011);
              illegal_o = (imm12 == 0);
            end else begin // C.LUI
              instruction_o = enc_u({{14{compressed_i[12]}},
                                     compressed_i[12], compressed_i[6:2]},
                                    rd_rs1, 7'b0110111);
              illegal_o = (rd_rs1 == 0) || (rd_rs1 == 2) ||
                          ({compressed_i[12], compressed_i[6:2]} == 0);
            end
          end
          3'b100: begin
            case (compressed_i[11:10])
              2'b00: begin // C.SRLI
                imm12 = {6'b000000, compressed_i[12], compressed_i[6:2]};
                instruction_o = enc_i(imm12, rs1_prime, 3'b101, rs1_prime,
                                        7'b0010011);
                illegal_o = (XLEN == 32) && compressed_i[12];
              end
              2'b01: begin // C.SRAI
                imm12 = {6'b010000, compressed_i[12], compressed_i[6:2]};
                instruction_o = enc_i(imm12, rs1_prime, 3'b101, rs1_prime,
                                        7'b0010011);
                illegal_o = (XLEN == 32) && compressed_i[12];
              end
              2'b10: begin // C.ANDI
                imm12 = {{6{compressed_i[12]}}, compressed_i[12],
                         compressed_i[6:2]};
                instruction_o = enc_i(imm12, rs1_prime, 3'b111, rs1_prime,
                                        7'b0010011);
              end
              default: begin
                if (!compressed_i[12]) begin
                  case (compressed_i[6:5])
                    2'b00: instruction_o = enc_r(7'b0100000, rs2_prime,
                                                  rs1_prime, 3'b000, rs1_prime,
                                                  7'b0110011); // C.SUB
                    2'b01: instruction_o = enc_r(7'b0000000, rs2_prime,
                                                  rs1_prime, 3'b100, rs1_prime,
                                                  7'b0110011); // C.XOR
                    2'b10: instruction_o = enc_r(7'b0000000, rs2_prime,
                                                  rs1_prime, 3'b110, rs1_prime,
                                                  7'b0110011); // C.OR
                    default: instruction_o = enc_r(7'b0000000, rs2_prime,
                                                    rs1_prime, 3'b111, rs1_prime,
                                                    7'b0110011); // C.AND
                  endcase
                end else begin
                  case (compressed_i[6:5])
                    2'b00: instruction_o = enc_r(7'b0100000, rs2_prime,
                                                  rs1_prime, 3'b000, rs1_prime,
                                                  7'b0111011); // C.SUBW
                    2'b01: instruction_o = enc_r(7'b0000000, rs2_prime,
                                                  rs1_prime, 3'b000, rs1_prime,
                                                  7'b0111011); // C.ADDW
                    default: illegal_o = 1'b1;
                  endcase
                  if (XLEN != 64)
                    illegal_o = 1'b1;
                end
              end
            endcase
          end
          3'b101: begin // C.J
            jump_imm = {{9{compressed_i[12]}}, compressed_i[12],
                        compressed_i[8], compressed_i[10:9],
                        compressed_i[6], compressed_i[7], compressed_i[2],
                        compressed_i[11], compressed_i[5:3], 1'b0};
            instruction_o = enc_j(jump_imm, 5'd0, 7'b1101111);
          end
          3'b110, 3'b111: begin // C.BEQZ / C.BNEZ
            branch_imm = {{4{compressed_i[12]}}, compressed_i[12],
                          compressed_i[6:5], compressed_i[2],
                          compressed_i[11:10], compressed_i[4:3], 1'b0};
            instruction_o = enc_b(branch_imm, 5'd0, rs1_prime,
                                    (funct3 == 3'b110) ? 3'b000 : 3'b001,
                                    7'b1100011);
          end
          default: illegal_o = 1'b1;
        endcase
      end

      2'b10: begin
        case (funct3)
          3'b000: begin // C.SLLI
            imm12 = {6'b000000, compressed_i[12], compressed_i[6:2]};
            instruction_o = enc_i(imm12, rd_rs1, 3'b001, rd_rs1, 7'b0010011);
            illegal_o = (rd_rs1 == 0) || ((XLEN == 32) && compressed_i[12]);
          end
          3'b010: begin // C.LWSP
            imm12 = {4'b0, compressed_i[3:2], compressed_i[12],
                     compressed_i[6:4], 2'b00};
            instruction_o = enc_i(imm12, 5'd2, 3'b010, rd_rs1, 7'b0000011);
            illegal_o = (rd_rs1 == 0);
          end
          3'b011: begin // C.FLWSP (RV32) / C.LDSP (RV64)
            if (XLEN == 32) begin
              imm12 = {4'b0, compressed_i[3:2], compressed_i[12],
                       compressed_i[6:4], 2'b00};
              instruction_o = enc_i(imm12, 5'd2, 3'b010, rd_rs1,
                                      7'b0000111);
            end else begin
              imm12 = {3'b0, compressed_i[4:2], compressed_i[12],
                       compressed_i[6:5], 3'b000};
              instruction_o = enc_i(imm12, 5'd2, 3'b011, rd_rs1,
                                      7'b0000011);
              illegal_o = (rd_rs1 == 0);
            end
          end
          3'b100: begin
            if (!compressed_i[12]) begin
              if (rs2 == 0) begin // C.JR
                instruction_o = enc_i(12'b0, rd_rs1, 3'b000, 5'd0,
                                        7'b1100111);
                illegal_o = (rd_rs1 == 0);
              end else begin // C.MV
                instruction_o = enc_r(7'b0000000, rs2, 5'd0, 3'b000,
                                        rd_rs1, 7'b0110011);
                illegal_o = (rd_rs1 == 0);
              end
            end else begin
              if ((rd_rs1 == 0) && (rs2 == 0)) begin // C.EBREAK
                instruction_o = 32'h0010_0073;
              end else if (rs2 == 0) begin // C.JALR
                instruction_o = enc_i(12'b0, rd_rs1, 3'b000, 5'd1,
                                        7'b1100111);
                illegal_o = (rd_rs1 == 0);
              end else begin // C.ADD
                instruction_o = enc_r(7'b0000000, rs2, rd_rs1, 3'b000,
                                        rd_rs1, 7'b0110011);
                illegal_o = (rd_rs1 == 0);
              end
            end
          end
          3'b110: begin // C.SWSP
            imm12 = {4'b0, compressed_i[8:7], compressed_i[12:9], 2'b00};
            instruction_o = enc_s(imm12, rs2, 5'd2, 3'b010, 7'b0100011);
          end
          3'b111: begin // C.FSWSP (RV32) / C.SDSP (RV64)
            if (XLEN == 32) begin
              imm12 = {4'b0, compressed_i[8:7], compressed_i[12:9],
                       2'b00};
              instruction_o = enc_s(imm12, rs2, 5'd2, 3'b010,
                                      7'b0100111);
            end else begin
              imm12 = {3'b0, compressed_i[9:7], compressed_i[12:10],
                       3'b000};
              instruction_o = enc_s(imm12, rs2, 5'd2, 3'b011,
                                      7'b0100011);
            end
          end
          default: illegal_o = 1'b1;
        endcase
      end

      default: illegal_o = 1'b1;
    endcase
  end

  initial begin : p_parameter_checks
    if ((XLEN != 32) && (XLEN != 64))
      $fatal(1, "C expander XLEN must be 32 or 64");
  end

endmodule
