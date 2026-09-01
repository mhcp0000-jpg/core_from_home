module rv_axi_xbar_elab_smoke;
  logic clk;
  logic rst_n;

  rv_axi4_if #(.ID_WIDTH(4)) master0_axi (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(4)) master1_axi (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(4)) master2_axi (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave0_axi  (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave1_axi  (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave2_axi  (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave3_axi  (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave4_axi  (.clk_i(clk), .rst_ni(rst_n));
  rv_axi4_if #(.ID_WIDTH(6)) slave5_axi  (.clk_i(clk), .rst_ni(rst_n));

  rv_axi_xbar #(
    .LOCAL_ID_WIDTH (4),
    .XBAR_ID_WIDTH  (6)
  ) u_dut (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .m0_s   (master0_axi),
    .m1_s   (master1_axi),
    .m2_s   (master2_axi),
    .s0_m   (slave0_axi),
    .s1_m   (slave1_axi),
    .s2_m   (slave2_axi),
    .s3_m   (slave3_axi),
    .s4_m   (slave4_axi),
    .s5_m   (slave5_axi)
  );

  rv_axi_error_slave #(
    .ID_WIDTH (6)
  ) u_error_target (
    .clk_i  (clk),
    .rst_ni (rst_n),
    .axi_s  (slave5_axi)
  );

  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
  end
endmodule
