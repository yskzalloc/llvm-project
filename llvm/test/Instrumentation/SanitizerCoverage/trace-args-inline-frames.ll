; A callee the inliner merged into its caller is reported like any other
; function: its parameters are traced from inside its inlined body, so the
; return address the runtime reads lands in that body and the debug location
; the call carries names the callee. This is what keeps trace-args complete
; under inlining, without having to build with -fno-inline.
;
; The input is the -O2 -g shape of
;
;    struct point { long x, y; };
;    static long leaf(long n, struct point *p) { return n + p->x + p->y; }
;    static long mid(long a, struct point *p)   { return leaf(a * 2, p) + 1; }
;    long caller(long size, struct point *p)    { return mid(size, p); }
;
; after leaf has been inlined into mid and mid into caller: three frames, one
; load left of leaf's body, and mid's own code folded away entirely.
;
; opt runs the verifier, so a passing run also proves the emitted IR is
; well-formed - including the inlined debug locations placed on the calls.
;
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-level=3 -sanitizer-coverage-trace-args -S | FileCheck %s

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i64 @caller(i64 %size, ptr %p) !dbg !10 {
entry:
    #dbg_value(i64 %size, !20, !DIExpression(), !22)
    #dbg_value(ptr %p, !21, !DIExpression(), !22)
    #dbg_value(i64 %size, !23, !DIExpression(), !27)
    #dbg_value(ptr %p, !26, !DIExpression(), !27)
    #dbg_value(i64 %size, !29, !DIExpression(DW_OP_constu, 1, DW_OP_shl, DW_OP_stack_value), !33)
    #dbg_value(ptr %p, !32, !DIExpression(), !33)
  %x = load i64, ptr %p, align 8, !dbg !35
  ret i64 %x, !dbg !36
}

; One field table is shared by all three frames: the parameter is the same
; struct point * in each.
; CHECK: @__sancov_offsets_ = private unnamed_addr constant [4 x i64] [i64 0, i64 8, i64 8, i64 8]

; CHECK-LABEL: define i64 @caller(

; caller's own frame, reported at the top of the entry block and located in
; caller itself - no inlinedAt.
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %size, ptr null, i32 0), !dbg [[OWN:![0-9]+]]
; CHECK: %[[P0:[0-9]+]] = ptrtoint ptr %p to i64, !dbg [[OWN]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, i32 16, i64 %[[P0]], ptr @__sancov_offsets_, i32 2), !dbg [[OWN]]

; mid's frame. mid kept no instruction of its own, but the body of the leaf it
; inlined lies inside mid's range, so mid is still reachable by walking out
; along the inline chain and is reported from there.
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %size, ptr null, i32 0), !dbg [[MID:![0-9]+]]
; CHECK: %[[P1:[0-9]+]] = ptrtoint ptr %p to i64, !dbg [[MID]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, i32 16, i64 %[[P1]], ptr @__sancov_offsets_, i32 2), !dbg [[MID]]

; leaf's frame. Its first parameter survives only as an expression computing
; the value (a * 2), which cannot be replayed, so it is reported with size 0 -
; the frame still accounts for every parameter leaf declares.
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 0, i64 0, ptr null, i32 0), !dbg [[LEAF:![0-9]+]]
; CHECK: %[[P2:[0-9]+]] = ptrtoint ptr %p to i64, !dbg [[LEAF]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, i32 16, i64 %[[P2]], ptr @__sancov_offsets_, i32 2), !dbg [[LEAF]]

; Exactly three frames: nothing is reported twice and nothing is invented.
; CHECK-NOT: call void @__sanitizer_cov_trace_args(

; Each frame's location names its own subprogram, and an inlined one carries the
; call site it was inlined at, which is what a symbolizer follows to recover
; the chain leaf -> mid -> caller from a single address.
; CHECK-DAG: [[OWN]] = !DILocation(line: 19, scope: ![[CALLER:[0-9]+]])
; CHECK-DAG: ![[CALLER]] = distinct !DISubprogram(name: "caller"
; CHECK-DAG: [[MID]] = !DILocation(line: 14, scope: ![[MIDSP:[0-9]+]], inlinedAt: ![[MIDAT:[0-9]+]])
; CHECK-DAG: ![[MIDSP]] = distinct !DISubprogram(name: "mid"
; CHECK-DAG: ![[MIDAT]] = distinct !DILocation(line: 20, column: 9, scope: ![[CALLER]])
; CHECK-DAG: [[LEAF]] = !DILocation(line: 9, scope: ![[LEAFSP:[0-9]+]], inlinedAt: ![[LEAFAT:[0-9]+]])
; CHECK-DAG: ![[LEAFSP]] = distinct !DISubprogram(name: "leaf"
; CHECK-DAG: ![[LEAFAT]] = distinct !DILocation(line: 15, column: 9, scope: ![[MIDSP]], inlinedAt: ![[MIDAT]])

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!8, !9}

!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, isOptimized: true, emissionKind: FullDebug)
!1 = !DIFile(filename: "frames.c", directory: "/")
!2 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!3 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !4, size: 64)
!4 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "point", file: !1, line: 1, size: 128, elements: !5)
!5 = !{!6, !7}
!6 = !DIDerivedType(tag: DW_TAG_member, name: "x", scope: !4, file: !1, line: 1, baseType: !2, size: 64)
!7 = !DIDerivedType(tag: DW_TAG_member, name: "y", scope: !4, file: !1, line: 1, baseType: !2, size: 64, offset: 64)
!8 = !{i32 7, !"Dwarf Version", i32 5}
!9 = !{i32 2, !"Debug Info Version", i32 3}

!10 = distinct !DISubprogram(name: "caller", scope: !1, file: !1, line: 18, type: !11, scopeLine: 19, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !19)
!11 = !DISubroutineType(types: !12)
!12 = !{!2, !2, !3}
!13 = distinct !DISubprogram(name: "mid", scope: !1, file: !1, line: 13, type: !11, scopeLine: 14, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !25)
!14 = distinct !DISubprogram(name: "leaf", scope: !1, file: !1, line: 8, type: !11, scopeLine: 9, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !31)

!19 = !{!20, !21}
!20 = !DILocalVariable(name: "size", arg: 1, scope: !10, file: !1, line: 18, type: !2)
!21 = !DILocalVariable(name: "p", arg: 2, scope: !10, file: !1, line: 18, type: !3)
!22 = !DILocation(line: 0, scope: !10)

!25 = !{!23, !26}
!23 = !DILocalVariable(name: "a", arg: 1, scope: !13, file: !1, line: 13, type: !2)
!26 = !DILocalVariable(name: "p", arg: 2, scope: !13, file: !1, line: 13, type: !3)
!27 = distinct !DILocation(line: 0, scope: !13, inlinedAt: !28)
!28 = distinct !DILocation(line: 20, column: 9, scope: !10)

!31 = !{!29, !32}
!29 = !DILocalVariable(name: "n", arg: 1, scope: !14, file: !1, line: 8, type: !2)
!32 = !DILocalVariable(name: "p", arg: 2, scope: !14, file: !1, line: 8, type: !3)
!33 = distinct !DILocation(line: 0, scope: !14, inlinedAt: !34)
!34 = distinct !DILocation(line: 15, column: 9, scope: !13, inlinedAt: !28)

!35 = distinct !DILocation(line: 10, column: 16, scope: !14, inlinedAt: !34)
!36 = !DILocation(line: 21, scope: !10)
