; On a big-endian target the 8-byte pieces of a wide access are still in
; memory order: the piece at the lowest address holds the most significant
; bits. A value that does not fill its store size, whose bits' bytes are then
; not all known, is not reported.
;
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args \
; RUN:   -sanitizer-coverage-trace-pointee-access -S | FileCheck %s

target datalayout = "E-m:e-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64_be-unknown-linux-gnu"

define void @wide(ptr %p) {
  %w = load i128, ptr %p, align 16
  %q = getelementptr inbounds i8, ptr %p, i64 16
  %odd = load i65, ptr %q, align 16
  ret void
}
; CHECK-LABEL: define void @wide(
; CHECK:      %w = load i128, ptr %p
; CHECK-NEXT: %[[F:[0-9]+]] = freeze i128 %w
; CHECK-NEXT: %[[HI:[0-9]+]] = lshr i128 %[[F]], 64
; CHECK-NEXT: %[[P0:[0-9]+]] = trunc i128 %[[HI]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, i64 %[[P0]], ptr null, i32 0) #{{[0-9]+}}, !pcsections ![[P0D:[0-9]+]]
; CHECK-NEXT: %[[P1:[0-9]+]] = trunc i128 %[[F]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, i64 %[[P1]], ptr null, i32 0) #{{[0-9]+}}, !pcsections ![[P1D:[0-9]+]]
; CHECK-NEXT: %q = getelementptr
; CHECK-NEXT: %odd = load i65
; CHECK-NEXT: ret void
; CHECK-DAG: ![[P0D]] = !{!"__sancov_dataflow", ![[P0DD:[0-9]+]]}
; CHECK-DAG: ![[P0DD]] = !{i8 2, i8 -126, i8 1, i8 0, i16 0, i16 1, i16 0, i16 16, i32 8, i32 0}
; CHECK-DAG: ![[P1D]] = !{!"__sancov_dataflow", ![[P1DD:[0-9]+]]}
; CHECK-DAG: ![[P1DD]] = !{i8 2, i8 -126, i8 1, i8 0, i16 0, i16 1, i16 1, i16 16, i32 8, i32 8}
