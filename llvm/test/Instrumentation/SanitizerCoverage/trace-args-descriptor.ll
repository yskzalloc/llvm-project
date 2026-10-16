; Every trace-args/trace-ret call carries an observation descriptor in a
; !pcsections attachment, which the backend emits into __sancov_dataflow:
;
;   u8 version, u8 flags, u8 class, u8 0, u16 IR argument, u16 IR arguments,
;   u16 element, u16 0, u32 size, u32 element offset
;
; flags: 1 return, 2 aggregate element, 4 in-memory argument, 8 sret object,
;        16 the function has an sret or swifterror argument, 32 unused,
;        64 a pointer reported with the bytes it points to
; class: 0 none, 1 integer, 2 pointer, 3 floating point, 4 vector, 5 object
;
; The descriptor comes from the IR alone; trace-args-debug-invariance.ll checks
; that debug information does not change it.
;
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -S | FileCheck %s
;
; PC sections are ELF only, and the call lowering has to keep them on the call,
; which X86 and AArch64 do.
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -mtriple=aarch64-linux-gnu -S \
; RUN:   | FileCheck %s --check-prefix=CHECK
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -mtriple=x86_64-apple-macosx -S \
; RUN:   | FileCheck %s --check-prefix=NONE
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -mtriple=riscv64-linux-gnu -S \
; RUN:   | FileCheck %s --check-prefix=NONE
; NONE: call void @__sanitizer_cov_trace_args(
; NONE-NOT: !pcsections

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.T = type { i32, i8, i64 }

; The sret pointer is not observed but counts: IR arguments 1..7 of 8, all
; flagged as belonging to a function with a hidden argument.
define void @args(ptr sret(%struct.T) %r, i32 %i, ptr %p, double %d, <2 x float> %v, { i32, i64 } %s, ptr byval(%struct.T) %b, <vscale x 2 x i64> %sv) {
  call void (...) @use(ptr %r, i32 %i, ptr %p, double %d, <2 x float> %v, { i32, i64 } %s, ptr %b, <vscale x 2 x i64> %sv)
  ret void
}


declare void @use(...)
; CHECK-LABEL: define void @args(
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, {{.*}}, !pcsections ![[I:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 2, {{.*}}, !pcsections ![[P:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 3, {{.*}}, !pcsections ![[D:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 4, {{.*}}, !pcsections ![[V:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 5, {{.*}}, !pcsections ![[S0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 5, {{.*}}, !pcsections ![[S1:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 6, {{.*}}, !pcsections ![[B:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 7, {{.*}}, !pcsections ![[SV:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_ret(i32 16, {{.*}}, !pcsections ![[RET:[0-9]+]]

; Returns: no IR argument (0xffff), one observation per aggregate element.
define { i32, i64 } @ret({ i32, i64 } %s) {
  ret { i32, i64 } %s
}
; CHECK-LABEL: define { i32, i64 } @ret(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, {{.*}}, !pcsections ![[R_A0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, {{.*}}, !pcsections ![[R_A1:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_ret(i32 4, {{.*}}, !pcsections ![[R_R0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_ret(i32 8, {{.*}}, !pcsections ![[R_R1:[0-9]+]]

; An unused argument is flagged (32); an unused object is not read.
define void @unused(i32 %x, ptr byval(%struct.T) %o) {
  ret void
}
; CHECK-LABEL: define void @unused(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, {{.*}}, !pcsections ![[U0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, {{.*}}, !pcsections ![[U1:[0-9]+]]

define void @void() {
  ret void
}
; CHECK-LABEL: define void @void(
; CHECK: call void @__sanitizer_cov_trace_ret(i32 0, {{.*}}, !pcsections ![[VOID:[0-9]+]]

; A dereferenceable pointer is a pointer (class 2) flagged 64, its size the
; bytes read behind it: the 24 the attribute gives, and the 64 the default
; -sanitizer-coverage-trace-pointee-bytes leaves of 4096. The same for a
; returned one. An unused one is only flagged unused.
define dereferenceable(4096) ptr @pointee(ptr dereferenceable(24) %p, ptr dereferenceable(8) %u) {
  ret ptr %p
}
; CHECK-LABEL: define dereferenceable(4096) ptr @pointee(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 24, {{.*}}, !pcsections ![[PT0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 1, i32 8, {{.*}}, !pcsections ![[PT1:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_ret(i32 64, {{.*}}, !pcsections ![[PTR:[0-9]+]]

; CHECK-DAG: ![[I]] = !{!"__sancov_dataflow", ![[I_D:[0-9]+]]}
; CHECK-DAG: ![[I_D]] = !{i8 1, i8 16, i8 1, i8 0, i16 1, i16 8, i16 0, i16 0, i32 4, i32 0}
; CHECK-DAG: ![[P]] = !{!"__sancov_dataflow", ![[P_D:[0-9]+]]}
; CHECK-DAG: ![[P_D]] = !{i8 1, i8 16, i8 2, i8 0, i16 2, i16 8, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[D]] = !{!"__sancov_dataflow", ![[D_D:[0-9]+]]}
; CHECK-DAG: ![[D_D]] = !{i8 1, i8 16, i8 3, i8 0, i16 3, i16 8, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[V]] = !{!"__sancov_dataflow", ![[V_D:[0-9]+]]}
; CHECK-DAG: ![[V_D]] = !{i8 1, i8 16, i8 4, i8 0, i16 4, i16 8, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[S0]] = !{!"__sancov_dataflow", ![[S0_D:[0-9]+]]}
; CHECK-DAG: ![[S0_D]] = !{i8 1, i8 18, i8 1, i8 0, i16 5, i16 8, i16 0, i16 0, i32 4, i32 0}
; CHECK-DAG: ![[S1]] = !{!"__sancov_dataflow", ![[S1_D:[0-9]+]]}
; CHECK-DAG: ![[S1_D]] = !{i8 1, i8 18, i8 1, i8 0, i16 5, i16 8, i16 1, i16 0, i32 8, i32 8}
; CHECK-DAG: ![[B]] = !{!"__sancov_dataflow", ![[B_D:[0-9]+]]}
; CHECK-DAG: ![[B_D]] = !{i8 1, i8 20, i8 5, i8 0, i16 6, i16 8, i16 0, i16 0, i32 16, i32 0}
; CHECK-DAG: ![[SV]] = !{!"__sancov_dataflow", ![[SV_D:[0-9]+]]}
; CHECK-DAG: ![[SV_D]] = !{i8 1, i8 16, i8 4, i8 0, i16 7, i16 8, i16 0, i16 0, i32 0, i32 0}
; CHECK-DAG: ![[RET]] = !{!"__sancov_dataflow", ![[RET_D:[0-9]+]]}
; CHECK-DAG: ![[RET_D]] = !{i8 1, i8 25, i8 5, i8 0, i16 -1, i16 8, i16 0, i16 0, i32 16, i32 0}
; CHECK-DAG: ![[R_A0]] = !{!"__sancov_dataflow", ![[R_A0_D:[0-9]+]]}
; CHECK-DAG: ![[R_A0_D]] = !{i8 1, i8 2, i8 1, i8 0, i16 0, i16 1, i16 0, i16 0, i32 4, i32 0}
; CHECK-DAG: ![[R_A1]] = !{!"__sancov_dataflow", ![[R_A1_D:[0-9]+]]}
; CHECK-DAG: ![[R_A1_D]] = !{i8 1, i8 2, i8 1, i8 0, i16 0, i16 1, i16 1, i16 0, i32 8, i32 8}
; CHECK-DAG: ![[R_R0]] = !{!"__sancov_dataflow", ![[R_R0_D:[0-9]+]]}
; CHECK-DAG: ![[R_R0_D]] = !{i8 1, i8 3, i8 1, i8 0, i16 -1, i16 1, i16 0, i16 0, i32 4, i32 0}
; CHECK-DAG: ![[R_R1]] = !{!"__sancov_dataflow", ![[R_R1_D:[0-9]+]]}
; CHECK-DAG: ![[R_R1_D]] = !{i8 1, i8 3, i8 1, i8 0, i16 -1, i16 1, i16 1, i16 0, i32 8, i32 8}
; CHECK-DAG: ![[VOID]] = !{!"__sancov_dataflow", ![[VOID_D:[0-9]+]]}
; CHECK-DAG: ![[VOID_D]] = !{i8 1, i8 1, i8 0, i8 0, i16 -1, i16 0, i16 0, i16 0, i32 0, i32 0}
; CHECK-DAG: ![[U0]] = !{!"__sancov_dataflow", ![[U0_D:[0-9]+]]}
; CHECK-DAG: ![[U0_D]] = !{i8 1, i8 32, i8 1, i8 0, i16 0, i16 2, i16 0, i16 0, i32 4, i32 0}
; CHECK-DAG: ![[U1]] = !{!"__sancov_dataflow", ![[U1_D:[0-9]+]]}
; CHECK-DAG: ![[U1_D]] = !{i8 1, i8 36, i8 5, i8 0, i16 1, i16 2, i16 0, i16 0, i32 0, i32 0}
; CHECK-DAG: ![[PT0]] = !{!"__sancov_dataflow", ![[PT0_D:[0-9]+]]}
; CHECK-DAG: ![[PT0_D]] = !{i8 1, i8 64, i8 2, i8 0, i16 0, i16 2, i16 0, i16 0, i32 24, i32 0}
; CHECK-DAG: ![[PT1]] = !{!"__sancov_dataflow", ![[PT1_D:[0-9]+]]}
; CHECK-DAG: ![[PT1_D]] = !{i8 1, i8 32, i8 2, i8 0, i16 1, i16 2, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[PTR]] = !{!"__sancov_dataflow", ![[PTR_D:[0-9]+]]}
; CHECK-DAG: ![[PTR_D]] = !{i8 1, i8 65, i8 2, i8 0, i16 -1, i16 2, i16 0, i16 0, i32 64, i32 0}
