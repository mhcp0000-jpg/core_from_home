#!/usr/bin/env python3
"""Generate beginner-facing module block/timing diagrams and HDD walkthroughs.

The generated SVG files are intentionally simple: data travels left-to-right,
control/state is shown top-to-bottom, and every wire is orthogonal and thick.
Run this script whenever a module interface or latency contract changes.
"""

from __future__ import annotations

from dataclasses import dataclass
from html import escape
from pathlib import Path
import re
import textwrap


ROOT = Path(__file__).resolve().parents[1]
HDD = ROOT / "docs" / "HDD_Core_Architecture.md"
OUT = ROOT / "docs" / "diagrams" / "modules"
BEGIN = "<!-- BEGIN GENERATED MODULE WALKTHROUGHS -->"
END = "<!-- END GENERATED MODULE WALKTHROUGHS -->"


@dataclass(frozen=True)
class ModuleDoc:
    name: str
    group: str
    source: str
    purpose: str
    inputs: str
    stages: tuple[str, str, str]
    outputs: str
    timing: str
    throughput: str
    hold: str
    steps: tuple[str, str, str]
    corners: str


def m(name, group, source, purpose, inputs, stages, outputs, timing,
      throughput, hold, steps, corners):
    return ModuleDoc(name, group, source, purpose, inputs, stages, outputs,
                     timing, throughput, hold, steps, corners)


MODULES = [
    m("rv_soc_top", "A. Top-level integration", "rtl/soc/rv_soc_top.sv",
      "Core, local TIM/peripheral fabric, AXI bridges와 Main Xbar를 하나의 합성 SoC로 연결한다.",
      "clock/reset; external IRQ; Host AXI M2",
      ("주소/용량 parameter 전달", "Core I/D path와 Xbar 결선", "CLINT/PLIC/HostIF IRQ 결합"),
      "Host AXI response; commit trace; HostIF event",
      "고정 단일 latency가 없는 wiring top이다. 각 child의 handshake latency가 합산된다.",
      "Core는 최대 I 1건과 D 2건/cycle을 제안하고, Host는 AXI burst를 제안할 수 있다.",
      "reset 동안 Core request를 차단하며 child backpressure를 그대로 전달한다.",
      ("reset과 address-map parameter를 모든 child에 동일하게 전달한다.",
       "Core local hit는 fabric에서 처리하고 miss는 bridge를 거쳐 Main Xbar로 보낸다.",
       "target response와 IRQ를 원래 Core/Host port로 되돌린다."),
      "잘못된 map은 elaboration fatal, unmapped access는 DECERR다. Debug halt는 현재 0에 고정된다."),
    m("rv_ooo_core", "A. Top-level integration", "rtl/rv_ooo_core.sv",
      "Frontend와 OoO backend를 묶고 IFU PMP 및 외부 I/D memory 경계를 제공한다.",
      "I-memory response; D-memory response; IRQ/mtime; redirect state",
      ("Frontend fetch/align", "IFU parcel PMP 검사", "Backend execute/commit"),
      "I/D request; dual retire trace; privilege/PMP",
      "명령 latency는 memory와 execution unit에 따라 가변이며 retire는 최대 2개/cycle이다.",
      "fetch/decode/dispatch/issue/commit baseline이 모두 2-wide다.",
      "redirect는 fetch epoch를 바꾸고, D response는 LSQ identity/tombstone으로 보호한다.",
      ("Frontend가 16-byte block을 받아 최대 두 instruction을 만든다.",
       "PMP fault metadata와 instruction을 backend에 prefix handshake로 전달한다.",
       "backend redirect/retire 결과를 frontend와 외부 trace에 연결한다."),
      "stale fetch/load response, exception과 interrupt의 precise boundary가 핵심이다."),
    m("rv_backend", "A. Top-level integration", "rtl/backend/rv_backend.sv",
      "decode부터 rename, OoO scheduling, execute, WB, ROB commit과 trap까지 소유한다.",
      "2-wide fetch bundle; dual D-memory; IRQ; predictor metadata",
      ("Decode/Rename/ROB/IQ", "P0~P3 fall-through, P4 registered", "11 sources → combinational WB4 / commit2"),
      "redirect; D-memory traffic; retire trace; predictor update",
      "ALU 명령도 여러 pipeline edge를 거쳐 retire하며 DIV/memory/flush에 따라 가변이다.",
      "global issue 최대 2 uop/cycle, completion 최대 4, retire 최대 2 instruction/cycle이다.",
      "어느 resource라도 부족하면 dispatch bundle 전체를 hold한다.",
      ("decode 결과가 모든 resource ready일 때 원자적으로 rename/allocate된다.",
       "IQ가 oldest-ready 두 uop을 실행 port에 보내고 결과를 WB arbitration한다.",
       "ROB head만 commit하며 exception/interrupt/branch가 recovery를 요청한다."),
      "same-bundle RAW/WAW, selective flush, serializing CSR/FENCE와 device memory가 교차한다."),
    m("rv_frontend", "B. Frontend", "rtl/frontend/rv_frontend.sv",
      "예측 PC에서 fetch block을 요청하고 C/32-bit 경계를 정렬해 backend에 공급한다.",
      "I-memory response; backend ready/redirect; predictor resolve/commit",
      ("next-PC/predictor query", "outstanding fetch와 target buffer", "64-byte fetch queue/align"),
      "I-memory request; 2-wide raw instruction와 prediction",
      "target-buffer hit는 memory wait 없이 queue fill 가능하고, miss는 I-memory latency에 따른다.",
      "backend가 소비하면 최대 두 instruction/cycle을 낸다. memory outstanding은 1 block이다.",
      "queue full 또는 outstanding request가 있으면 request를 hold하며 redirect가 최우선이다.",
      ("현재 PC로 predictor와 target buffer를 조회한다.",
       "필요한 16-byte block을 요청하거나 target-buffer data를 queue에 넣는다.",
       "C 길이를 판정해 taken lane 뒤 younger lane을 막고 backend로 보낸다."),
      "cross-block 32-bit instruction, stale epoch response, redirect-cycle target fill이 핵심이다."),
    m("rv_lsu_cluster", "A. Top-level integration", "rtl/backend/rv_lsu_cluster.sv",
      "두 AGU, LSQ, committed store buffer와 D-memory arbitration을 하나의 memory execution cluster로 묶는다.",
      "dual memory issue; ROB commit; PMP; dual D response",
      ("AGU/PMP update", "LQ/SQ ordering/forwarding", "load·SB·device request arbitration"),
      "5 completion sources; dual D request; memory-idle",
      "AGU update는 1 registered stage, load는 forwarding 또는 memory latency, store는 commit 뒤 response까지 가변이다.",
      "최대 두 AGU update/cycle과 두 D request/cycle이나 bank/device 제약이 적용된다.",
      "lane별 fall-through request buffer가 valid&&!ready payload를 고정한다.",
      ("dispatch 때 LQ/SQ entry를 ROB와 동시에 예약한다.",
       "AGU가 주소/data를 만들고 LSQ가 older store를 검사한다.",
       "load result 또는 committed store response를 해당 ROB sequence로 완료한다."),
      "unknown older store, same-bank conflict, flushed load tombstone, device-store fault를 다룬다."),

    m("rv_fetch_queue", "B. Frontend", "rtl/frontend/rv_fetch_queue.sv",
      "16-byte fetch block들을 byte queue로 보관하고 C/32-bit instruction 두 개를 정렬한다.",
      "block data/address/fault; consume count; flush",
      ("fill address 정렬/skip", "64-byte data+fault FIFO", "16/32-bit boundary 추출"),
      "2-wide PC/raw/length/fault; free-space",
      "fill edge 뒤 저장 byte가 보이며 consume과 compatible fill은 같은 edge에 처리된다.",
      "공간과 instruction boundary가 허용하면 최대 2 instruction/cycle이다.",
      "공간 부족 시 fill을 거부하고 backend stall 시 head/data를 유지한다.",
      ("block 주소와 queue tail 사이의 byte offset을 계산한다.",
       "유효 byte와 parcel fault bit를 FIFO에 기록한다.",
       "head에서 길이를 읽고 소비된 byte만 pointer/count에서 제거한다."),
      "queue wrap, halfword 끝의 32-bit instruction, redirect flush를 검사해야 한다."),
    m("rv_fetch_target_buffer", "B. Frontend", "rtl/frontend/rv_fetch_target_buffer.sv",
      "최근 predicted-taken target의 16-byte block을 보관해 redirect 재요청 latency를 없앤다.",
      "lookup address; fill block; invalidate",
      ("direct-map index", "tag+valid+block array", "hit compare/data mux"),
      "lookup hit와 block data",
      "lookup은 조합, fill/invalidate는 clock edge에서 반영된다.",
      "매 cycle 한 lookup, 한 fill을 처리한다.",
      "FENCE.I/PMP redirect invalidate가 fill보다 우선한다.",
      ("target block 주소로 index/tag를 만든다.",
       "valid tag가 맞으면 저장 block을 frontend에 즉시 반환한다.",
       "memory response 또는 replay block을 해당 entry에 채운다."),
      "alias tag, 같은 cycle invalidate/fill, wrong-path block 재사용을 막아야 한다."),
    m("rv_branch_predictor", "B. Frontend", "rtl/frontend/rv_branch_predictor.sv",
      "BTB, tournament direction predictor와 RAS로 두 fetch lane의 next PC를 예측한다.",
      "2 PC/raw instruction; resolve; in-order commit; redirect restore",
      ("BTB 64 sets × 4 ways", "bimodal/gshare/chooser", "speculative+committed GHR/RAS"),
      "lane별 taken/target/prediction metadata",
      "query는 조합이며 prediction fire/resolve/commit update는 edge에서 반영된다.",
      "두 lane query/cycle, resolve 한 건, commit 최대 두 건/cycle이다.",
      "reset/architectural redirect가 speculative history를 복구하며 update payload를 보존한다.",
      ("PC로 BTB와 세 PHT를 병렬 조회한다.",
       "instruction 종류와 RAS를 결합해 taken/target을 결정한다.",
       "resolve에서 학습하고 mispredict면 저장 metadata로 speculative history를 복구한다."),
      "compressed raw encoding, 두 lane history 순서, RAS under/overflow가 중요하다."),
    m("rv_c_expander", "B. Frontend", "rtl/frontend/rv_c_expander.sv",
      "16-bit C instruction을 backend가 사용하는 canonical 32-bit instruction으로 확장한다.",
      "16-bit compressed instruction; XLEN mode",
      ("quadrant decode", "register/immediate 재배치", "reserved/illegal 판정"),
      "32-bit instruction와 illegal",
      "순수 조합 경로로 cycle state가 없다.",
      "입력이 바뀔 때마다 한 결과를 만든다.",
      "backpressure는 상위 decode가 소유한다.",
      ("quadrant와 funct field로 instruction class를 찾는다.",
       "compressed register와 immediate를 RV I/F encoding으로 재배치한다.",
       "reserved encoding이면 illegal을 함께 출력한다."),
      "RV32/RV64 shared encoding 차이와 zero/reserved immediate를 확인한다."),

    m("rv_decode2", "C. Rename and scheduling", "rtl/backend/rv_decode2.sv",
      "두 raw instruction을 실행 가능한 uop control과 immediate로 해석한다.",
      "2-wide PC/raw/length/fetch fault; ISA enable parameter",
      ("C expansion", "opcode/funct decode", "source/destination/FU/exception 생성"),
      "2-wide decoded uop bundle",
      "순수 조합 decode이며 등록은 rename/ROB accept edge에서 일어난다.",
      "최대 두 instruction/cycle이다.",
      "downstream resource stall이면 입력 bundle이 상위에서 유지된다.",
      ("16-bit이면 canonical instruction으로 확장한다.",
       "operand class, immediate, FU와 memory/CSR 속성을 만든다.",
       "unsupported/reserved encoding을 drop하지 않고 exception uop로 표시한다."),
      "lane0 illegal이어도 lane1 순서는 유지되고 trap 때 younger가 제거된다."),
    m("rv_rename2", "C. Rename and scheduling", "rtl/backend/rv_rename2.sv",
      "architectural INT/FP register를 physical tag로 바꾸고 WAR/WAW false dependency를 제거한다.",
      "2-wide source/destination; commit; checkpoint restore/release",
      ("RAT/RRAT lookup", "8-bit group free-list encoder", "same-pair bypass/checkpoint"),
      "physical source/new destination/stale tag; resource ready",
      "rename 결과는 조합으로 계산되고 dispatch fire edge에서 RAT/free-list가 갱신된다.",
      "자원이 충분하면 최대 두 instruction/cycle이다.",
      "한 lane이라도 필요한 tag/checkpoint가 부족하면 bundle 전체를 수락하지 않는다.",
      ("두 lane source의 현재 RAT mapping을 읽는다.",
       "lane 순서로 새 destination tag를 예약하고 RAW/WAW bypass를 적용한다.",
       "dispatch edge에서 RAT/free-list/checkpoint를 원자적으로 갱신한다."),
      "lane1 RAW/WAW, x0 no-allocation, commit과 recovery 동시 우선순위가 핵심이다."),
    m("rv_phys_regfile", "C. Rename and scheduling", "rtl/backend/rv_phys_regfile.sv",
      "renamed INT 또는 FP operand 값과 ready 상태를 저장한다.",
      "read/query tag; allocate-not-ready; dual writeback",
      ("data array", "ready bitmap", "same-cycle write bypass"),
      "read data/ready와 query ready",
      "read는 조합, allocate/write는 edge에서 반영되며 write bypass는 같은 cycle wakeup을 돕는다.",
      "instance마다 최대 8 read, 6 ready query, 2 write, 2 allocate/cycle이다.",
      "writeback이 막히면 producer가 payload를 유지하고 allocate tag는 not-ready가 된다.",
      ("rename이 새 tag를 allocate해 ready bit를 내린다.",
       "IQ가 tag로 data/ready를 조회한다.",
       "WB edge에서 data와 ready를 기록하고 dependent IQ를 깨운다."),
      "x0 hardwire, 같은 tag allocate/write, dual write collision을 금지한다."),
    m("rv_rob", "C. Rename and scheduling", "rtl/backend/rv_rob.sv",
      "OoO 완료 결과를 program order로 정렬해 precise dual commit을 만드는 48-entry circular buffer다.",
      "allocate2; completion4; retire ready; selective/full flush",
      ("head/tail/count", "entry metadata+complete+exception", "sequence CAM completion/retire prefix"),
      "head2 retire bundle; trap head; occupancy",
      "allocate/complete는 edge에서 기록되고 다음 조합 phase에 retire 가능해진다.",
      "최대 2 allocate, 4 completion update, 2 in-order retire/cycle이다.",
      "head incomplete/exception/side-effect not-ready면 younger complete entry도 기다린다.",
      ("dispatch가 tail부터 lane0, lane1 entry와 sequence를 예약한다.",
       "WB가 sequence로 entry를 찾아 complete/exception/branch metadata를 기록한다.",
       "head부터 정상 complete prefix만 commit하고 stale mapping을 반환한다."),
      "wrap age, completion+flush, lane0 exception+lane1 complete, dual store commit을 다룬다."),
    m("rv_issue_queue", "C. Rename and scheduling", "rtl/backend/rv_issue_queue.sv",
      "renamed uop과 source-ready 상태를 보관하고 oldest-ready 실행 후보를 찾는다.",
      "dispatch uop; PRF/WB wakeup; flush; candidate accept",
      ("56-entry unified payload", "ready scoreboard + WB bypass", "oldest select → port registers"),
      "두 candidate와 occupancy",
      "WB는 ready를 edge에서 저장하며 tag-match bypass로 같은 cycle candidate에도 참여한다.",
      "최대 두 dispatch와 두 accepted issue/cycle이다.",
      "candidate는 실행 port가 accept하기 전 제거되지 않는다.",
      ("dispatch uop과 physical source tags를 빈 entry에 쓴다.",
       "WB tag가 일치하면 source ready를 세운다.",
       "모든 source와 target FU가 ready인 oldest entry를 candidate로 낸다."),
      "store address/data split phase, same-cycle wakeup/select, selective flush를 처리한다."),
    m("rv_issue_arbiter", "C. Rename and scheduling", "rtl/backend/rv_issue_arbiter.sv",
      "IQ 후보와 실행 port mask를 비교해 global 최대 두 grant를 만든다.",
      "candidate payload/age/port mask; 5 port ready",
      ("oldest candidate 선택", "첫 grant port 배정", "충돌 제거 후 둘째 grant"),
      "candidate accept와 port별 valid/index",
      "순수 조합 경로이며 grant는 같은 edge의 issue handshake에 사용된다.",
      "전체 실행 cluster 합산 최대 두 uop/cycle이다.",
      "port ready가 아니면 candidate를 accept하지 않는다.",
      ("각 candidate가 사용할 수 있는 ready port mask를 만든다.",
       "oldest 요청에 첫 port를 주고 해당 entry/port를 제외한다.",
       "남은 후보 중 oldest compatible 요청에 두 번째 port를 준다."),
      "같은 entry/port 이중 grant와 younger가 older를 부당하게 추월하는 경우를 금지한다."),

    m("rv_int_alu", "D. Execute and writeback", "rtl/backend/rv_int_alu.sv",
      "RV32/RV64 integer arithmetic, logical, shift와 compare 결과를 계산한다.",
      "operation; operands; word-operation",
      ("adder/compare", "logic/shift", "result select/word sign-extension"),
      "XLEN result",
      "순수 조합 실행이며 뒤의 result buffer가 1 registered stage를 제공한다.",
      "ALU instance당 한 operation/cycle이다.",
      "stall identity는 뒤 result buffer가 보존한다.",
      ("operation으로 필요한 arithmetic/logic 결과를 병렬 계산한다.",
       "shift amount와 signed/unsigned compare를 XLEN 규칙으로 선택한다.",
       "RV64 W-op이면 32-bit 결과를 sign-extend한다."),
      "shift width, signed compare, overflow를 trap으로 오해하지 않는 것이 중요하다."),
    m("rv_branch_unit", "D. Execute and writeback", "rtl/backend/rv_branch_unit.sv",
      "branch/JAL/JALR의 실제 taken과 target을 계산하고 prediction과 비교한다.",
      "PC/raw/length; operands/immediate; prediction metadata",
      ("condition compare", "PC/indirect target 계산", "taken/target mispredict compare"),
      "actual taken/target, mispredict, misaligned",
      "순수 조합 실행 후 fast result buffer에서 등록된다.",
      "한 branch operation/cycle이다.",
      "downstream stall 시 result buffer가 resolve identity를 유지한다.",
      ("branch 종류에 맞게 operands를 비교한다.",
       "PC-relative 또는 JALR target을 계산하고 IALIGN을 확인한다.",
       "예측 taken/target과 달라지면 recovery request를 만든다."),
      "C raw encoding, JALR bit0 clear, target misalignment와 wrong-path training을 확인한다."),
    m("rv_multiplier", "D. Execute and writeback", "rtl/backend/rv_multiplier.sv",
      "MUL/MULH 계열과 RV64 W 결과를 2-stage elastic pipeline으로 계산한다.",
      "valid/ready; operands/operation; ROB sequence/destination",
      ("stage0 product/select", "stage1 result register", "result handshake"),
      "result/tag/sequence valid-ready",
      "accept edge를 C0라 하면 no-stall result valid는 두 번째 pipeline edge 뒤 보인다.",
      "pipeline이 흐르면 한 multiply/cycle을 받을 수 있다.",
      "result stall이 stage1→stage0→request ready로 역전파되고 payload는 고정된다.",
      ("signedness 조합에 맞게 full product를 계산해 stage0에 넣는다.",
       "다음 edge에 low/high 또는 W 결과를 stage1로 이동한다.",
       "WB가 accept할 때 결과 entry를 비우며 killed sequence는 flush한다."),
      "MULH signedness, back-to-back full pipe, selective flush와 wrap sequence를 검사한다."),
    m("rv_divider", "D. Execute and writeback", "rtl/backend/rv_divider.sv",
      "DIV/DIVU/REM/REMU를 한 bit/cycle restoring 방식으로 수행한다.",
      "request operands/op/sequence; result ready; flush",
      ("special-case detect", "busy iterative quotient/remainder", "held result register"),
      "result/tag/sequence valid-ready",
      "divide-by-zero와 signed overflow는 accept 직후 result valid, 일반 RV32는 32 iteration으로 약 33 cycle issue→visible이다.",
      "non-pipelined라 이전 result가 소비된 뒤 다음 요청 한 건을 받는다.",
      "busy/result-valid 동안 request ready=0이고 result stall 시 payload를 유지한다.",
      ("accept 때 부호와 절댓값, iteration 수를 저장한다.",
       "매 cycle dividend bit 하나를 내려 quotient/remainder를 갱신한다.",
       "마지막 iteration에서 부호/W-op를 적용해 result register를 valid로 만든다."),
      "0 divisor, INT_MIN/-1, flush 중 busy/result, RV64 W 32-iteration을 처리한다."),
    m("rv_fpu", "D. Execute and writeback", "rtl/backend/rv_fpu.sv",
      "RV32F arithmetic/FMA/divsqrt/convert/compare/move 결과와 fflags를 계산한다.",
      "operation/rm/frm; three operands; sequence/destination; flush",
      ("fast bit-level execute", "3-stage elastic pipe", "iterative FDIV88/FSQRT64"),
      "FP/INT result, fflags, exception identity",
      "fast는 LATENCY=3, finite FDIV/FSQRT는 약 89/65 edge 뒤 result valid가 된다.",
      "stall이 없으면 한 FP operation/cycle을 받을 수 있다.",
      "마지막 stage stall이 전 stage ready와 request ready로 전파된다.",
      ("rm/frm과 operand bits로 canonical RV32F result/fflags를 계산한다.",
       "payload를 3-stage elastic pipeline으로 이동한다.",
       "WB가 결과를 ROB/PRF에 보내고 fflags는 retire 때만 FCSR에 누적한다."),
      "NaN/sNaN, signed zero, subnormal, rounding, flush된 fflags를 다룬다."),
    m("rv_exec_result_buffer", "D. Execute and writeback", "rtl/backend/rv_exec_result_buffer.sv",
      "조합 ALU/branch 결과에 sequence identity와 backpressure를 보존하는 1-entry register를 제공한다.",
      "request payload valid-ready; result ready; flush",
      ("request capture", "1-entry valid+payload", "result stable/kill check"),
      "completion payload valid-ready",
      "request accept 다음 cycle에 result valid가 보이는 1 registered stage다.",
      "result가 매 cycle 소비되면 한 request/cycle이다.",
      "valid&&!ready 동안 모든 payload를 고정하고 killed sequence는 handshake 없이 제거한다.",
      ("실행 결과와 ROB/destination/exception metadata를 한 payload로 묶는다.",
       "빈 entry 또는 동시 consume이면 새 payload를 capture한다.",
       "WB accept 시 비우고 flush boundary보다 younger면 즉시 invalidate한다."),
      "consume+refill, result stall, selective/full flush 동시 조건이 핵심이다."),
    m("rv_writeback_arbiter", "D. Execute and writeback", "rtl/backend/rv_writeback_arbiter.sv",
      "11개 completion source 중 ROB/PRF port 제약을 만족하는 최대 4개를 선택한다.",
      "source valid/payload; INT/FP write 요구; ROB live query",
      ("stale source filter", "age/port compatible select", "source-ready와 WB bundle 생성"),
      "4 completion; INT2/FP2 write; source ready",
      "조합 grant이며 LSQ candidate와 execution-port register가 장거리 경로를 분할한다.",
      "최대 completion 4개, INT write 2개, FP write 2개/cycle이다.",
      "선택되지 않은 stateful producer는 result valid/payload를 유지한다.",
      ("ROB live와 sequence를 확인해 stale completion을 걸러낸다.",
       "oldest/port-compatible source를 completion slot에 배치한다.",
       "PRF write, IQ wakeup과 ROB complete에 동일 grant를 fanout한다."),
      "동일 destination collision, killed result, write-port 포화와 exception completion을 확인한다."),
    m("rv_branch_recovery", "D. Execute and writeback", "rtl/backend/rv_branch_recovery.sv",
      "여러 branch resolve 중 recovery를 소유할 oldest mispredict를 선택한다.",
      "resolve candidates와 sequence/target",
      ("mispredict filter", "wrap-aware oldest compare", "flush boundary/redirect select"),
      "selective flush와 redirect",
      "순수 조합이며 선택된 recovery가 같은 cycle control fanout에 사용된다.",
      "cycle당 recovery 한 건이다.",
      "architectural trap/return redirect가 상위 priority에서 branch redirect를 막는다.",
      ("valid mispredict 후보만 남긴다.",
       "ROB sequence age로 가장 오래된 후보를 선택한다.",
       "그 branch sequence를 flush boundary, actual target을 redirect PC로 낸다."),
      "두 동시 mispredict, sequence wrap, trap과 branch 동시 발생을 다룬다."),

    m("rv_lsu_pipe", "E. Load/store subsystem", "rtl/backend/rv_lsu_pipe.sv",
      "base+immediate 주소, byte mask와 aligned store data를 만드는 1-stage AGU다.",
      "memory issue payload; LQ/SQ identity; flush",
      ("effective address", "alignment/mask/data shift", "registered LSQ update"),
      "address/data update 또는 misaligned exception",
      "issue accept 다음 cycle에 update valid가 보인다.",
      "lane마다 한 update/cycle이며 두 instance가 병렬 동작한다.",
      "update stall 시 payload 고정, flush cycle에는 새 issue를 받지 않는다.",
      ("base와 immediate로 effective/physical address를 만든다.",
       "size/alignment를 검사하고 beat mask와 shifted data를 만든다.",
       "LQ/SQ index와 함께 registered update로 전달한다."),
      "unsupported size, beat boundary, store address-only/data-only phase와 flush를 다룬다."),
    m("rv_lsq_order_check", "E. Load/store subsystem", "rtl/backend/rv_lsq_order_check.sv",
      "한 load와 모든 older SQ entry를 비교해 stall 또는 forwarding source를 결정한다.",
      "load address/mask/sequence; SQ valid/address/data/mask/sequence",
      ("older/younger age compare", "unknown/overlap/full-cover 검사", "youngest older forwarding select"),
      "issue permit, forward valid/data/index, stall reason",
      "순수 조합 검사로 SQ/LQ registered 상태를 같은 scheduler cycle에 판정한다.",
      "검사 port마다 한 load candidate/cycle이다.",
      "unknown address/data나 partial overlap이면 memory issue를 보수적으로 막는다.",
      ("load보다 older인 valid store만 후보로 남긴다.",
       "미확정 주소 또는 부분 overlap이 있으면 stall reason을 만든다.",
       "full-cover 후보 중 load에 가장 가까운 youngest older store를 선택한다."),
      "sequence wrap, 여러 same-address store, byte mask partial overlap을 확인한다."),
    m("rv_lsq", "E. Load/store subsystem", "rtl/backend/rv_lsq.sv",
      "speculative load와 store의 주소/data/완료 상태를 ROB sequence와 함께 추적한다.",
      "dispatch2; AGU update2; load response; commit2; flush",
      ("LQ24/SQ16 arrays", "registered load candidate", "ordering/forward + tombstone recovery"),
      "load issue/forward; SQ→SB/direct store; occupancy",
      "dispatch/AGU update는 edge에서 반영되고 다음 scheduler cycle에 issue/forward 후보가 된다.",
      "최대 LQ/SQ allocate2, update2, commit2 및 load candidate2/cycle이다.",
      "unknown older store와 partial overlap에서 load를 hold하며 outstanding killed LQ는 tombstone 유지다.",
      ("ROB dispatch와 같은 edge에 LQ/SQ entry와 sequence를 예약한다.",
       "AGU update 뒤 모든 older store를 검사해 memory/forward/stall을 결정한다.",
       "load response 또는 store commit에서 entry를 완료/해제하고 flush younger를 제거한다."),
      "same-cycle store→load, flushed outstanding response, device serialization과 dual commit을 처리한다."),
    m("rv_store_buffer", "E. Load/store subsystem", "rtl/backend/rv_store_buffer.sv",
      "ROB에서 commit된 normal store를 memory response까지 보관하는 16-entry FIFO다.",
      "dual committed enqueue; dual drain ready/response; forwarding query",
      ("committed FIFO", "bank-aware drain issue", "response tracking/machine-check"),
      "dual D-memory store; forwarding data; empty/full",
      "enqueue 후 drain은 fabric ready와 response latency에 따라 가변이다.",
      "공간이 있으면 두 commit store enqueue, 서로 다른 bank면 두 drain/cycle 가능하다.",
      "memory가 막히면 issued entry와 request payload를 유지하며 branch flush는 적용하지 않는다.",
      ("ROB commit lane 순서로 store를 FIFO에 넣는다.",
       "oldest eligible entry를 bank별 D request로 보낸다.",
       "response ID로 entry를 제거하고 error면 sticky machine-check를 기록한다."),
      "dual enqueue 공간, same-bank drain, younger load forwarding, response error를 다룬다."),

    m("rv_csr_file", "F. Privilege, trap and protection", "rtl/backend/rv_csr_file.sv",
      "M/U privilege, machine CSR, counters, FCSR와 PMP configuration의 architectural owner다.",
      "head CSR evaluate/commit; trap/MRET/WFI; IRQ/mtime; fflags",
      ("CSR read/WARL/RMW", "pending transaction", "commit/trap privilege state"),
      "CSR result/illegal; trap vector; privilege/PMP/interrupt state",
      "CSR evaluate payload는 먼저 capture되고 동일 ROB instruction commit edge에서만 side effect가 생긴다.",
      "serializing 정책으로 한 CSR/system transaction만 진행한다.",
      "trap이 MRET보다, MRET이 CSR commit보다 우선하며 flush가 pending CSR을 취소한다.",
      ("ROB head CSR의 old value와 write intent/value를 평가한다.",
       "pending register에 주소/data를 고정하고 결과를 ROB에 완료한다.",
       "정상 retire edge에서만 CSR/PMP/FCSR를 변경한다."),
      "CSRRS/RC x0 suppression, WARL, nested trap overwrite, counter/fflags order를 다룬다."),
    m("rv_pmp", "F. Privilege, trap and protection", "rtl/backend/rv_pmp.sv",
      "OFF/TOR/NA4/NAPOT entry를 priority 순서로 검사해 R/W/X 권한을 판정한다.",
      "주소/size/access type/privilege/MPRV; pmpcfg/pmpaddr",
      ("shared entry range predecode", "lowest-index first-match", "containment/permission check"),
      "allow/fault와 fault address",
      "순수 조합 판정으로 IFU parcel 및 dual AGU 앞에 놓인다.",
      "CHECK_PORTS parameter 수만큼 병렬 access/cycle이다.",
      "state는 CSR file이 소유하며 PMP module 자체 backpressure는 없다.",
      ("각 entry의 address mode로 lower/upper range를 계산한다.",
       "접근 일부라도 처음 matching entry와 겹치면 그 entry를 선택한다.",
       "전체 접근 포함 여부와 R/W/X, privilege/lock 규칙으로 allow를 결정한다."),
      "partial first-match, M unlocked bypass, locked entry와 2-byte IFU parcel 경계를 확인한다."),
    m("rv_trap_controller", "F. Privilege, trap and protection", "rtl/backend/rv_trap_controller.sv",
      "precise exception/interrupt와 MRET/WFI/FENCE/PMP post-commit redirect 순서를 정한다.",
      "ROB head trap/empty; pending IRQ; retire events; CSR vector/MRET PC",
      ("exception>interrupt selection", "architectural next-PC", "pending redirect/WFI sleep"),
      "CSR trap request; architectural redirect; WFI state",
      "head exception은 즉시 trap handshake, post-commit redirect는 한 cycle pending 후 실행된다.",
      "동시에 architectural redirect 한 건만 허용한다.",
      "기존 pending redirect가 trap을 한 cycle 막고 interrupt는 ROB empty에서만 accept한다.",
      ("동기 exception이 있으면 pending interrupt보다 먼저 선택한다.",
       "CSR에 precise PC/cause/tval을 전달하고 mtvec으로 redirect한다.",
       "MRET/FENCE.I/PMP write/WFI retire 뒤 next PC redirect 또는 sleep을 관리한다."),
      "exception+interrupt, trap-in-trap, WFI wake, dual-retire next-PC를 다룬다."),
    m("rv_fence_controller", "F. Privilege, trap and protection", "rtl/backend/rv_fence_controller.sv",
      "FENCE/FENCE.I가 older memory를 drain한 뒤 안전하게 완료되도록 판정한다.",
      "head fence metadata; LSU idle; I-fabric idle; next PC",
      ("pred/succ 분류", "memory-idle gate", "completion/redirect request"),
      "completion sequence와 frontend flush 정보",
      "순수 조합이며 idle 조건이 성립한 scheduler cycle에 completion을 제안한다.",
      "serializing head fence 한 건이다.",
      "LSQ/SB 또는 required I path가 busy이면 completion을 내지 않는다.",
      ("head instruction에서 FENCE/FENCE.I와 mask를 읽는다.",
       "요구된 predecessor operation이 모두 끝났는지 확인한다.",
       "완료 sequence와 FENCE.I next-PC refetch 정보를 반환한다."),
      "committed store drain, outstanding load, FENCE.I target-buffer/epoch invalidate를 확인한다."),

    m("rv_local_to_axi_bridge", "G. SoC fabric and memory", "rtl/soc/rv_local_to_axi_bridge.sv",
      "Core local request 한 건을 AXI4 single-beat transaction으로 변환한다.",
      "local valid payload; AXI ready/response; watchdog parameter",
      ("request capture/alignment", "AR 또는 AW+W handshake", "R/B response 또는 timeout drain"),
      "AXI master channels; local response",
      "정상 latency는 target AXI latency, 무응답은 기본 4096-cycle watchdog으로 종료한다.",
      "read 한 건과 write 한 건 중 bridge state가 허용하는 local outstanding 한 건이다.",
      "각 AXI channel valid&&!ready payload를 고정하며 partial-accepted timeout은 drain한다.",
      ("local request와 ID/committed/device를 capture한다.",
       "read는 AR, write는 독립 AW/W handshake를 완료한다.",
       "R/B를 local response로 바꾸거나 timeout SLVERR 뒤 late response를 폐기한다."),
      "AW/W 다른 cycle accept, bad ID/RLAST, timeout 전후 side-effect ambiguity를 다룬다."),
    m("rv_axi_to_local_bridge", "G. SoC fabric and memory", "rtl/soc/rv_axi_to_local_bridge.sv",
      "Host/Xbar AXI burst를 local request sequence로 분해한다.",
      "AXI slave channels; local ready/response; target windows",
      ("whole-burst precheck", "beat address/data sequencer", "R beat 또는 merged B response"),
      "local requester; AXI R/B",
      "local beat마다 response를 기다리므로 burst latency는 beat 수×local latency+backpressure다.",
      "한 read 또는 write burst를 처리하고 local outstanding은 한 beat다.",
      "AW가 AR보다 우선하며 R/B stall 시 AXI payload와 beat index를 유지한다.",
      ("INCR/size/alignment/window/4-KiB 경계를 transaction 전에 검사한다.",
       "유효하면 beat 하나씩 local request를 보내고 response를 모은다.",
       "read는 각 R beat, write는 최종 merged B response를 반환한다."),
      "window/4-KiB crossing은 local side effect 0, WLAST 오류와 narrow strobe를 처리한다."),
    m("rv_axi_xbar", "G. SoC fabric and memory", "rtl/soc/rv_axi_xbar.sv",
      "세 AXI initiator를 여섯 target으로 decode/arbitrate하고 ID prefix로 response를 복귀시킨다.",
      "M0 I, M1 D, M2 Host AXI; S0..S5 response",
      ("whole-burst target decode", "target별 round-robin AR/AW", "W owner lock와 ID-prefix return"),
      "S0 I-local, S1 D-local, PLIC, HostIF, error targets",
      "address route는 handshake cycle에 결정되고 전체 latency는 arbitration+target response다.",
      "master별 read 1/write 1 outstanding, target별 AR/AW arbitration이다.",
      "AW accept부터 WLAST까지 target W owner를 고정하고 stalled channel payload를 보존한다.",
      ("첫/마지막 byte를 decode해 한 target과 4-KiB 안에 드는지 검사한다.",
       "각 target에서 round-robin으로 한 AR/AW owner를 선택한다.",
       "downstream ID 상위 prefix로 B/R을 원 master에 반환한다."),
      "동시 AR/AW, bad response prefix, unmapped/unsupported burst와 fairness를 다룬다."),
    m("rv_axi_error_slave", "G. SoC fabric and memory", "rtl/soc/rv_axi_error_slave.sv",
      "unmapped/unsupported AXI transaction을 hang 없이 deterministic DECERR로 끝낸다.",
      "AXI AW/W/AR과 B/R ready",
      ("AW/AR capture", "write W drain 또는 read beat count", "zero+DECERR response"),
      "AXI B 또는 R beats",
      "address accept 뒤 state machine이 response를 만들며 read는 LEN+1 beat를 반환한다.",
      "한 transaction at a time이며 AW와 AR 동시면 AW 우선이다.",
      "R/B stall 동안 ID/data/resp/last를 유지한다.",
      ("AW 또는 AR metadata를 capture한다.",
       "write는 WLAST까지 data를 버리고 read는 beat count를 증가시킨다.",
       "B 또는 zero-data R에 DECERR를 실어 종료한다."),
      "malformed WLAST에서도 protocol state가 영구 대기하지 않도록 검증해야 한다."),
    m("rv_i_fabric", "G. SoC fabric and memory", "rtl/soc/rv_i_fabric.sv",
      "Core IFU와 Xbar inbound 요청을 Boot ROM/2-bank ITIM 또는 outbound AXI로 중재한다.",
      "128-bit IF request; 64-bit inbound local request; local/AXI responses",
      ("BootROM/ITIM/outbound decode", "bank/requester arbitration", "128-bit response assemble/buffer"),
      "IF response; inbound response; outbound local request",
      "ITIM은 synchronous bank read를 조립하고 outbound는 AXI latency에 따른다.",
      "Core fetch block 1건과 inbound access가 bank conflict가 없을 때 병행 가능하다.",
      "response buffer 또는 bank conflict가 requester ready로 역전파된다.",
      ("주소가 Boot ROM/ITIM/local 밖인지 decode한다.",
       "필요한 bank read와 inbound 요청을 공정하게 grant한다.",
       "bank data를 fetch block으로 조립하거나 outbound response를 원 requester에 반환한다."),
      "Core fetch와 Host ITIM write 경쟁, BootROM inbound read, response handoff를 다룬다."),
    m("rv_d_fabric", "G. SoC fabric and memory", "rtl/soc/rv_d_fabric.sv",
      "LSU0/LSU1과 Xbar inbound를 2-bank DTIM/CLINT 또는 outbound AXI로 중재한다.",
      "세 local initiator; DTIM/CLINT/AXI responses",
      ("DTIM/CLINT/outbound decode", "bank별 1R1W age arbitration", "lane별 response buffer/handoff"),
      "세 local responses; outbound request; CLINT IRQ/time",
      "DTIM synchronous read와 response handoff, CLINT/AXI target latency에 따라 가변이다.",
      "서로 다른 bank는 두 LSU가 병행하며 inbound Host가 세 번째 경쟁자가 된다.",
      "same-bank loser는 ready=0으로 payload를 유지하고 old response+next request handoff를 지원한다.",
      ("각 요청 주소를 DTIM, CLINT 또는 outbound로 분류한다.",
       "bank/target별 age로 grant하고 request identity를 저장한다.",
       "response를 원 lane/Host inbound에 돌려주고 다음 요청을 같은 edge에 받을 수 있다."),
      "same-bank dual load/store, Host race, old response ID와 next metadata 분리를 다룬다."),
    m("rv_sram_1r1w", "G. SoC fabric and memory", "rtl/soc/rv_sram_1r1w.sv",
      "한 read port와 한 byte-strobe write port를 가진 합성 가능한 synchronous SRAM wrapper다.",
      "read enable/address; write enable/address/data/strobe",
      ("memory array", "write-strobe merge", "registered read-valid/data"),
      "read valid/data",
      "read enable edge 다음 cycle에 read_valid/data가 보인다.",
      "매 cycle read 1건과 write 1건을 동시에 받을 수 있다.",
      "memory array는 reset-clear하지 않고 read output register만 reset한다.",
      ("read/write address와 byte strobe를 받는다.",
       "write bytes를 기존 word와 merge해 memory에 기록한다.",
       "동일 주소 read/write면 merge된 new data를 read output에 등록한다."),
      "same-row write-first policy와 미초기화 memory content가 ASIC macro와 일치해야 한다."),
    m("rv_tim_2bank", "G. SoC fabric and memory", "rtl/soc/rv_tim_2bank.sv",
      "주소 bit로 두 개의 64-bit 1R1W SRAM bank를 interleave한다.",
      "bank별 read/write enable/address/data/strobe",
      ("bank/address mapping", "SRAM bank0", "SRAM bank1"),
      "bank별 registered read response",
      "각 bank read는 1-cycle synchronous latency다.",
      "서로 다른 bank에서 read2/write2, bank마다 read1+write1/cycle이다.",
      "same-bank 추가 arbitration은 I/D fabric이 수행한다.",
      ("beat address의 interleave bit로 bank를 선택한다.",
       "bank-local row address를 생성해 SRAM instance에 보낸다.",
       "두 bank read-valid/data를 fabric에 독립 반환한다."),
      "bank 선택 bit, odd/even row, same-bank read/write policy를 확인한다."),
    m("rv_clint", "G. SoC fabric and memory", "rtl/soc/rv_clint.sv",
      "single-hart MSIP, MTIMECMP와 MTIME register를 제공한다.",
      "local bus request; clock/reset",
      ("address/size decode", "msip/mtimecmp/mtime state", "read/write response"),
      "local response; software/timer IRQ; mtime",
      "local request handshake 뒤 register response를 반환하며 mtime은 매 cycle 증가한다.",
      "single local transaction path다.",
      "invalid size/address는 오류 response이며 reset이 IRQ state를 지운다.",
      ("offset과 narrow access를 decode한다.",
       "write strobe로 MSIP/MTIMECMP/MTIME word를 갱신한다.",
       "mtime>=mtimecmp와 msip bit로 IRQ를 생성한다."),
      "RV32 high/low word access, compare update 중 transient IRQ와 reset 값을 다룬다."),
    m("rv_plic_local", "G. SoC fabric and memory", "rtl/soc/rv_plic.sv",
      "PLIC priority/pending/enable/claim-complete를 local bus register로 구현한다.",
      "local request; external source vector",
      ("source gateway/pending", "M/S context arbitration", "register read/write/claim"),
      "local response; MEIP/SEIP",
      "request와 source sampling은 edge에서 상태에 반영되고 response는 local handshake로 전달된다.",
      "한 MMIO transaction path와 source별 pending sampling이다.",
      "claim read는 선택 pending을 atomic clear하며 in-service source는 재claim하지 않는다.",
      ("source level을 pending gateway에 capture한다.",
       "priority>threshold인 enabled 최고 priority source를 선택한다.",
       "claim read/complete write로 pending/in-service를 변경한다."),
      "priority tie는 낮은 ID, source0 reserved, M/S context 독립 enable을 확인한다."),
    m("rv_plic", "G. SoC fabric and memory", "rtl/soc/rv_plic.sv",
      "AXI4 single-beat access를 local PLIC register transaction으로 감싼 wrapper다.",
      "AXI slave channels; source vector",
      ("AXI-to-local bridge", "rv_plic_local", "AXI response return"),
      "AXI B/R; MEIP/SEIP",
      "AXI bridge latency와 local PLIC response가 합산된다.",
      "MMIO burst 최대 1 beat다.",
      "invalid burst는 PLIC state를 건드리지 않고 오류 response를 낸다.",
      ("AXI transaction을 single local request로 변환한다.",
       "PLIC local register/gateway 동작을 수행한다.",
       "local response를 원 AXI ID의 B/R로 반환한다."),
      "narrow/alignment, claim side effect와 AXI retry를 주의한다."),
    m("rv_bootrom_local", "G. SoC fabric and memory", "rtl/soc/rv_bootrom.sv",
      "reset/WFI/MSIP boot code image를 read-only local memory로 제공한다.",
      "local read request; INIT_FILE",
      ("address/window check", "ROM word array", "registered response/error"),
      "local read data/response",
      "read request 뒤 ROM response가 등록되어 반환된다.",
      "한 local read transaction/cycle 조건이다.",
      "write는 side effect 없이 오류이며 ROM array는 reset이 아니라 readmemh로 초기화된다.",
      ("주소가 ROM window와 정렬에 맞는지 확인한다.",
       "해당 word를 image array에서 읽는다.",
       "read data 또는 write/범위 오류 response를 반환한다."),
      "잘못된 INIT_FILE, window 끝, Host write 시도를 다룬다."),
    m("rv_bootrom", "G. SoC fabric and memory", "rtl/soc/rv_bootrom.sv",
      "AXI access 가능한 Boot ROM wrapper다.",
      "AXI slave; ROM image parameter",
      ("AXI-to-local burst bridge", "rv_bootrom_local", "R/B response"),
      "AXI response",
      "AXI beat sequencer와 ROM read latency가 합산된다.",
      "한 burst, local beat 한 건씩이다.",
      "write와 invalid burst는 ROM side effect 없이 error다.",
      ("AXI burst 전체 범위를 사전 검사한다.",
       "각 read beat를 local ROM 요청으로 바꾼다.",
       "ROM response를 ID/RLAST가 있는 AXI R로 반환한다."),
      "SoC top은 이 wrapper 대신 I-fabric 내부 local leaf를 사용한다."),
    m("rv_hostif_local", "G. SoC fabric and memory", "rtl/soc/rv_hostif.sv",
      "simulation/FPGA host용 console, exit와 boot mailbox MMIO register를 제공한다.",
      "local MMIO request; event ready",
      ("register decode", "boot/event state", "event valid-ready/output response"),
      "local response; event kind/data; boot entry/flags",
      "MMIO handshake와 event backpressure에 따라 완료 latency가 달라진다.",
      "한 local transaction과 한 pending event를 유지한다.",
      "event_valid&&!ready 동안 kind/data를 고정한다.",
      ("주소/size/write strobe로 HostIF register를 decode한다.",
       "console/exit write를 event payload로 capture한다.",
       "host가 event를 accept하면 pending을 지우고 MMIO response를 완료한다."),
      "event backpressure, partial write, HostIF와 DTIM HTIF 주소를 혼동하지 않아야 한다."),
    m("rv_hostif", "G. SoC fabric and memory", "rtl/soc/rv_hostif.sv",
      "AXI4 HostIF target wrapper다.",
      "AXI slave; event ready",
      ("AXI-to-local bridge", "rv_hostif_local", "AXI response/event"),
      "AXI B/R; event; boot fields",
      "AXI bridge와 event handshake latency가 합산된다.",
      "MMIO burst 최대 1 beat다.",
      "invalid burst는 event를 만들지 않고 오류로 끝난다.",
      ("AXI request를 local MMIO request로 바꾼다.",
       "HostIF register/event 동작을 수행한다.",
       "local response를 원 AXI ID로 반환한다."),
      "console event 재전송과 write response 순서를 확인한다."),
    m("rv_soc_addr_decode", "G. SoC fabric and memory", "rtl/soc/rv_soc_addr_decode.sv",
      "parameterized memory map 주소를 I-local, D-local, PLIC, HostIF 또는 error target으로 분류한다.",
      "32-bit address와 region base/size parameter",
      ("half-open range compares", "group target select", "default error"),
      "soc_target_e",
      "순수 조합 decode다.",
      "주소 한 개당 즉시 한 target을 낸다.",
      "overlap 방지는 별도 map checker가 보장한다.",
      ("각 base<=addr<end를 병렬 비교한다.",
       "BootROM/ITIM과 DTIM/CLINT를 local target으로 묶는다.",
       "일치가 없으면 default error target을 선택한다."),
      "region 끝의 half-open 경계와 size overflow가 중요하다."),
    m("rv_soc_map_check", "G. SoC fabric and memory", "rtl/soc/rv_soc_map_check.sv",
      "잘못된 base/size/alignment/overlap configuration을 time 0에 중단한다.",
      "모든 memory-map parameter",
      ("size/alignment 검사", "32-bit overflow 검사", "pairwise overlap 검사"),
      "없음; 위반 시 elaboration fatal",
      "runtime datapath가 아니라 elaboration/time-zero 검사다.",
      "configuration당 한 번 실행된다.",
      "backpressure/flush 개념이 없다.",
      ("각 region size가 nonzero이고 요구 alignment인지 검사한다.",
       "base+size가 address width를 넘지 않는지 계산한다.",
       "모든 region pair가 겹치지 않는지 확인하고 위반 시 fatal한다."),
      "새 external SRAM region을 추가하면 반드시 overlap pair에 포함해야 한다."),
]


def wrap_lines(text: str, width: int) -> list[str]:
    return textwrap.wrap(text, width=width, break_long_words=False,
                         break_on_hyphens=False) or [""]


def svg_text_block(x: int, y: int, lines: list[str], css: str,
                   step: int = 24) -> str:
    spans = []
    for index, line in enumerate(lines):
        dy = 0 if index == 0 else step
        spans.append(f'<tspan x="{x}" dy="{dy}">{escape(line)}</tspan>')
    return f'<text x="{x}" y="{y}" class="{css}">' + "".join(spans) + "</text>"


def module_svg(d: ModuleDoc) -> str:
    input_lines = wrap_lines(d.inputs, 28)
    output_lines = wrap_lines(d.outputs, 28)
    timing_lines = wrap_lines("Latency: " + d.timing, 102)
    throughput_lines = wrap_lines("Throughput: " + d.throughput, 102)
    hold_lines = wrap_lines("Stall/flush: " + d.hold, 102)
    timing_content = timing_lines + throughput_lines + hold_lines
    svg_height = max(620, 520 + 24 * len(timing_content))
    timing_height = svg_height - 454
    stage_y = (180, 246, 312)
    stage_parts = []
    for y, stage in zip(stage_y, d.stages):
        stage_parts.append(f'<rect x="390" y="{y}" width="500" height="54" class="stage"/>')
        stage_parts.append(svg_text_block(410, y + 33, wrap_lines(stage, 54), "stage-text", 20))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="{svg_height}" viewBox="0 0 1280 {svg_height}" role="img" aria-labelledby="title desc">
<title id="title">{escape(d.name)} block diagram</title>
<desc id="desc">{escape(d.purpose)} Inputs flow left to right through three internal functions to outputs. Timing contract is shown below.</desc>
<defs><marker id="arrow" markerWidth="12" markerHeight="12" refX="10" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 Z" class="arrow-head"/></marker></defs>
<style>
  .bg {{ fill:#f8fafc; }} .panel {{ fill:#ffffff; stroke:#334155; stroke-width:3; }}
  .core {{ fill:#eff6ff; stroke:#2563eb; stroke-width:4; }} .stage {{ fill:#ffffff; stroke:#2563eb; stroke-width:2.5; }}
  .timing {{ fill:#f0fdf4; stroke:#15803d; stroke-width:3; }} .wire {{ fill:none; stroke:#0f766e; stroke-width:5; marker-end:url(#arrow); }}
  .arrow-head {{ fill:#0f766e; }} text {{ font-family:'Noto Sans KR','Malgun Gothic',Arial,sans-serif; fill:#0f172a; }}
  .title {{ font-size:32px; font-weight:700; }} .subtitle {{ font-size:17px; fill:#475569; }}
  .label {{ font-size:20px; font-weight:700; }} .body {{ font-size:17px; }} .stage-text {{ font-size:18px; font-weight:600; }}
  .timing-text {{ font-size:16px; }}
  @media (prefers-color-scheme:dark) {{ .bg{{fill:#0f172a}} .panel{{fill:#111827;stroke:#94a3b8}} .core{{fill:#172554;stroke:#60a5fa}} .stage{{fill:#111827;stroke:#60a5fa}} .timing{{fill:#052e16;stroke:#4ade80}} text{{fill:#e5e7eb}} .subtitle{{fill:#cbd5e1}} .wire{{stroke:#5eead4}} .arrow-head{{fill:#5eead4}} }}
</style>
<rect width="1280" height="{svg_height}" class="bg"/>
<text x="40" y="48" class="title">{escape(d.name)}</text>
<text x="40" y="78" class="subtitle">{escape(d.group)} · {escape(d.source)}</text>
{svg_text_block(40, 105, wrap_lines(d.purpose, 72), "subtitle", 23)}
<rect x="40" y="146" width="270" height="218" rx="8" class="panel"/>
<text x="60" y="180" class="label">Inputs / events</text>
{svg_text_block(60, 218, input_lines, "body", 25)}
<rect x="370" y="126" width="540" height="258" rx="10" class="core"/>
<text x="390" y="158" class="label">Internal flow / state</text>
{''.join(stage_parts)}
<rect x="970" y="146" width="270" height="218" rx="8" class="panel"/>
<text x="990" y="180" class="label">Outputs / effects</text>
{svg_text_block(990, 218, output_lines, "body", 25)}
<path d="M310 255 H350 V255 H370" class="wire"/>
<path d="M910 255 H950 V255 H970" class="wire"/>
<rect x="40" y="414" width="1200" height="{timing_height}" rx="8" class="timing"/>
<text x="60" y="448" class="label">Timing contract</text>
{svg_text_block(60, 480, timing_content, "timing-text", 24)}
</svg>'''


TIMELINES = [
    ("instruction-lifecycle", "한 ALU 명령의 기본 lifecycle", "각 cell은 해당 cycle의 주 동작이며 실제 stall이 있으면 뒤 단계가 늘어난다.",
     ["C0", "C1", "C2", "C3", "C4", "C5"],
     [("Frontend", ["fetch/align", "decode 전달", "—", "—", "—", "—"]),
      ("Rename/ROB", ["—", "tag+ROB allocate", "ROB wait", "ROB wait", "complete", "retire"]),
      ("Issue", ["—", "IQ insert", "oldest-ready grant", "—", "—", "—"]),
      ("Execute", ["—", "—", "ALU calculate", "result buffer", "—", "—"]),
      ("WB/PRF", ["—", "—", "—", "WB grant", "PRF ready", "—"]),
      ("Commit", ["—", "—", "—", "—", "head check", "RRAT+trace"])]),
    ("rob-div-add-timing", "ROB OoO 완료와 in-order dual commit", "younger ADD가 먼저 완료돼도 older DIV가 끝나기 전에는 commit하지 못한다.",
     ["C0", "C1", "C2", "C3…C32", "C33", "C34"],
     [("DIV seq40", ["allocate", "issue", "busy", "iterate", "WB complete", "commit L0"]),
      ("ADD seq41", ["allocate", "issue", "WB complete", "ROB wait", "complete", "commit L1"]),
      ("ROB head", ["seq40", "seq40", "seq40 incomplete", "seq40 incomplete", "both complete", "head+=2"]),
      ("Architectural", ["no change", "no change", "ADD not visible", "ADD not visible", "no change", "x5 then x6"])]),
    ("rename-pair-timing", "동일 bundle RAW/WAW rename", "lane1은 lane0이 만든 working RAT을 보므로 같은 cycle dependency도 physical tag로 정확히 연결된다.",
     ["before", "comb", "accept edge", "next cycle"],
     [("lane0", ["RAT[x5]=p7", "ADD x5→p40", "RAT[x5]=p40", "producer in IQ"]),
      ("lane1 RAW", ["src x5", "src=p40 bypass", "consumer stored", "wait p40"]),
      ("lane1 WAW", ["dst x5", "new=p41 stale=p40", "RAT[x5]=p41", "p40 freed at L1 commit"]),
      ("free-list", ["p40,p41 free", "reserve both", "both allocated", "no partial state"])]),
    ("branch-recovery-timing", "Branch mispredict selective recovery", "resolving branch와 older state는 살리고 younger state와 이전 fetch epoch만 제거한다.",
     ["C0", "C1", "C2", "C3", "C4"],
     [("Branch seq50", ["issue", "resolve wrong", "ROB complete", "wait/commit", "committed"]),
      ("Younger seq51+", ["spec execute", "flush selected", "ROB/IQ/LSQ kill", "absent", "absent"]),
      ("Rename", ["checkpoint live", "restore request", "RAT/free restored", "new rename", "continue"]),
      ("Frontend", ["old epoch", "redirect target", "drop stale rsp", "target fetch", "new instructions"])]),
    ("lsq-forwarding-timing", "Store-to-load forwarding", "load는 모든 older store 주소를 확인하고 youngest full-cover store data만 사용한다.",
     ["C0", "C1", "C2", "C3", "C4"],
     [("Store seq60", ["SQ allocate", "AGU address", "SQ addr/data ready", "still speculative", "commit→SB"]),
      ("Load seq61", ["LQ allocate", "AGU address", "order check", "forward complete", "ROB complete"]),
      ("D-memory read", ["none", "none", "blocked until check", "none: forwarded", "none"]),
      ("Visibility", ["no write", "no write", "no write", "no write", "SB may write"])]),
    ("trap-interrupt-timing", "Precise exception과 interrupt 경계", "동기 exception은 ROB head에서 우선하고 interrupt는 ROB가 비어 architectural boundary가 된 뒤 수락한다.",
     ["C0", "C1", "C2", "C3", "C4", "C5"],
     [("ROB", ["older retire", "fault at head", "flush all", "empty", "handler fetch", "handler run"]),
      ("Interrupt", ["pending", "pending but loses", "still pending", "MIE cleared", "masked", "software policy"]),
      ("CSR", ["unchanged", "trap handshake", "mepc/cause/tval", "M-mode", "handler state", "save context"]),
      ("Frontend", ["normal", "stop", "redirect mtvec", "request handler", "response", "decode handler"])]),
    ("axi-burst-timing", "AXI inbound burst와 오류 선검사", "target/window/4-KiB 검사는 첫 local beat 전에 끝나므로 invalid burst는 partial write를 만들지 않는다.",
     ["C0", "C1", "C2", "C3", "C4", "C5"],
     [("AXI AR/AW", ["valid", "handshake+precheck", "—", "—", "—", "—"]),
      ("valid burst", ["—", "beat0 req", "beat0 rsp", "beat1 req", "beat1 rsp", "RLast/B"]),
      ("invalid burst", ["—", "route error", "DECERR beat0", "DECERR beat1", "done", "—"]),
      ("local side effect", ["0", "valid: req / invalid:0", "valid only", "valid only", "valid only", "0"])]),
    ("dual-bank-timing", "Dual LSU와 2-bank 1R1W TIM", "서로 다른 bank 요청은 병렬이고 같은 bank 요청은 older one만 grant되어 younger가 payload를 유지한다.",
     ["C0", "C1", "C2", "C3"],
     [("different banks", ["LSU0 B0 + LSU1 B1", "both grant", "both read rsp", "both complete"]),
      ("same bank LSU0", ["older B0", "grant", "read rsp", "complete"]),
      ("same bank LSU1", ["younger B0", "ready=0 hold", "retry grant", "read rsp"]),
      ("payload rule", ["stable", "stable while stalled", "accepted", "identity preserved"])]),
]


def timeline_svg(slug, title, caption, cycles, rows):
    width = 1640
    left = 230
    top = 150
    cell_w = (width - left - 40) // len(cycles)
    cell_h = 74
    height = top + cell_h * len(rows) + 110
    parts = [f'''<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">
<title id="title">{escape(title)}</title><desc id="desc">{escape(caption)}</desc>
<style>
 .bg{{fill:#f8fafc}} .grid{{fill:#fff;stroke:#64748b;stroke-width:2}} .active{{fill:#dbeafe;stroke:#2563eb;stroke-width:2.5}}
 text{{font-family:'Noto Sans KR','Malgun Gothic',Arial,sans-serif;fill:#0f172a}} .title{{font-size:32px;font-weight:700}} .caption{{font-size:17px;fill:#475569}}
 .head{{font-size:18px;font-weight:700}} .label{{font-size:18px;font-weight:700}} .cell{{font-size:15px}}
 @media(prefers-color-scheme:dark){{.bg{{fill:#0f172a}} .grid{{fill:#111827;stroke:#94a3b8}} .active{{fill:#172554;stroke:#60a5fa}} text{{fill:#e5e7eb}} .caption{{fill:#cbd5e1}}}}
</style><rect width="{width}" height="{height}" class="bg"/>
<text x="40" y="48" class="title">{escape(title)}</text><text x="40" y="82" class="caption">{escape(caption)}</text>''']
    for col, cycle in enumerate(cycles):
        x = left + col * cell_w
        parts.append(f'<text x="{x + cell_w/2}" y="130" text-anchor="middle" class="head">{escape(cycle)}</text>')
    for row_index, (label, cells) in enumerate(rows):
        y = top + row_index * cell_h
        parts.append(f'<text x="40" y="{y + 43}" class="label">{escape(label)}</text>')
        for col, cell in enumerate(cells):
            x = left + col * cell_w
            cls = "grid" if cell == "—" else "active"
            parts.append(f'<rect x="{x}" y="{y}" width="{cell_w-6}" height="{cell_h-8}" rx="5" class="{cls}"/>')
            lines = wrap_lines(cell, 20)
            start_y = y + 31 - (len(lines)-1)*9
            parts.append(svg_text_block(int(x + (cell_w-6)/2), int(start_y), lines, "cell", 19).replace('<text ', '<text text-anchor="middle" '))
    parts.append('</svg>')
    return "".join(parts)


GROUP_INTROS = {
    "A. Top-level integration": "먼저 hierarchy를 연결하는 top module을 본다. 이 모듈들은 leaf 연산보다 ownership과 경로 이해가 핵심이다.",
    "B. Frontend": "PC 선택부터 instruction 두 개가 backend에 전달될 때까지 따라간다.",
    "C. Rename and scheduling": "architectural instruction이 physical identity와 ROB sequence를 얻고 실행을 기다리는 과정이다.",
    "D. Execute and writeback": "issue된 uop이 계산되고 결과가 PRF/ROB에 돌아오는 경로다.",
    "E. Load/store subsystem": "두 LSU의 out-of-order memory 동작을 program order와 precise visibility로 바꾼다.",
    "F. Privilege, trap and protection": "CSR, PMP, exception, interrupt와 fence가 architectural boundary를 소유한다.",
    "G. SoC fabric and memory": "Core/Host 요청이 TIM, peripheral 또는 error target까지 이동하고 반드시 response로 끝나는 경로다.",
}


def generated_markdown() -> str:
    lines = [
        "### 15.43 초보자용 module walkthrough와 timing atlas",
        "",
        "이 절은 signal 목록을 읽기 전에 실제 동작을 순서대로 이해하기 위한 입문 경로다.",
        "모든 latency는 `valid && ready`가 성립한 clock edge를 accept 기준으로 센다.",
        "`조합`은 별도 state edge가 없다는 뜻이고, `1 registered stage`는 accept 다음",
        "cycle에 output valid가 보인다는 뜻이다. `가변` latency는 기능이 불명확하다는",
        "뜻이 아니라 downstream ready, memory response 또는 iteration 수가 완료 시점을",
        "결정한다는 뜻이다. 각 SVG는 좌→우 data flow, 위→아래 control/state, 5-pixel",
        "직교 화살표를 공통 규칙으로 사용한다.",
        "",
        "#### 15.43.1 명령어 한 개를 끝까지 따라가기",
        "",
        "![한 ALU 명령의 기본 lifecycle](diagrams/modules/instruction-lifecycle.svg)",
        "",
        "위 그림의 C0~C5는 stall이 없는 교육용 예시다. 실제 Core에서 fetch memory wait,",
        "IQ dependency, WB port conflict 또는 ROB-head wait가 생기면 해당 stage의 valid와",
        "payload가 유지되면서 뒤 cycle로 늘어난다. OoO의 핵심은 Execute/WB 순서는 바뀔",
        "수 있지만 Commit은 ROB head의 program order를 절대 넘지 않는다는 점이다.",
        "",
        "#### 15.43.2 반드시 먼저 볼 cycle 예시",
        "",
    ]
    for slug, title, caption, _, _ in TIMELINES[1:]:
        lines.extend([f"##### {title}", "", f"![{title}](diagrams/modules/{slug}.svg)", "", caption, ""])
    lines.extend(["#### 15.43.3 전체 합성 module card", ""])
    for group, intro in GROUP_INTROS.items():
        lines.extend([f"#### {group}", "", intro, ""])
        for d in (item for item in MODULES if item.group == group):
            lines.extend([
                f"##### `{d.name}`",
                "",
                f"[SVG 크게 보기](diagrams/modules/{d.name}.svg)",
                "",
                f"![{d.name} block diagram](diagrams/modules/{d.name}.svg)",
                "",
                f"**목적.** {d.purpose}",
                "",
                "**Step-by-step.**",
                "",
                f"1. {d.steps[0]}",
                f"2. {d.steps[1]}",
                f"3. {d.steps[2]}",
                "",
                f"**타이밍.** {d.timing} 처리율은 {d.throughput} Backpressure/flush 규칙은 {d.hold}",
                "",
                f"**코너케이스.** {d.corners}",
                "",
                f"**RTL 위치.** [`{d.source}`](../{d.source})",
                "",
            ])
    lines.extend([
        "#### 15.43.4 그림과 RTL을 함께 변경하는 규칙",
        "",
        "module port, 저장 state, latency, 처리율 또는 event priority가 바뀌면 해당 RTL과",
        "이 절의 module card source data, SVG, directed test를 같은 commit에서 변경한다.",
        "`python scripts/generate_module_diagrams.py --check`는 checked-in SVG/HDD가 generator",
        "결과와 같은지 검사하고, option 없이 실행하면 다시 생성한다. 그림의 latency는",
        "희망 사양이 아니라 현재 RTL의 handshake edge를 기준으로 유지한다.",
        "",
    ])
    return "\n".join(lines)


def render_all() -> dict[Path, str]:
    outputs = {OUT / f"{d.name}.svg": module_svg(d) + "\n" for d in MODULES}
    for timeline in TIMELINES:
        outputs[OUT / f"{timeline[0]}.svg"] = timeline_svg(*timeline) + "\n"
    hdd_text = HDD.read_text(encoding="utf-8")
    if BEGIN not in hdd_text or END not in hdd_text:
        raise SystemExit("HDD generated walkthrough markers are missing")
    before, remainder = hdd_text.split(BEGIN, 1)
    _, after = remainder.split(END, 1)
    outputs[HDD] = before + BEGIN + "\n\n" + generated_markdown() + "\n" + END + after
    return outputs


def validate_catalog() -> None:
    names = [d.name for d in MODULES]
    if len(names) != len(set(names)):
        raise SystemExit("duplicate module name in documentation catalog")
    actual = set()
    for source in (ROOT / "rtl").rglob("*.sv"):
        text = source.read_text(encoding="utf-8")
        actual.update(re.findall(r"(?m)^module\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    documented = set(names)
    if actual != documented:
        missing = sorted(actual - documented)
        stale = sorted(documented - actual)
        raise SystemExit(f"module catalog mismatch: missing={missing}, stale={stale}")
    for d in MODULES:
        source = ROOT / d.source
        if not source.is_file():
            raise SystemExit(f"module source does not exist: {d.source}")
        source_text = source.read_text(encoding="utf-8")
        if not re.search(rf"(?m)^module\s+{re.escape(d.name)}\b", source_text):
            raise SystemExit(f"{d.name} is not declared in {d.source}")


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="fail if checked-in diagrams/HDD differ")
    args = parser.parse_args()
    validate_catalog()
    outputs = render_all()
    stale = []
    for path, expected in outputs.items():
        actual = path.read_text(encoding="utf-8") if path.exists() else None
        if actual != expected:
            stale.append(path)
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(expected, encoding="utf-8", newline="\n")
    if args.check and stale:
        for path in stale:
            print(f"STALE {path.relative_to(ROOT)}")
        return 1
    action = "checked" if args.check else "generated"
    print(f"Module documentation {action}: {len(MODULES)} modules, "
          f"{len(TIMELINES)} timing diagrams")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
