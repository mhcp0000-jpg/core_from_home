#!/usr/bin/env python3
"""Test the ACTUAL LSU validation adapter with the real FIFO and WB modules.

Explicit unit geometry: XLEN32/64, SEQ8, TAG7, WB11/INT2/FP2/COMPLETE4,
LSU_VALIDATION_PIPELINE=1. This is not a core elaboration override or timing
measurement. An injected missing-flush-qualifier regression must be detected.
The fixture checks older exactly-once transfer, younger kill, full [young,old]
compaction, flush-all, two older lanes under WB backpressure, and reset while
pending. Finite binary tests, not full ISA/IEEE-X proof.
"""
import argparse,hashlib,json,os,re,shutil,subprocess
from pathlib import Path

if not __debug__:
    raise RuntimeError('Validation assertions are required; do not use Python -O/PYTHONOPTIMIZE')
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest().upper()
def read(p):return Path(p).read_text(encoding='utf-8-sig')
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root',type=Path,default=Path(__file__).absolute().parent.parent)
parser.add_argument('--out',type=Path,required=True,help='New empty artifact directory; never overwrites a previous run')
parser.add_argument('--verilator',help='Verilator executable; PATH or known local Windows runtime otherwise')
parser.add_argument('--make',help='GNU make executable; PATH or known local Windows devkit otherwise')
parser.add_argument('--jobs',type=int,default=1)
args=parser.parse_args()
if not 1<=args.jobs<=32:parser.error('--jobs must be 1..32')
root=args.source_root.absolute();out=args.out.absolute()
if out.exists():raise FileExistsError('Choose a new --out; prior observations stay immutable')
if os.name=='nt' and not str(out).isascii():parser.error('Use run_lsu_validation_adapter_tests.ps1 for an owned ASCII drive alias')
def tool(requested,alternatives):
    for item in ([requested] if requested else alternatives):
        found=shutil.which(item)
        if found:return Path(found).absolute()
        if Path(item).is_file():return Path(item).absolute()
    parser.error('Required executable not found; pass its explicit path')
verilator=tool(args.verilator,['verilator_bin','verilator','C:/rv_toolchains/verilator-5.050/bin/verilator_bin.exe'])
make=tool(args.make,['make','C:/rv_toolchains/w64devkit-2.9.1/w64devkit/bin/make.exe'])
source_paths=('rtl/rv_ooo_pkg.sv','rtl/backend/rv_backend.sv','rtl/backend/rv_exec_result_buffer.sv','rtl/backend/rv_writeback_arbiter.sv')
source_bytes={path:(root/path).read_bytes() for path in source_paths}
source_sha={path:hashlib.sha256(data).hexdigest().upper() for path,data in source_bytes.items()}
backend=source_bytes['rtl/backend/rv_backend.sv'].decode('utf-8-sig').replace('\r\n','\n')
if not re.search(r'\bWB_SOURCES\s*=\s*11\s*;',backend):raise ValueError('Fixture expects the 11-source backend mapping')
if 'source_valid[5+lsu_source]=lsu_completion_valid[lsu_source];' not in backend:raise ValueError('LSU source mapping changed; update fixture deliberately')
for qualifier in ('validation_valid[src-5] && !flush_valid','wb_source_ready[SRC] && !flush_valid'):
    if backend.count(qualifier)!=1:raise ValueError('Expected corrected validation flush boundary is absent')
out.mkdir(parents=True)
env=os.environ.copy();env['PATH']=str(make.parent)+os.pathsep+env['PATH']
if (verilator.parent.parent/'include/verilated.h').is_file():env['VERILATOR_ROOT']=str(verilator.parent.parent)
report=dict(passed=False,scope=__doc__,sourceRoot=str(root),sources=source_sha,
            verilatorSha256=sha(verilator),makeSha256=sha(make),cases=[])
(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
for width,negative in ((32,False),(64,False),(32,True)):
    name='negative_omit_flush' if negative else 'candidate'
    declarations=backend[backend.index('  logic [WB_SOURCES-1:0] source_valid,source_ready,source_live,source_dst_valid;'):backend.index('  // What the writeback arbiter sees.')]
    first=backend.index('  typedef struct packed {',backend.index('  localparam int unsigned SKID_FIRST'))
    last=backend.index('  logic [3:0] complete_valid',first)
    wb_declarations=backend[first:last]
    first=backend.index('  always_comb begin\n    for (int unsigned src = 0; src < WB_SOURCES; src++) begin\n      raw_payload[src].sequence_id')
    last=backend.index('  // A presented result that the arbiter does not take',first)
    actual_adapter=backend[first:last]
    if negative:
        actual_adapter=actual_adapter.replace('validation_valid[src-5] && !flush_valid','validation_valid[src-5]',1)
        actual_adapter=actual_adapter.replace('wb_source_ready[SRC] && !flush_valid','wb_source_ready[SRC]',1)
    fixture=f'''module validation_flush_tb;
import rv_ooo_pkg::*;
localparam int XLEN={width},ROB_SEQ_WIDTH=8,PHYS_TAG_WIDTH=7,WB_SOURCES=11;
localparam int SKID_FIRST=2,SKID_LAST=9;
localparam bit LSU_VALIDATION_PIPELINE=1'b1;
logic clk_i=0,rst_ni=0;
always #5 clk_i=~clk_i;
logic flush_valid=0,flush_all=0;
logic [7:0] flush_sequence=20;
logic [1:0] inject=0;
logic block_wb=0;
logic [7:0] injected_sequence=10,injected_sequence1=30;
{declarations}
{wb_declarations}
assign skid_valid_q='0;
assign skid_q='0;
always_comb begin
  source_valid='0;source_sequence='0;source_dst_valid='0;
  source_dst_class='{{default:REG_NONE}};source_dst_phys='0;source_data='0;
  source_exception='0;source_exception_cause='{{default:EXC_ILLEGAL_INSTRUCTION}};
  source_exception_tval='0;source_mispredict='0;source_branch_target='0;source_fflags='0;
  for(int n=0;n<4;n++) begin source_valid[n]=block_wb;source_sequence[n]=8'(n);end
  source_valid[5]=inject[0] && !flush_valid;
  source_valid[6]=inject[1] && !flush_valid;
  source_sequence[5]=injected_sequence;source_sequence[6]=injected_sequence1;
  source_exception[5]=1;source_exception[6]=1;
  source_exception_cause[5]=EXC_LOAD_ACCESS_FAULT;
  source_exception_cause[6]=EXC_STORE_ACCESS_FAULT;
  source_exception_tval[5]=XLEN'('h80030000);source_exception_tval[6]=XLEN'('h80030004);
end
{actual_adapter}
logic [3:0] completed,completed_exception;
logic [3:0][7:0] completed_sequence;
exception_code_e [3:0] completed_cause;
logic [3:0][XLEN-1:0] completed_tval;
rv_writeback_arbiter #(.XLEN(XLEN),.SOURCE_COUNT(11),.ROB_SEQ_WIDTH(8),
 .PHYS_TAG_WIDTH(7),.INT_WRITE_PORTS(2),.FP_WRITE_PORTS(2),.ROB_COMPLETE_PORTS(4)) u_wb(
 .source_valid_i(wb_source_valid),.source_ready_o(wb_source_ready),.source_live_i('1),
 .source_sequence_i(wb_source_sequence),.source_destination_valid_i(wb_source_dst_valid),
 .source_destination_class_i(wb_source_dst_class),.source_destination_phys_i(wb_source_dst_phys),
 .source_data_i(wb_source_data),.source_exception_valid_i(wb_source_exception),
 .source_exception_cause_i(wb_source_exception_cause),.source_exception_tval_i(wb_source_exception_tval),
 .source_branch_mispredict_i(wb_source_mispredict),.source_branch_target_i(wb_source_branch_target),
 .source_fflags_i(wb_source_fflags),.flush_valid_i(flush_valid),.flush_all_i(flush_all),
 .flush_sequence_i(flush_sequence),.complete_valid_o(completed),
 .complete_sequence_o(completed_sequence),.complete_exception_valid_o(completed_exception),
 .complete_exception_cause_o(completed_cause),.complete_exception_tval_o(completed_tval));
int seen_old=0,seen_old1=0,seen_young=0;
task automatic step(input logic[1:0] request,input logic flushing,input logic all_kill,
 input logic holding,input logic[7:0] sequence_id,input logic[7:0] sequence1=30);
 @(negedge clk_i);
 inject=request;flush_valid=flushing;flush_all=all_kill;block_wb=holding;
 injected_sequence=sequence_id;injected_sequence1=sequence1;
 #1;
 for(int port=0;port<4;port++) if(completed[port]) begin
   if(completed_sequence[port]==10) begin
     seen_old++;
     if(seen_old>1) $fatal(1,"duplicate older validation completion");
     if(!completed_exception[port] || completed_cause[port]!=EXC_LOAD_ACCESS_FAULT ||
        completed_tval[port]!=XLEN'('h80030000)) $fatal(1,"older validation payload lost");
   end
   if(completed_sequence[port]==11) begin
     seen_old1++;
     if(seen_old1>1) $fatal(1,"duplicate second older validation completion");
     if(!completed_exception[port] || completed_cause[port]!=EXC_STORE_ACCESS_FAULT ||
        completed_tval[port]!=XLEN'('h80030004)) $fatal(1,"second older validation payload lost");
   end
   if(completed_sequence[port]==30) seen_young++;
 end
 @(posedge clk_i);#1;
endtask
task automatic reset_model();
 @(negedge clk_i);rst_ni=0;inject=0;flush_valid=0;flush_all=0;block_wb=0;
 repeat(2) @(negedge clk_i);
 rst_ni=1;seen_old=0;seen_old1=0;seen_young=0;
endtask
initial begin
 reset_model();
 // Older resident head survives, younger lane is killed. A flush edge must
 // not consume the survivor because the FIFO itself does not pop on flush.
 step(2'b11,0,0,0,10);
 step(0,1,0,0,10);
 step(0,0,0,0,10);
 step(0,0,0,0,10);
 if(seen_old!=1 || seen_young!=0) $fatal(1,"flush survivor transfer count wrong");
 reset_model();
 // Full FIFO in issue order [young,old], blocked by four older WB sources.
 // Selective flush must compact the older second entry, not drop it.
 step(1,0,0,1,30);
 step(1,0,0,1,10);
 step(0,1,0,0,10);
 step(0,0,0,0,10);
 step(0,0,0,0,10);
 if(seen_old!=1 || seen_young!=0) $fatal(1,"full flush compaction wrong");
 reset_model();
 step(2'b11,0,0,1,10);
 step(0,1,1,0,10);
 step(0,0,0,0,10);
 if(seen_old!=0 || seen_young!=0) $fatal(1,"flush-all leaked completion");
 reset_model();
 // Two LSU lanes hold distinct older faults through prolonged WB pressure.
 // Releasing WB on the selective-flush edge must not consume either entry.
 step(2'b11,0,0,1,10,11);
 repeat(8) step(0,0,0,1,10,11);
 if(seen_old!=0 || seen_old1!=0) $fatal(1,"WB backpressure leaked completion");
 step(0,1,0,0,10,11);
 step(0,0,0,0,10,11);
 step(0,0,0,0,10,11);
 if(seen_old!=1 || seen_old1!=1 || seen_young!=0)
   $fatal(1,"two-lane older survivor transfer count wrong");
 reset_model();
 step(2'b11,0,0,1,10,11);
 reset_model();
 step(0,0,0,0,10,11);
 step(0,0,0,0,10,11);
 if(seen_old!=0 || seen_old1!=0 || seen_young!=0)
   $fatal(1,"reset leaked pending validation completion");
 $display("PASS actual validation adapter flush XLEN=%0d older exactly once/younger killed/full compaction/flush-all/two older lanes/reset",XLEN);
 $finish;
end
endmodule
'''
    folder=out/f'{name}_x{width}';folder.mkdir(exist_ok=True)
    for path,dest in (('rtl/rv_ooo_pkg.sv','pkg.sv'),('rtl/backend/rv_exec_result_buffer.sv','buffer.sv'),('rtl/backend/rv_writeback_arbiter.sv','wb.sv')):
        (folder/dest).write_bytes(source_bytes[path])
    (folder/'fixture.sv').write_text(fixture,encoding='utf-8')
    with (folder/'compile.log').open('w',encoding='utf-8') as log:
        gen=subprocess.run([str(verilator),'--cc','--exe','--main','--timing','--assert','-Wno-fatal','-Werror-UNOPTFLAT','--top-module','validation_flush_tb','--Mdir','obj','pkg.sv','buffer.sv','wb.sv','fixture.sv'],cwd=folder,env=env,stdout=log,stderr=subprocess.STDOUT)
    assert gen.returncode==0,'Fixture generation failed, NOT a detected RTL counterexample'
    with (folder/'build.log').open('w',encoding='utf-8') as log:
        build=subprocess.run([str(make),'-j',str(args.jobs),'-C','obj','-f','Vvalidation_flush_tb.mk','CXX=g++','CC=gcc','LINK=g++','VM_PARALLEL_BUILDS=1'],cwd=folder,env=env,stdout=log,stderr=subprocess.STDOUT)
    assert build.returncode==0,'Fixture build failed, NOT a detected RTL counterexample'
    with (folder/'result.log').open('w',encoding='utf-8') as log:
        executable='Vvalidation_flush_tb.exe' if os.name=='nt' else 'Vvalidation_flush_tb'
        native=subprocess.run([str(folder/'obj'/executable)],cwd=folder,env=env,stdout=log,stderr=subprocess.STDOUT)
    result=read(folder/'result.log')
    passed=(native.returncode!=0 and 'duplicate older validation completion' in result) if negative else (native.returncode==0 and 'PASS actual validation adapter flush' in result)
    report['cases'].append(dict(name=name,width=width,negative=negative,passed=passed,nativeExit=native.returncode,compileExit=gen.returncode,buildExit=build.returncode,
                               backendSha256=source_sha['rtl/backend/rv_backend.sv'],fixtures={f:sha(folder/f) for f in ('pkg.sv','buffer.sv','wb.sv','fixture.sv')}))
    (out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(f'validation adapter {name} x{width} negative={negative} exit={native.returncode} passed={passed}',flush=True)
    assert passed
report['sourceUnchangedAtEnd']=all(sha(root/path)==binding for path,binding in source_sha.items())
report['passed']=report['sourceUnchangedAtEnd']
(out/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
if not report['passed']:raise SystemExit('Source changed during the run; inspect frozen fixture evidence')
print('PASS actual adapter32/64 + injected missing-flush regression; not whole-core ISA/timing proof',flush=True)
