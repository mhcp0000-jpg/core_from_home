.section .text.init
.option norelax
.option norvc
.globl _start
_start:
j entry_jump
.org 0x166
.option rvc
entry_jump:
c.j main
.option norvc
.org 0x8fc
.globl main
main:
lui s6,0x80000
lui ra, 339563
addi ra, ra, 1080
lui sp, 993909
addi sp, sp, -540
lui gp, 158177
addi gp, gp, -713
lui tp, 414002
addi tp, tp, 1806
lui t0, 682554
addi t0, t0, 1104
lui t1, 50632
addi t1, t1, -48
lui t2, 75955
addi t2, t2, -205
lui s0, 861169
addi s0, s0, -2012
lui s1, 561913
addi s1, s1, 43
lui a0, 98703
addi a0, a0, -2031
lui a1, 383453
addi a1, a1, -1544
lui a2, 611098
addi a2, a2, -1955
lui a3, 60816
addi a3, a3, 1141
lui a4, 953894
addi a4, a4, -620
lui a5, 532085
addi a5, a5, -267
lui a6, 225127
addi a6, a6, 1484
lui a7, 39317
addi a7, a7, 216
lui s2, 90122
addi s2, s2, 858
lui s3, 454710
addi s3, s3, 1882
lui s4, 438485
addi s4, s4, 1179
lui s5, 73249
addi s5, s5, -1137
lui s6, 252353
addi s6, s6, 1828
lui s7, 95119
addi s7, s7, 2009
lui s8, 577815
addi s8, s8, -306
lui s9, 445141
addi s9, s9, -1498
lui s10, 61982
addi s10, s10, -586
lui s11, 867017
addi s11, s11, 1199
lui t3, 592921
addi t3, t3, 719
lui t4, 129816
addi t4, t4, -989
lui t5, 993473
addi t5, t5, 93
lui t6, 234083
addi t6, t6, 89
or tp, gp, sp
sltiu a0, s10, -280
sltiu a0, t0, -302
add t6, a2, a4
auipc s11, 5685
slt a6, t5, tp
andi tp, s5, 48
slt t1, a5, t3
sltu zero, t1, s9
sub s8, s3, sp
slt t5, sp, tp
or a3, tp, s3
sub zero, t6, a0
xor zero, s4, a1
sub a5, s6, a7
slt s10, a1, s3
add t6, a0, s3
and tp, s6, t0
and ra, t0, s8
xori gp, t5, -751
xor a7, t6, t0
add ra, ra, s2
sltu a4, a5, t2
xor s3, t3, s8
sub s10, sp, s6
sltu s11, t4, t6
auipc t6, 16692
sub s1, s0, s3
add s2, s7, t4
addi a5, a5, -357
lui s4, 42866
sub t1, s6, s1
or t4, sp, tp
xor sp, a1, t4
or s7, s1, s3
or zero, s5, t0
addi sp, gp, -740
sltu tp, t2, a7
sub tp, ra, s7
slt s1, t5, t5
slt a5, t0, t1
srl a3, t0, ra
slt s4, s5, t4
sub s6, s0, a7
and t5, ra, s2
xor a6, t4, s10
sub a2, s1, tp
or s3, a3, a1
auipc tp, 43185
or a2, s9, t4
slt s6, a5, zero
slt s7, ra, tp
sltu t3, a7, a0
auipc s3, 14370
add a1, t1, a0
sra t4, a3, sp
add s2, t2, t4
lui s6, 31698
xor s4, a0, s0
slti s4, a2, -656
xor s2, s0, tp
or a6, t0, zero
slt t0, s10, t4
addi t3, s5, 777
auipc a6, 40678
sltu a1, gp, s7
xor zero, a5, s2
sub s7, t1, a6
xor s5, t3, s1
add a4, a4, t1
sltu a4, a1, t0
lui gp, 47930
sltu ra, tp, s8
sltu t5, a4, s1
add s0, sp, t1
sll t2, s6, sp
sub t0, t6, s7
add s7, s7, s3
slt sp, s6, t4
sltu s11, s1, t4
xor t6, s7, t5
sub gp, sp, a7
sltu tp, s4, ra
sltiu t0, zero, 327
add a7, s0, t3
sub a3, a7, a6
xor s0, a0, tp
or a0, zero, t3
xori s3, s11, -664
auipc zero, 62225
sub s2, s1, s6
xori t0, a6, -232
xor a1, s0, t1
and s11, s9, ra
sltu s0, t1, s7
addi s4, t2, 902
or a7, s8, t6
slt zero, s1, gp
xor s8, a7, t1
xori a2, s0, -70
and t4, a3, s7
add a1, ra, zero
sub s6, a3, t1
slt s8, a6, t2
lui tp, 31414
add tp, s5, a0
sub a5, zero, t5
sltu s3, a1, s2
slti a7, sp, 134
sltiu t4, t0, 31
sltiu t3, t6, -690
slti s8, a3, -530
sub s4, t0, gp
sub s5, a6, a4
and t0, tp, s7
sltu s7, s1, s5
xor ra, ra, gp
slt a7, a6, a0
xor s9, t0, zero
sub s4, s6, t2
addi s1, t3, -817
and a0, s7, t3
slt a3, a1, a3
and a6, s8, t4
and a1, sp, a7
xor a2, zero, a6
xor t5, a1, tp
lui zero, 16761
sltu s11, t2, a5
and s5, a5, t4
sltu t3, s6, zero
slt s6, s0, tp
slt tp, s11, t3
xor a4, s10, a2
add t5, gp, s1
lui s4, 23262
ori s0, s2, 429
xori s2, a7, -707
add a2, s9, t1
slt a5, a2, s0
slti s1, a0, 582
srai a2, t6, 24
sub t2, s1, gp
slt a4, t4, a2
slti s3, gp, -683
sub t1, t6, s2
sltu s8, s1, zero
slt s7, sp, s7
auipc s4, 9160
and t4, s4, a4
sltu s1, s1, s2
ori tp, t1, -426
slt t4, zero, ra
slt sp, a2, t2
add a0, s0, a4
or t6, a3, s5
slt s5, s1, s7
lui t5, 26
or s2, s9, t5
sra s7, s0, s5
and a5, s6, s3
sltu a6, zero, t6
andi s5, gp, -998
sltu s10, a1, tp
and t5, tp, a5
or s4, s1, s7
sub s9, s10, s5
sub a2, t1, t5
sub gp, t3, s6
and t3, s10, s10
and zero, t4, a6
slti t6, a7, -934
and tp, s5, t2
sub zero, a1, a6
add t0, s2, t0
xor t5, a7, a2
add tp, a7, s2
ori s2, a6, -874
slt s9, s9, gp
sub s6, a0, a3
sll s6, a5, s7
sub a7, s9, a1
slt a4, s8, s10
sltiu a2, a4, 564
addi a1, s11, -615
or a7, s6, a0
or ra, a0, t3
sltu a1, t6, s3
slt a6, a0, s9
add s7, a4, a1
xor ra, a2, s2
add a4, s4, a5
slt t6, a6, ra
auipc s7, 9720
slt a1, s1, s5
slt t6, s8, s3
add t0, t5, a3
slt t0, t0, s8
and s8, a2, gp
slti sp, s3, -473
sltu a3, t0, s1
and s11, sp, t0
xor s4, tp, s5
slti a1, t3, -70
lui s4, 364
sub a1, a1, s2
sra t3, a2, t3
auipc s11, 60643
ori s3, s7, -490
addi s2, s7, -698
lui sp, 27419
slt s0, s9, t1
addi s8, s3, 132
auipc s6, 32178
addi gp, s1, -368
slt s1, a4, s8
xor t0, s11, a0
xor gp, t4, a1
addi zero, s8, -357
sub t1, a7, t4
sub a3, t3, s5
slt a0, s0, a4
xor s2, s4, a3
xor s0, a1, a2
xor s0, s3, s2
slt s10, t4, t1
sltiu s11, t6, -461
addi t3, t6, -393
xori sp, t1, 425
sltu s0, a0, s5
sltu tp, a6, s5
or s10, a0, s10
addi s10, s11, 434
sltiu a5, s5, -538
sltu zero, t4, s3
sra s0, s0, a5
and a3, s8, a5
and s4, a6, s9
or s5, t4, t4
or s6, s3, s11
slt t3, a0, s4
addi a4, s4, -440
or a3, s6, zero
auipc a4, 62526
sltu s7, sp, a0
sltu s6, s10, s5
xor t1, s4, s1
sub t5, a4, s8
and zero, t5, tp
and zero, zero, t3
sub t5, a0, s2
xor s7, t0, a1
sub t2, zero, t4
add sp, t5, s8
slt zero, s1, t2
andi t2, s3, 670
lui t0,0x80020
addi t1,zero,1
sw zero,4(t0)
sw t1,0(t0)
done: j done
.section .htif,"aw",@progbits
.balign 8
.globl tohost
tohost: .dword 0
.globl fromhost
fromhost: .dword 0
