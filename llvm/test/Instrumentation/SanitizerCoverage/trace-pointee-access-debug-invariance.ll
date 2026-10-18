; Debug information must not decide which accesses are reported: instrumenting
; and then stripping debug information gives the module that stripping and then
; instrumenting gives, with every access option on, for what clang -O2 -g
; emits for the accesses of Inputs/trace-pointee-access-cases-*.ll on x86-64
; and AArch64, and for the argument shapes of the trace-args inputs.
;
; DEFINE: %{access} = -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret \
; DEFINE:   -sanitizer-coverage-trace-pointee-access -sanitizer-coverage-trace-pointee-access-volatile \
; DEFINE:   -sanitizer-coverage-trace-pointee-access-atomic
;
; RUN: opt < %S/Inputs/trace-pointee-access-cases-x86_64.ll -passes='module(sancov-module)' %{access} \
; RUN:   | opt -strip-debug -S -o %t.x86_64.instrumented-then-stripped.ll
; RUN: opt < %S/Inputs/trace-pointee-access-cases-x86_64.ll -strip-debug \
; RUN:   | opt -passes='module(sancov-module)' %{access} -S -o %t.x86_64.stripped-then-instrumented.ll
; RUN: diff %t.x86_64.instrumented-then-stripped.ll %t.x86_64.stripped-then-instrumented.ll
; RUN: opt < %S/Inputs/trace-pointee-access-cases-aarch64.ll -passes='module(sancov-module)' %{access} \
; RUN:   | opt -strip-debug -S -o %t.aarch64.instrumented-then-stripped.ll
; RUN: opt < %S/Inputs/trace-pointee-access-cases-aarch64.ll -strip-debug \
; RUN:   | opt -passes='module(sancov-module)' %{access} -S -o %t.aarch64.stripped-then-instrumented.ll
; RUN: diff %t.aarch64.instrumented-then-stripped.ll %t.aarch64.stripped-then-instrumented.ll
; RUN: opt < %S/Inputs/trace-args-cases-x86_64.ll -passes='module(sancov-module)' %{access} \
; RUN:   | opt -strip-debug -S -o %t.args.instrumented-then-stripped.ll
; RUN: opt < %S/Inputs/trace-args-cases-x86_64.ll -strip-debug \
; RUN:   | opt -passes='module(sancov-module)' %{access} -S -o %t.args.stripped-then-instrumented.ll
; RUN: diff %t.args.instrumented-then-stripped.ll %t.args.stripped-then-instrumented.ll
;
; With debug information, a record takes the line, column and scope of its
; access - here the one of an inlined callee's load - but not its Key
; Instructions atom, and nothing else from it.
; RUN: opt < %S/Inputs/trace-pointee-access-cases-x86_64.ll -passes='module(sancov-module)' %{access} -S \
; RUN:   | FileCheck %s
; CHECK-LABEL: define dso_local i32 @a01_fields(
; CHECK:      %y.i = getelementptr inbounds nuw i8, ptr %o, i64 12
; CHECK-NEXT: %[[Y:[0-9]+]] = load i16, ptr %y.i, align 4, !dbg ![[Y_LOC:[0-9]+]]
; CHECK:      call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 2, i64 %{{[0-9]+}}, ptr null, i32 0) #{{[0-9]+}}, !dbg ![[REC_LOC:[0-9]+]], !pcsections
; CHECK-DAG:  ![[HELPER:[0-9]+]] = distinct !DISubprogram(name: "helper"
; CHECK-DAG:  ![[Y_LOC]] = distinct !DILocation(line: 11, column: 16, scope: ![[HELPER]], inlinedAt: ![[AT:[0-9]+]], atomGroup: 1, atomRank: 3)
; CHECK-DAG:  ![[REC_LOC]] = !DILocation(line: 11, column: 16, scope: ![[HELPER]], inlinedAt: ![[AT]])
