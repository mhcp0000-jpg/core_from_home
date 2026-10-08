// Explicit test-instance parameters; no command-line hardware overrides.
module rv_result_buffer32_tb;
  rv_exec_result_buffer_depth2_tb #(.XLEN(32)) u_check();
endmodule
module rv_result_buffer64_tb;
  rv_exec_result_buffer_depth2_tb #(.XLEN(64)) u_check();
endmodule
