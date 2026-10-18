; With -sanitizer-coverage-trace-pointee-access, trace-args also reports the
; value of each load and store a function makes through one of its pointer
; arguments at a constant byte offset, right after the access:
;
;   call @__sanitizer_cov_trace_args(i32 0x80000000 | kind << 16 | IR argument,
;                                    i32 size, i64 value, ptr null, i32 0)
;
; with a version 2 descriptor:
;
;   u8 2, u8 flags (128 access, 2 more than one piece), u8 class,
;   u8 kind (1 store, 2 volatile, 4 atomic, ordering << 4), u16 IR argument,
;   u16 IR arguments, u16 piece, u16 access size, u32 piece size,
;   u32 signed piece offset
;
; The value is the SSA value of the access. Nothing is read for it.
;
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args \
; RUN:   -sanitizer-coverage-trace-pointee-access -S | FileCheck %s
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args \
; RUN:   -sanitizer-coverage-trace-pointee-access \
; RUN:   -sanitizer-coverage-trace-pointee-access-volatile \
; RUN:   -sanitizer-coverage-trace-pointee-access-atomic -S \
; RUN:   | FileCheck %s --check-prefix=ALL
;
; Off, the default, nothing changes: the output is the output without the
; option, byte for byte.
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -S -o %t.default.ll
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret \
; RUN:   -sanitizer-coverage-trace-pointee-access=false -sanitizer-coverage-trace-pointee-access-volatile \
; RUN:   -sanitizer-coverage-trace-pointee-access-atomic -S -o %t.off.ll
; RUN: diff %t.default.ll %t.off.ll
; RUN: FileCheck %s --check-prefix=OFF --input-file=%t.off.ll
; OFF-NOT: {{i32 -21[0-9]{8},}}
; OFF-NOT: !{i8 2,
;
; Access records go through trace-args, so trace-ret alone has none.
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-ret \
; RUN:   -sanitizer-coverage-trace-pointee-access -S | FileCheck %s --check-prefix=OFF
;
; The instrumentation adds, removes, reorders and moves no load or store: the
; loads, stores and block labels of the module are the same lines in the same
; order before and after, with every option on (but for the numbers of
; metadata nodes).
; RUN: opt < %s -S | grep -E '^ *(%[^ ]+ = )?(load|store|atomicrmw|cmpxchg) |^[a-z0-9_.]+:' | sed 's/, ![a-z]* ![0-9]*$//' > %t.before
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret \
; RUN:   -sanitizer-coverage-trace-pointee-access -sanitizer-coverage-trace-pointee-access-volatile \
; RUN:   -sanitizer-coverage-trace-pointee-access-atomic -S \
; RUN:   | grep -E '^ *(%[^ ]+ = )?(load|store|atomicrmw|cmpxchg) |^[a-z0-9_.]+:' | sed 's/, ![a-z]* ![0-9]*$//' > %t.after
; RUN: diff %t.before %t.after

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

%struct.inner = type { i32, i16 }
%struct.outer = type { i64, %struct.inner, [4 x i8] }

; A load is reported with the value it loaded, a store with the value it
; stored, both after the access. The pointer itself is still reported at entry
; by value only: the pass infers no snapshot from the accesses.
define i32 @direct(ptr %p, i32 %v) {
  %old = load i32, ptr %p, align 4
  store i32 %v, ptr %p, align 4
  ret i32 %old
}
; CHECK-LABEL: define i32 @direct(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %{{[0-9]+}}, ptr null, i32 0), !pcsections ![[DIRECT_PTR:[0-9]+]]
; CHECK: %old = load i32, ptr %p, align 4
; CHECK-NEXT: %[[F:[0-9]+]] = freeze i32 %old
; CHECK-NEXT: %[[Z:[0-9]+]] = zext i32 %[[F]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 4, i64 %[[Z]], ptr null, i32 0) #{{[0-9]+}}, !pcsections ![[DIRECT_LD:[0-9]+]]
; CHECK-NEXT: store i32 %v, ptr %p, align 4
; CHECK-NEXT: %[[SF:[0-9]+]] = freeze i32 %v
; CHECK-NEXT: %[[S:[0-9]+]] = zext i32 %[[SF]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 4, i64 %[[S]], ptr null, i32 0) #{{[0-9]+}}, !pcsections ![[DIRECT_ST:[0-9]+]]
; CHECK-NEXT: ret i32 %old

; Constant offsets accumulate through GEP chains, into nested fields; a
; partial-width access is reported at its own width and offset.
define void @fields(ptr %o, i8 %b) {
  %in = getelementptr inbounds %struct.outer, ptr %o, i64 0, i32 1
  %f1 = getelementptr inbounds %struct.inner, ptr %in, i64 0, i32 1
  %x = load i16, ptr %f1, align 2
  %lo = getelementptr inbounds i8, ptr %o, i64 1
  store i8 %b, ptr %lo, align 1
  %arr = getelementptr inbounds %struct.outer, ptr %o, i64 0, i32 2, i64 3
  %y = load i8, ptr %arr, align 1
  ret void
}
; CHECK-LABEL: define void @fields(
; CHECK: %x = load i16
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 2, {{.*}}, !pcsections ![[FIELDS_X:[0-9]+]]
; CHECK: store i8 %b
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 1, {{.*}}, !pcsections ![[FIELDS_B:[0-9]+]]
; CHECK: %y = load i8
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 1, {{.*}}, !pcsections ![[FIELDS_Y:[0-9]+]]

; container_of: a member pointer reaches the members before it.
define i64 @container_of(ptr %member) {
  %base = getelementptr inbounds i8, ptr %member, i64 -16
  %v = load i64, ptr %base, align 8
  ret i64 %v
}
; CHECK-LABEL: define i64 @container_of(
; CHECK: %v = load i64
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, {{.*}}, !pcsections ![[CONTAINER:[0-9]+]]

; Wider than a word: 8-byte pieces in memory order, numbered, at their own
; offsets; floating-point and vector pieces keep their class; a first-class
; aggregate is reported element by element.
define void @wide(ptr %p, <4 x float> %v, { i64, double, i32 } %s, x86_fp80 %e) {
  %w = load i128, ptr %p, align 16
  %pv = getelementptr inbounds i8, ptr %p, i64 16
  store <4 x float> %v, ptr %pv, align 16
  %ps = getelementptr inbounds i8, ptr %p, i64 32
  store { i64, double, i32 } %s, ptr %ps, align 8
  %pe = getelementptr inbounds i8, ptr %p, i64 64
  store x86_fp80 %e, ptr %pe, align 16
  ret void
}
; CHECK-LABEL: define void @wide(
; CHECK: %w = load i128, ptr %p
; CHECK-NEXT: %[[WF:[0-9]+]] = freeze i128 %w
; CHECK-NEXT: %[[W0:[0-9]+]] = trunc i128 %[[WF]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, i64 %[[W0]], {{.*}}, !pcsections ![[WIDE_W0:[0-9]+]]
; CHECK-NEXT: %[[WS:[0-9]+]] = lshr i128 %[[WF]], 64
; CHECK-NEXT: %[[W1:[0-9]+]] = trunc i128 %[[WS]] to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, i64 %[[W1]], {{.*}}, !pcsections ![[WIDE_W1:[0-9]+]]
; CHECK: store <4 x float> %v
; CHECK: bitcast <4 x float> %{{[0-9]+}} to i128
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 8, {{.*}}, !pcsections ![[WIDE_V0:[0-9]+]]
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 8, {{.*}}, !pcsections ![[WIDE_V1:[0-9]+]]
; CHECK: store { i64, double, i32 } %s
; CHECK: extractvalue { i64, double, i32 } %s, 0
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 8, {{.*}}, !pcsections ![[WIDE_S0:[0-9]+]]
; CHECK: extractvalue { i64, double, i32 } %s, 1
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 8, {{.*}}, !pcsections ![[WIDE_S1:[0-9]+]]
; CHECK: extractvalue { i64, double, i32 } %s, 2
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 4, {{.*}}, !pcsections ![[WIDE_S2:[0-9]+]]
; CHECK: store x86_fp80 %e
; CHECK: bitcast x86_fp80 %{{[0-9]+}} to i80
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 8, {{.*}}, !pcsections ![[WIDE_E0:[0-9]+]]
; CHECK: trunc i80 %{{[0-9]+}} to i16
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 2, {{.*}}, !pcsections ![[WIDE_E1:[0-9]+]]
; CHECK-NEXT: ret void

; More than eight pieces is not reported, nor is a scalable vector.
define void @too_wide(ptr %p, <vscale x 2 x i64> %sv) {
  %big = load [9 x i64], ptr %p, align 8
  %bigint = load i576, ptr %p, align 8
  store <vscale x 2 x i64> %sv, ptr %p, align 16
  ret void
}
; CHECK-LABEL: define void @too_wide(
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void

; Floating-point values are reported by their bits, as class float.
define double @floats(ptr %p, float %f) {
  %d = load double, ptr %p, align 8
  %pf = getelementptr inbounds i8, ptr %p, i64 8
  store float %f, ptr %pf, align 4
  ret double %d
}
; CHECK-LABEL: define double @floats(
; CHECK: %d = load double
; CHECK: bitcast double %{{[0-9]+}} to i64
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, {{.*}}, !pcsections ![[FLOAT_D:[0-9]+]]
; CHECK: store float %f
; CHECK: bitcast float %{{[0-9]+}} to i32
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 4, {{.*}}, !pcsections ![[FLOAT_F:[0-9]+]]

; A conditional access is reported in its own block, only when it executes,
; and a repeated access every time.
define i32 @conditional(ptr %p, i1 %c) {
entry:
  br i1 %c, label %then, label %done
then:
  %a = load i32, ptr %p, align 4
  %b = load i32, ptr %p, align 4
  %s = add i32 %a, %b
  br label %done
done:
  %r = phi i32 [ 0, %entry ], [ %s, %then ]
  ret i32 %r
}
; CHECK-LABEL: define i32 @conditional(
; CHECK: entry:
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: then:
; CHECK-NEXT: %a = load i32
; CHECK-NEXT: freeze
; CHECK-NEXT: zext
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 4,
; CHECK-NEXT: %b = load i32
; CHECK-NEXT: freeze
; CHECK-NEXT: zext
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 4,
; CHECK-NEXT: %s = add
; CHECK: done:
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret i32

; Volatile and atomic accesses are left alone by default. With their options,
; the value of the original access is reported, the access unchanged; the kind
; byte carries the ordering. Read-modify-write and compare-exchange are never
; reported: their old value is not a plain load of the location, and the
; stored value is not an SSA value of the program.
define void @volatile_atomic(ptr %p, i32 %v) {
  %vl = load volatile i32, ptr %p, align 4
  store volatile i32 %v, ptr %p, align 4
  %al = load atomic i32, ptr %p acquire, align 4
  store atomic i32 %v, ptr %p release, align 4
  %rmw = atomicrmw add ptr %p, i32 1 seq_cst, align 4
  %cx = cmpxchg ptr %p, i32 0, i32 %v seq_cst seq_cst, align 4
  ret void
}
; CHECK-LABEL: define void @volatile_atomic(
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void
; ALL-LABEL: define void @volatile_atomic(
; ALL: %vl = load volatile i32, ptr %p, align 4
; ALL: call void @__sanitizer_cov_trace_args(i32 -2147352576, i32 4, {{.*}}, !pcsections ![[VOL_LD:[0-9]+]]
; ALL-NEXT: store volatile i32 %v, ptr %p, align 4
; ALL: call void @__sanitizer_cov_trace_args(i32 -2147287040, i32 4, {{.*}}, !pcsections ![[VOL_ST:[0-9]+]]
; ALL-NEXT: %al = load atomic i32, ptr %p acquire, align 4
; ALL: call void @__sanitizer_cov_trace_args(i32 -2143027200, i32 4, {{.*}}, !pcsections ![[AT_LD:[0-9]+]]
; ALL-NEXT: store atomic i32 %v, ptr %p release, align 4
; ALL: call void @__sanitizer_cov_trace_args(i32 -2141913088, i32 4, {{.*}}, !pcsections ![[AT_ST:[0-9]+]]
; ALL-NEXT: %rmw = atomicrmw add ptr %p, i32 1 seq_cst, align 4
; ALL-NEXT: %cx = cmpxchg ptr %p, i32 0, i32 %v seq_cst seq_cst, align 4
; ALL-NEXT: ret void

; No SSA value, no record: memcpy, memset and inline assembly are not
; reported, and nothing is read to recover their values.
define void @no_value(ptr %dst, ptr %src) {
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %src, i64 16, i1 false)
  call void @llvm.memset.p0.i64(ptr %dst, i8 0, i64 16, i1 false)
  %x = call i32 asm sideeffect "lock xaddl $0, $1", "=r,=*m,0,*m"(ptr elementtype(i32) %dst, i32 1, ptr elementtype(i32) %dst)
  ret void
}
; CHECK-LABEL: define void @no_value(
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void

; The address must be one argument at one offset: not either of two
; arguments, not a variable index, not a pointer loaded from memory, not an
; integer turned into a pointer, not another address space.
define void @rejected(ptr %p, ptr %q, i1 %c, i64 %i, ptr addrspace(1) %g) {
  %either = select i1 %c, ptr %p, ptr %q
  %a = load i32, ptr %either, align 4
  %idx = getelementptr inbounds i32, ptr %p, i64 %i
  %b = load i32, ptr %idx, align 4
  %inner = load ptr, ptr %q, align 8
  %c2 = load i32, ptr %inner, align 4
  %int = ptrtoint ptr %p to i64
  %back = inttoptr i64 %int to ptr
  %d = load i32, ptr %back, align 4
  %e = load i32, ptr addrspace(1) %g, align 4
  %cast = addrspacecast ptr addrspace(1) %g to ptr
  %f = load i32, ptr %cast, align 4
  ret void
}
; The load of %inner is itself an access through %q, a pointer value.
; CHECK-LABEL: define void @rejected(
; CHECK: %a = load i32
; CHECK-NEXT: %idx = getelementptr
; CHECK-NEXT: %b = load i32
; CHECK-NEXT: %inner = load ptr
; CHECK-NEXT: %[[I:[0-9]+]] = ptrtoint ptr %inner to i64
; CHECK-NEXT: call void @__sanitizer_cov_trace_args(i32 -2147483647, i32 8, {{.*}}, !pcsections ![[INNER:[0-9]+]]
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void

; PHIs and selects are followed when every incoming value is the same argument
; at the same offset, a PHI taking itself included; not when the offset
; differs, nor around a loop that advances the pointer.
define void @phis(ptr %p, i1 %c, i64 %n) {
entry:
  %f8 = getelementptr inbounds i8, ptr %p, i64 8
  br i1 %c, label %l, label %r
l:
  %fl = getelementptr inbounds i8, ptr %p, i64 8
  br label %join
r:
  br label %join
join:
  %same = phi ptr [ %fl, %l ], [ %f8, %r ]
  %differs = phi ptr [ %fl, %l ], [ %p, %r ]
  %sel = select i1 %c, ptr %f8, ptr %same
  %a = load i64, ptr %same, align 8
  %b = load i64, ptr %differs, align 8
  %s = load i64, ptr %sel, align 8
  br label %loop
loop:
  %self = phi ptr [ %p, %join ], [ %self, %loop ]
  %cur = phi ptr [ %p, %join ], [ %next, %loop ]
  %x = load i8, ptr %self, align 1
  %y = load i8, ptr %cur, align 1
  %next = getelementptr inbounds i8, ptr %cur, i64 1
  %k = icmp eq i8 %y, 0
  br i1 %k, label %exit, label %loop
exit:
  ret void
}
; CHECK-LABEL: define void @phis(
; CHECK: %a = load i64
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, {{.*}}, !pcsections ![[PHI_SAME:[0-9]+]]
; CHECK-NEXT: %b = load i64
; CHECK-NEXT: %s = load i64
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 8, {{.*}}, !pcsections ![[PHI_SAME]]
; CHECK: %x = load i8
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 1, {{.*}}, !pcsections ![[PHI_SELF:[0-9]+]]
; CHECK-NEXT: %y = load i8
; CHECK-NEXT: %next =
; CHECK: ret void

; Arguments the ABI passes the object itself in, or the return buffer, are
; reported as objects already; a swifterror slot is not memory of the
; program's; an access marked !nosanitize was emitted by another
; instrumentation.
define void @abi(ptr sret(%struct.inner) %r, ptr byval(%struct.inner) %b, ptr swifterror %e, ptr %p) {
  store i32 1, ptr %r, align 4
  %x = load i32, ptr %b, align 4
  store ptr null, ptr %e, align 8
  %y = load i32, ptr %p, align 4, !nosanitize !{}
  ret void
}
; CHECK-LABEL: define void @abi(
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void

; An explicit dereferenceable(N) pointer keeps its call-time snapshot
; (DF_Pointee) and gets access records as well, which are told apart by their
; descriptors.
define i32 @explicit(ptr dereferenceable(8) %p) {
  %v = load i32, ptr %p, align 4
  ret i32 %v
}
; CHECK-LABEL: define i32 @explicit(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %{{[0-9]+}}, ptr @__sancov_offsets_{{.*}}, i32 1), !pcsections ![[EXPL_SNAP:[0-9]+]]
; CHECK: %v = load i32
; CHECK: call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 4, {{.*}}, ptr null, i32 0) #{{[0-9]+}}, !pcsections ![[EXPL_ACC:[0-9]+]]

declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)

; An unused pointer is reported by value, flagged unused, and has no accesses.
define void @unused(ptr %p) {
  ret void
}
; CHECK-LABEL: define void @unused(
; CHECK: call void @__sanitizer_cov_trace_args(i32 0, i32 8, i64 %{{[0-9]+}}, ptr null, i32 0), !pcsections ![[UNUSED:[0-9]+]]
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; CHECK: ret void
; CHECK-DAG: ![[UNUSED]] = !{!"__sancov_dataflow", ![[UNUSED_D:[0-9]+]]}
; CHECK-DAG: ![[UNUSED_D]] = !{i8 1, i8 32, i8 2, i8 0, i16 0, i16 1, i16 0, i16 0, i32 8, i32 0}

; CHECK-DAG: ![[DIRECT_PTR]] = !{!"__sancov_dataflow", ![[DIRECT_PTR_D:[0-9]+]]}
; CHECK-DAG: ![[DIRECT_PTR_D]] = !{i8 1, i8 0, i8 2, i8 0, i16 0, i16 2, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[DIRECT_LD]] = !{!"__sancov_dataflow", ![[DIRECT_LD_D:[0-9]+]]}
; CHECK-DAG: ![[DIRECT_LD_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}
; CHECK-DAG: ![[DIRECT_ST]] = !{!"__sancov_dataflow", ![[DIRECT_ST_D:[0-9]+]]}
; CHECK-DAG: ![[DIRECT_ST_D]] = !{i8 2, i8 -128, i8 1, i8 1, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}
; CHECK-DAG: ![[FIELDS_X]] = !{!"__sancov_dataflow", ![[FIELDS_X_D:[0-9]+]]}
; CHECK-DAG: ![[FIELDS_X_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 2, i16 0, i16 2, i32 2, i32 12}
; CHECK-DAG: ![[FIELDS_B]] = !{!"__sancov_dataflow", ![[FIELDS_B_D:[0-9]+]]}
; CHECK-DAG: ![[FIELDS_B_D]] = !{i8 2, i8 -128, i8 1, i8 1, i16 0, i16 2, i16 0, i16 1, i32 1, i32 1}
; CHECK-DAG: ![[FIELDS_Y]] = !{!"__sancov_dataflow", ![[FIELDS_Y_D:[0-9]+]]}
; CHECK-DAG: ![[FIELDS_Y_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 2, i16 0, i16 1, i32 1, i32 19}
; CHECK-DAG: ![[CONTAINER]] = !{!"__sancov_dataflow", ![[CONTAINER_D:[0-9]+]]}
; CHECK-DAG: ![[CONTAINER_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 1, i16 0, i16 8, i32 8, i32 -16}
; CHECK-DAG: ![[WIDE_W0]] = !{!"__sancov_dataflow", ![[WIDE_W0_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_W0_D]] = !{i8 2, i8 -126, i8 1, i8 0, i16 0, i16 4, i16 0, i16 16, i32 8, i32 0}
; CHECK-DAG: ![[WIDE_W1]] = !{!"__sancov_dataflow", ![[WIDE_W1_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_W1_D]] = !{i8 2, i8 -126, i8 1, i8 0, i16 0, i16 4, i16 1, i16 16, i32 8, i32 8}
; CHECK-DAG: ![[WIDE_V0]] = !{!"__sancov_dataflow", ![[WIDE_V0_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_V0_D]] = !{i8 2, i8 -126, i8 4, i8 1, i16 0, i16 4, i16 0, i16 16, i32 8, i32 16}
; CHECK-DAG: ![[WIDE_V1]] = !{!"__sancov_dataflow", ![[WIDE_V1_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_V1_D]] = !{i8 2, i8 -126, i8 4, i8 1, i16 0, i16 4, i16 1, i16 16, i32 8, i32 24}
; CHECK-DAG: ![[WIDE_S0]] = !{!"__sancov_dataflow", ![[WIDE_S0_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_S0_D]] = !{i8 2, i8 -126, i8 1, i8 1, i16 0, i16 4, i16 0, i16 24, i32 8, i32 32}
; CHECK-DAG: ![[WIDE_S1]] = !{!"__sancov_dataflow", ![[WIDE_S1_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_S1_D]] = !{i8 2, i8 -126, i8 3, i8 1, i16 0, i16 4, i16 1, i16 24, i32 8, i32 40}
; CHECK-DAG: ![[WIDE_S2]] = !{!"__sancov_dataflow", ![[WIDE_S2_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_S2_D]] = !{i8 2, i8 -126, i8 1, i8 1, i16 0, i16 4, i16 2, i16 24, i32 4, i32 48}
; CHECK-DAG: ![[WIDE_E0]] = !{!"__sancov_dataflow", ![[WIDE_E0_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_E0_D]] = !{i8 2, i8 -126, i8 3, i8 1, i16 0, i16 4, i16 0, i16 10, i32 8, i32 64}
; CHECK-DAG: ![[WIDE_E1]] = !{!"__sancov_dataflow", ![[WIDE_E1_D:[0-9]+]]}
; CHECK-DAG: ![[WIDE_E1_D]] = !{i8 2, i8 -126, i8 3, i8 1, i16 0, i16 4, i16 1, i16 10, i32 2, i32 72}
; CHECK-DAG: ![[FLOAT_D]] = !{!"__sancov_dataflow", ![[FLOAT_D_D:[0-9]+]]}
; CHECK-DAG: ![[FLOAT_D_D]] = !{i8 2, i8 -128, i8 3, i8 0, i16 0, i16 2, i16 0, i16 8, i32 8, i32 0}
; CHECK-DAG: ![[FLOAT_F]] = !{!"__sancov_dataflow", ![[FLOAT_F_D:[0-9]+]]}
; CHECK-DAG: ![[FLOAT_F_D]] = !{i8 2, i8 -128, i8 3, i8 1, i16 0, i16 2, i16 0, i16 4, i32 4, i32 8}
; CHECK-DAG: ![[INNER]] = !{!"__sancov_dataflow", ![[INNER_D:[0-9]+]]}
; CHECK-DAG: ![[INNER_D]] = !{i8 2, i8 -128, i8 2, i8 0, i16 1, i16 5, i16 0, i16 8, i32 8, i32 0}
; CHECK-DAG: ![[PHI_SAME]] = !{!"__sancov_dataflow", ![[PHI_SAME_D:[0-9]+]]}
; CHECK-DAG: ![[PHI_SAME_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 3, i16 0, i16 8, i32 8, i32 8}
; CHECK-DAG: ![[PHI_SELF]] = !{!"__sancov_dataflow", ![[PHI_SELF_D:[0-9]+]]}
; CHECK-DAG: ![[PHI_SELF_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 3, i16 0, i16 1, i32 1, i32 0}
; CHECK-DAG: ![[EXPL_SNAP]] = !{!"__sancov_dataflow", ![[EXPL_SNAP_D:[0-9]+]]}
; CHECK-DAG: ![[EXPL_SNAP_D]] = !{i8 1, i8 64, i8 2, i8 0, i16 0, i16 1, i16 0, i16 0, i32 8, i32 0}
; CHECK-DAG: ![[EXPL_ACC]] = !{!"__sancov_dataflow", ![[EXPL_ACC_D:[0-9]+]]}
; CHECK-DAG: ![[EXPL_ACC_D]] = !{i8 2, i8 -128, i8 1, i8 0, i16 0, i16 1, i16 0, i16 4, i32 4, i32 0}

; Kinds: 2 volatile, 3 volatile store, 4 | acquire (4) << 4 = 68,
; 5 | release (5) << 4 = 85.
; ALL-DAG: ![[VOL_LD]] = !{!"__sancov_dataflow", ![[VOL_LD_D:[0-9]+]]}
; ALL-DAG: ![[VOL_LD_D]] = !{i8 2, i8 -128, i8 1, i8 2, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}
; ALL-DAG: ![[VOL_ST]] = !{!"__sancov_dataflow", ![[VOL_ST_D:[0-9]+]]}
; ALL-DAG: ![[VOL_ST_D]] = !{i8 2, i8 -128, i8 1, i8 3, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}
; ALL-DAG: ![[AT_LD]] = !{!"__sancov_dataflow", ![[AT_LD_D:[0-9]+]]}
; ALL-DAG: ![[AT_LD_D]] = !{i8 2, i8 -128, i8 1, i8 68, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}
; ALL-DAG: ![[AT_ST]] = !{!"__sancov_dataflow", ![[AT_ST_D:[0-9]+]]}
; ALL-DAG: ![[AT_ST_D]] = !{i8 2, i8 -128, i8 1, i8 85, i16 0, i16 2, i16 0, i16 4, i32 4, i32 0}

; The records of different accesses differ only in their descriptors, which
; code generation does not compare: they are nomerge, so that tail merging
; cannot give two of them one call site.
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args \
; RUN:   -sanitizer-coverage-trace-pointee-access -S | FileCheck %s --check-prefix=NOMERGE
; NOMERGE: call void @__sanitizer_cov_trace_args(i32 -2147483648, {{.*}}) #[[NM:[0-9]+]], !pcsections
; NOMERGE: attributes #[[NM]] = { nomerge }
