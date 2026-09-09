# PMP fetch parcel boundary 결과

실행일: 2026-09-09

- ELF: `test.elf`
- PMP 설정 commit: `pmpaddr0=0x2000023f`, `pmpcfg0=0x0000000f`
- TOR 범위: `[0x00000000, 0x800008fc)`
- 검사 instruction: PC `0x800008fc`, raw `0x80000b37` (`LUI x22,0x80000`)
- 관측 결과: `trap=0`, GPR write `x22=0x80000000`
- checker: `PASS: TOR top=0x800008fc, 16-byte block=0x800008f0, M-mode instruction at 0x800008fc retired without fault`

전체 in-order retire 기록은 `commit_trace.csv`에 보존한다. 이 결과는
`0x800008f0~0x800008ff`를 하나의 16-byte PMP access로 오판하던 기존 문제를
재현한 뒤, transport는 16 bytes로 유지하면서 2-byte instruction parcel 단위로
권한을 합성한 RTL에서 얻었다.
