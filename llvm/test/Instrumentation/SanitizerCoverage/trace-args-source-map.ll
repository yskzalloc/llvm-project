; With debug information, trace-args records which source parameter each
; argument observation holds in the debug-only !sancov.dataflow attachment of
; the function, one tuple per piece:
;
;   !{i32 IR argument, i32 element, DILocalVariable, i1 indirect,
;     i64 value bit offset, i64 variable bit offset, i64 bit size}
;
; The attachment is the only thing debug information adds; stripping debug
; information removes it (trace-args-debug-invariance.ll).
;
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -S | FileCheck %s
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -S \
; RUN:   | opt -strip-debug -S | FileCheck %s --check-prefix=STRIPPED
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -S \
; RUN:   | opt -passes=strip-nonlinetable-debuginfo -S | FileCheck %s --check-prefix=STRIPPED
; STRIPPED-NOT: !sancov.dataflow
;
; The split-aggregate cases of Inputs/trace-args-cases-*.ll, as clang emits them for each
; target: a source parameter split into two IR arguments on x86-64, and into
; two elements of one IR argument on AArch64, followed by a parameter that keeps
; its own mapping.
; RUN: opt < %S/Inputs/trace-args-cases-x86_64.ll -passes='module(sancov-module)' -sanitizer-coverage-trace-args -S \
; RUN:   | FileCheck %s --check-prefix=X86
; RUN: opt < %S/Inputs/trace-args-cases-aarch64.ll -passes='module(sancov-module)' -sanitizer-coverage-trace-args -S \
; RUN:   | FileCheck %s --check-prefix=A64
;
; X86: define {{.*}} @c13_after_split(double %m.coerce0, i64 %m.coerce1, i32 noundef %z) {{.*}} !sancov.dataflow ![[MAP:[0-9]+]]
; X86-DAG: ![[MAP]] = !{![[M0:[0-9]+]], ![[M1:[0-9]+]], ![[Z:[0-9]+]]}
; X86-DAG: ![[M0]] = !{i32 0, i32 0, ![[MVAR:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; X86-DAG: ![[M1]] = !{i32 1, i32 0, ![[MVAR]], i1 false, i64 0, i64 64, i64 64}
; X86-DAG: ![[Z]] = !{i32 2, i32 0, ![[ZVAR:[0-9]+]], i1 false, i64 0, i64 0, i64 32}
; X86-DAG: ![[MVAR]] = !DILocalVariable(name: "m", arg: 1,
; X86-DAG: ![[ZVAR]] = !DILocalVariable(name: "z", arg: 2,
;
; The first element's record was optimized out; the second maps it at offset
; 0, and the poison record of fragment [0, 64) completes it.
; A64: define {{.*}} @c13_after_split([2 x i64] %m.coerce, i32 noundef %z) {{.*}} !sancov.dataflow ![[MAP:[0-9]+]]
; A64-DAG: ![[MAP]] = !{![[M0:[0-9]+]], ![[M1:[0-9]+]], ![[Z:[0-9]+]]}
; A64-DAG: ![[M0]] = !{i32 0, i32 0, ![[MVAR:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; A64-DAG: ![[M1]] = !{i32 0, i32 1, ![[MVAR]], i1 false, i64 0, i64 64, i64 64}
; A64-DAG: ![[Z]] = !{i32 1, i32 0, ![[ZVAR:[0-9]+]], i1 false, i64 0, i64 0, i64 32}
; A64-DAG: ![[MVAR]] = !DILocalVariable(name: "m", arg: 1,
; A64-DAG: ![[ZVAR]] = !DILocalVariable(name: "z", arg: 2,

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.S = type { i64, i64, i64 }

; A struct coerced into one register and described as two fragments merges
; into one piece; the hidden sret pointer has no entry and does not shift %p.
; CHECK: define void @coerced(ptr sret(%struct.S) %r, i64 %p, ptr %q) {{.*}} !sancov.dataflow ![[COERCED:[0-9]+]]
define void @coerced(ptr sret(%struct.S) %r, i64 %p, ptr %q) !dbg !10 {
entry:
  %a = trunc i64 %p to i32
  %hi = lshr i64 %p, 32
  %b = trunc i64 %hi to i32
    #dbg_value(i32 %a, !13, !DIExpression(DW_OP_LLVM_fragment, 0, 32), !15)
    #dbg_value(i32 %b, !13, !DIExpression(DW_OP_LLVM_fragment, 32, 32), !15)
    #dbg_value(ptr %q, !14, !DIExpression(), !15)
  ret void
}

; byval, described by a #dbg_declare of the argument: the observed address is
; the parameter's address.
; CHECK: define i64 @use(ptr byval(%struct.S) %s) {{.*}} !sancov.dataflow ![[USE:[0-9]+]]
define i64 @use(ptr byval(%struct.S) %s) !dbg !20 {
entry:
    #dbg_declare(ptr %s, !21, !DIExpression(), !22)
  %v = load i64, ptr %s
  ret i64 %v
}

; A struct passed by address without an IR attribute, described through
; DW_OP_deref, and a C++ reference, described directly: the first is the
; parameter's address, the second the parameter's value.
; CHECK: define i64 @indirect(ptr %n, ptr %ref) {{.*}} !sancov.dataflow ![[INDIRECT:[0-9]+]]
define i64 @indirect(ptr %n, ptr %ref) !dbg !30 {
entry:
    #dbg_value(ptr %n, !31, !DIExpression(DW_OP_deref), !33)
    #dbg_value(ptr %ref, !32, !DIExpression(), !33)
  %v = load i64, ptr %n
  ret i64 %v
}

; -O0: the arguments are stored to declared allocas, a split struct at the
; offsets of its two halves.
; CHECK: define i64 @unoptimized(double %m0, i64 %m1, i32 %z) {{.*}} !sancov.dataflow ![[UNOPT:[0-9]+]]
define i64 @unoptimized(double %m0, i64 %m1, i32 %z) !dbg !40 {
entry:
  %m = alloca { double, i64 }, align 8
  %z.addr = alloca i32, align 4
  %lo = getelementptr inbounds { double, i64 }, ptr %m, i32 0, i32 0
  store double %m0, ptr %lo, align 8
  %hi = getelementptr inbounds { double, i64 }, ptr %m, i32 0, i32 1
  store i64 %m1, ptr %hi, align 8
    #dbg_declare(ptr %m, !41, !DIExpression(), !43)
  store i32 %z, ptr %z.addr, align 4
    #dbg_declare(ptr %z.addr, !42, !DIExpression(), !43)
  ; A later assignment to the parameter is not its value on entry.
  store i32 7, ptr %z.addr, align 4
  %r = load i64, ptr %hi
  ret i64 %r
}

; -O0 for a struct coerced into two IR arguments: the arguments go to a
; temporary, which is copied into the declared alloca.
; CHECK: define float @hfa(<2 x float> %c0, float %c1) {{.*}} !sancov.dataflow ![[HFA:[0-9]+]]
define float @hfa(<2 x float> %c0, float %c1) !dbg !70 {
entry:
  %h = alloca [3 x float], align 4
  %coerce = alloca { <2 x float>, float }, align 4
  %lo = getelementptr inbounds { <2 x float>, float }, ptr %coerce, i32 0, i32 0
  store <2 x float> %c0, ptr %lo, align 4
  %hi = getelementptr inbounds { <2 x float>, float }, ptr %coerce, i32 0, i32 1
  store float %c1, ptr %hi, align 4
  call void @llvm.memcpy.p0.p0.i64(ptr align 4 %h, ptr align 4 %coerce, i64 12, i1 false)
    #dbg_declare(ptr %h, !71, !DIExpression(), !72)
  %r = load float, ptr %h, align 4
  ret float %r
}
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

; Salvaged expressions: what is left of a deleted trunc, lshr or zext is the
; same bits - a bitfield struct coerced into an i32, and a bool converted to
; its 8-bit type, whose zero bits above are the reported value's.
; CHECK: define i32 @salvaged(i32 %b, i1 zeroext %t) {{.*}} !sancov.dataflow ![[SALV:[0-9]+]]
define i32 @salvaged(i32 %b, i1 zeroext %t) !dbg !80 {
entry:
    #dbg_value(i32 %b, !81, !DIExpression(DW_OP_LLVM_convert, 32, DW_ATE_unsigned, DW_OP_LLVM_convert, 16, DW_ATE_unsigned, DW_OP_stack_value, DW_OP_LLVM_fragment, 0, 16), !83)
    #dbg_value(i32 %b, !81, !DIExpression(DW_OP_constu, 16, DW_OP_shr, DW_OP_LLVM_convert, 32, DW_ATE_unsigned, DW_OP_LLVM_convert, 16, DW_ATE_unsigned, DW_OP_stack_value, DW_OP_LLVM_fragment, 16, 16), !83)
    #dbg_value(i1 %t, !82, !DIExpression(DW_OP_LLVM_convert, 1, DW_ATE_unsigned, DW_OP_LLVM_convert, 8, DW_ATE_unsigned, DW_OP_stack_value), !83)
  %r = zext i1 %t to i32
  %s = add i32 %b, %r
  ret i32 %s
}

; A hidden argument described by an artificial variable - a Fortran
; CHARACTER's length, here taken out of the {address, length} pair flang builds
; at -O0 - maps to that variable; a parameter outranks an artificial variable
; describing the same value.
; CHECK: define void @hidden(ptr %s, i64 %len, ptr %x) {{.*}} !sancov.dataflow ![[HID:[0-9]+]]
define void @hidden(ptr %s, i64 %len, ptr %x) !dbg !90 {
entry:
  %p0 = insertvalue { ptr, i64 } undef, ptr %s, 0
  %p1 = insertvalue { ptr, i64 } %p0, i64 %len, 1
  %a = extractvalue { ptr, i64 } %p1, 0
  %l = extractvalue { ptr, i64 } %p1, 1
    #dbg_value(i64 %l, !92, !DIExpression(), !94)
    #dbg_declare(ptr %a, !91, !DIExpression(), !94)
    #dbg_value(ptr %x, !93, !DIExpression(), !94)
    #dbg_value(ptr %x, !95, !DIExpression(), !94)
  ret void
}

; -O0, as Swift and flang copy a coerced argument into its variable: stored to
; a temporary, loaded back whole or by member, stored into the declared alloca.
; CHECK: define void @reloaded(i64 %c, i64 %d) {{.*}} !sancov.dataflow ![[REL:[0-9]+]]
define void @reloaded(i64 %c, i64 %d) !dbg !100 {
entry:
  %tmp = alloca i64, align 8
  %tmp2 = alloca i64, align 8
  %v = alloca { i32, i32 }, align 4
  %w = alloca { i32, i32 }, align 4
  store i64 %c, ptr %tmp, align 8
  %y.addr = getelementptr inbounds i8, ptr %tmp, i64 4
  %x = load i32, ptr %tmp, align 4
  %y = load i32, ptr %y.addr, align 4
  store i32 %x, ptr %v, align 4
  %v.y = getelementptr inbounds i8, ptr %v, i64 4
  store i32 %y, ptr %v.y, align 4
    #dbg_declare(ptr %v, !101, !DIExpression(), !103)
  store i64 %d, ptr %tmp2, align 8
  %whole = load { i32, i32 }, ptr %tmp2, align 4
  store { i32, i32 } %whole, ptr %w, align 4
    #dbg_declare(ptr %w, !102, !DIExpression(), !103)
  ret void
}

; What does not count: a record inlined from a callee describes the callee's
; parameter; a local variable is no parameter; a computed expression is not the
; value; a parameter of another subprogram is not this function's.
; CHECK-LABEL: define i64 @nothing(i64 %x, i64 %y, i64 %w) !dbg !{{[0-9]+}} {
; CHECK-NOT: !sancov.dataflow
define i64 @nothing(i64 %x, i64 %y, i64 %w) !dbg !50 {
entry:
    #dbg_value(i64 %x, !52, !DIExpression(), !54)
    #dbg_value(i64 %y, !53, !DIExpression(), !55)
    #dbg_value(i64 %w, !51, !DIExpression(DW_OP_plus_uconst, 1, DW_OP_stack_value), !54)
  ret i64 %x
}

; Two parameters claiming the same observation: neither is recorded.
; CHECK-LABEL: define i64 @ambiguous(i64 %a) !dbg !{{[0-9]+}} {
; CHECK-NOT: !sancov.dataflow
define i64 @ambiguous(i64 %a) !dbg !60 {
entry:
    #dbg_value(i64 %a, !61, !DIExpression(), !63)
    #dbg_value(i64 %a, !62, !DIExpression(), !63)
  ret i64 %a
}

; No debug information, no map.
; CHECK-LABEL: define i64 @nodebug(i64 %a) {
; CHECK-NOT: !sancov.dataflow
define i64 @nodebug(i64 %a) {
  ret i64 %a
}

; CHECK-DAG: ![[COERCED]] = !{![[C_P:[0-9]+]], ![[C_Q:[0-9]+]]}
; CHECK-DAG: ![[C_P]] = !{i32 1, i32 0, ![[PAIR:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[C_Q]] = !{i32 2, i32 0, ![[Q:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[PAIR]] = !DILocalVariable(name: "p", arg: 1,
; CHECK-DAG: ![[Q]] = !DILocalVariable(name: "q", arg: 2,
; CHECK-DAG: ![[USE]] = !{![[U_S:[0-9]+]]}
; CHECK-DAG: ![[U_S]] = !{i32 0, i32 0, ![[S:[0-9]+]], i1 true, i64 0, i64 0, i64 0}
; CHECK-DAG: ![[S]] = !DILocalVariable(name: "s", arg: 1,
; CHECK-DAG: ![[INDIRECT]] = !{![[I_N:[0-9]+]], ![[I_R:[0-9]+]]}
; CHECK-DAG: ![[I_N]] = !{i32 0, i32 0, ![[N:[0-9]+]], i1 true, i64 0, i64 0, i64 0}
; CHECK-DAG: ![[I_R]] = !{i32 1, i32 0, ![[REF:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[N]] = !DILocalVariable(name: "n", arg: 1,
; CHECK-DAG: ![[REF]] = !DILocalVariable(name: "ref", arg: 2,
; CHECK-DAG: ![[UNOPT]] = !{![[O_M0:[0-9]+]], ![[O_M1:[0-9]+]], ![[O_Z:[0-9]+]]}
; CHECK-DAG: ![[O_M0]] = !{i32 0, i32 0, ![[OM:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[O_M1]] = !{i32 1, i32 0, ![[OM]], i1 false, i64 0, i64 64, i64 64}
; CHECK-DAG: ![[O_Z]] = !{i32 2, i32 0, ![[OZ:[0-9]+]], i1 false, i64 0, i64 0, i64 32}
; CHECK-DAG: ![[HFA]] = !{![[H0:[0-9]+]], ![[H1:[0-9]+]]}
; CHECK-DAG: ![[H0]] = !{i32 0, i32 0, ![[HV:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[H1]] = !{i32 1, i32 0, ![[HV]], i1 false, i64 0, i64 64, i64 32}
; CHECK-DAG: ![[HV]] = !DILocalVariable(name: "h", arg: 1,
; CHECK-DAG: ![[SALV]] = !{![[S_B:[0-9]+]], ![[S_T:[0-9]+]]}
; CHECK-DAG: ![[S_B]] = !{i32 0, i32 0, ![[SB:[0-9]+]], i1 false, i64 0, i64 0, i64 32}
; CHECK-DAG: ![[S_T]] = !{i32 1, i32 0, ![[ST:[0-9]+]], i1 false, i64 0, i64 0, i64 8}
; CHECK-DAG: ![[SB]] = !DILocalVariable(name: "b", arg: 1,
; CHECK-DAG: ![[ST]] = !DILocalVariable(name: "t", arg: 2,
; CHECK-DAG: ![[HID]] = !{![[H_S:[0-9]+]], ![[H_L:[0-9]+]], ![[H_X:[0-9]+]]}
; CHECK-DAG: ![[H_S]] = !{i32 0, i32 0, ![[HS:[0-9]+]], i1 true, i64 0, i64 0, i64 0}
; CHECK-DAG: ![[H_L]] = !{i32 1, i32 0, ![[HL:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[H_X]] = !{i32 2, i32 0, ![[HX:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[HS]] = !DILocalVariable(name: "s", arg: 1,
; CHECK-DAG: ![[HL]] = !DILocalVariable(name: ".s.len", scope: {{.*}} flags: DIFlagArtificial)
; CHECK-DAG: ![[HX]] = !DILocalVariable(name: "x", arg: 2,
; CHECK-DAG: ![[REL]] = !{![[R_V:[0-9]+]], ![[R_W:[0-9]+]]}
; CHECK-DAG: ![[R_V]] = !{i32 0, i32 0, ![[RV:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[R_W]] = !{i32 1, i32 0, ![[RW:[0-9]+]], i1 false, i64 0, i64 0, i64 64}
; CHECK-DAG: ![[RV]] = !DILocalVariable(name: "v", arg: 1,
; CHECK-DAG: ![[RW]] = !DILocalVariable(name: "w", arg: 2,
; CHECK-DAG: ![[OM]] = !DILocalVariable(name: "m", arg: 1, scope: ![[UNOPT_SP:[0-9]+]]
; CHECK-DAG: ![[OZ]] = !DILocalVariable(name: "z", arg: 2, scope: ![[UNOPT_SP]]

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}

!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, isOptimized: true, emissionKind: FullDebug)
!1 = !DIFile(filename: "map.c", directory: "/")
!2 = !{i32 7, !"Dwarf Version", i32 5}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!5 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!6 = !DICompositeType(tag: DW_TAG_structure_type, name: "S", file: !1, size: 192, elements: !{})
!7 = !DIBasicType(name: "double", size: 64, encoding: DW_ATE_float)
!8 = !DICompositeType(tag: DW_TAG_structure_type, name: "pair", file: !1, size: 64, elements: !{})
!9 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !6, size: 64)
!10 = distinct !DISubprogram(name: "coerced", scope: !1, file: !1, line: 1, type: !11, scopeLine: 1, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!11 = !DISubroutineType(types: !12)
!12 = !{!6, !8, !9}
!13 = !DILocalVariable(name: "p", arg: 1, scope: !10, file: !1, line: 1, type: !8)
!14 = !DILocalVariable(name: "q", arg: 2, scope: !10, file: !1, line: 1, type: !9)
!15 = !DILocation(line: 1, column: 1, scope: !10)
!16 = !DIDerivedType(tag: DW_TAG_reference_type, baseType: !6, size: 64)
!17 = !DICompositeType(tag: DW_TAG_structure_type, name: "mix", file: !1, size: 128, elements: !{})
!20 = distinct !DISubprogram(name: "use", scope: !1, file: !1, line: 5, type: !23, scopeLine: 5, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!21 = !DILocalVariable(name: "s", arg: 1, scope: !20, file: !1, line: 5, type: !6)
!22 = !DILocation(line: 5, column: 1, scope: !20)
!23 = !DISubroutineType(types: !24)
!24 = !{!5, !6}
!30 = distinct !DISubprogram(name: "indirect", scope: !1, file: !1, line: 10, type: !34, scopeLine: 10, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!31 = !DILocalVariable(name: "n", arg: 1, scope: !30, file: !1, line: 10, type: !6)
!32 = !DILocalVariable(name: "ref", arg: 2, scope: !30, file: !1, line: 10, type: !16)
!33 = !DILocation(line: 10, column: 1, scope: !30)
!34 = !DISubroutineType(types: !35)
!35 = !{!5, !6, !16}
!40 = distinct !DISubprogram(name: "unoptimized", scope: !1, file: !1, line: 20, type: !44, scopeLine: 20, spFlags: DISPFlagDefinition, unit: !0)
!41 = !DILocalVariable(name: "m", arg: 1, scope: !40, file: !1, line: 20, type: !17)
!42 = !DILocalVariable(name: "z", arg: 2, scope: !40, file: !1, line: 20, type: !4)
!43 = !DILocation(line: 20, column: 1, scope: !40)
!44 = !DISubroutineType(types: !45)
!45 = !{!5, !17, !4}
!50 = distinct !DISubprogram(name: "nothing", scope: !1, file: !1, line: 30, type: !56, scopeLine: 30, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!51 = !DILocalVariable(name: "w", arg: 3, scope: !50, file: !1, line: 30, type: !5)
!52 = !DILocalVariable(name: "local", scope: !50, file: !1, line: 31, type: !5)
!53 = !DILocalVariable(name: "m", arg: 1, scope: !57, file: !1, line: 28, type: !5)
!54 = !DILocation(line: 31, column: 1, scope: !50)
!55 = !DILocation(line: 28, column: 1, scope: !57, inlinedAt: !54)
!56 = !DISubroutineType(types: !58)
!57 = distinct !DISubprogram(name: "leaf", scope: !1, file: !1, line: 28, type: !56, scopeLine: 28, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!58 = !{!5, !5, !5, !5}
!60 = distinct !DISubprogram(name: "ambiguous", scope: !1, file: !1, line: 40, type: !64, scopeLine: 40, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!61 = !DILocalVariable(name: "a", arg: 1, scope: !60, file: !1, line: 40, type: !5)
!62 = !DILocalVariable(name: "b", arg: 2, scope: !60, file: !1, line: 40, type: !5)
!63 = !DILocation(line: 40, column: 1, scope: !60)
!64 = !DISubroutineType(types: !65)
!65 = !{!5, !5, !5}
!66 = !DICompositeType(tag: DW_TAG_structure_type, name: "hfa", file: !1, size: 96, elements: !{})
!67 = !DIBasicType(name: "float", size: 32, encoding: DW_ATE_float)
!68 = !DISubroutineType(types: !69)
!69 = !{!67, !66}
!70 = distinct !DISubprogram(name: "hfa", scope: !1, file: !1, line: 50, type: !68, scopeLine: 50, spFlags: DISPFlagDefinition, unit: !0)
!71 = !DILocalVariable(name: "h", arg: 1, scope: !70, file: !1, line: 50, type: !66)
!72 = !DILocation(line: 50, column: 1, scope: !70)
!73 = !DIBasicType(name: "unsigned short", size: 16, encoding: DW_ATE_unsigned)
!74 = !DIBasicType(name: "_Bool", size: 8, encoding: DW_ATE_boolean)
!75 = !DICompositeType(tag: DW_TAG_structure_type, name: "bits", file: !1, size: 32, elements: !{})
!76 = !DISubroutineType(types: !77)
!77 = !{!4, !75, !74}
!78 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !4, size: 64)
!80 = distinct !DISubprogram(name: "salvaged", scope: !1, file: !1, line: 60, type: !76, scopeLine: 60, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!81 = !DILocalVariable(name: "b", arg: 1, scope: !80, file: !1, line: 60, type: !75)
!82 = !DILocalVariable(name: "t", arg: 2, scope: !80, file: !1, line: 60, type: !74)
!83 = !DILocation(line: 60, column: 1, scope: !80)
!90 = distinct !DISubprogram(name: "hidden", scope: !1, file: !1, line: 70, type: !76, scopeLine: 70, spFlags: DISPFlagDefinition, unit: !0)
!91 = !DILocalVariable(name: "s", arg: 1, scope: !90, file: !1, line: 70, type: !4)
!92 = !DILocalVariable(name: ".s.len", scope: !90, file: !1, line: 70, type: !5, flags: DIFlagArtificial)
!93 = !DILocalVariable(name: "x", arg: 2, scope: !90, file: !1, line: 70, type: !78)
!94 = !DILocation(line: 70, column: 1, scope: !90)
!95 = !DILocalVariable(name: "__range", scope: !90, file: !1, line: 70, type: !78, flags: DIFlagArtificial)
!100 = distinct !DISubprogram(name: "reloaded", scope: !1, file: !1, line: 80, type: !76, scopeLine: 80, spFlags: DISPFlagDefinition, unit: !0)
!101 = !DILocalVariable(name: "v", arg: 1, scope: !100, file: !1, line: 80, type: !8)
!102 = !DILocalVariable(name: "w", arg: 2, scope: !100, file: !1, line: 80, type: !8)
!103 = !DILocation(line: 80, column: 1, scope: !100)
