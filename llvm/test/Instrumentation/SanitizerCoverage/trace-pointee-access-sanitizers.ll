; Access records are the program's own accesses, not what another
; instrumentation adds: run after AddressSanitizer or MemorySanitizer (as rustc
; runs SanitizerCoverage), the shadow accesses those emit are not reported,
; and the program's load and store still are, once each, after the check.
; Run before them (as clang runs it), the checks do not instrument the records.
;
; DEFINE: %{access} = -sanitizer-coverage-trace-args -sanitizer-coverage-trace-pointee-access
; RUN: opt < %s -passes='asan,module(sancov-module)' %{access} -S | FileCheck %s --check-prefixes=CHECK,ASAN
; RUN: opt < %s -passes='asan,module(sancov-module)' -asan-instrumentation-with-call-threshold=0 %{access} -S \
; RUN:   | FileCheck %s --check-prefixes=CHECK,ASANCALL
; RUN: opt < %s -passes='msan,module(sancov-module)' %{access} -S | FileCheck %s --check-prefixes=CHECK,MSAN
; RUN: opt < %s -passes='msan<kernel>,module(sancov-module)' %{access} -S | FileCheck %s --check-prefixes=CHECK,KMSAN
; RUN: opt < %s -passes='tsan-module,function(tsan),module(sancov-module)' %{access} -S | FileCheck %s --check-prefixes=CHECK
; RUN: opt < %s -passes='module(sancov-module),asan' -asan-instrumentation-with-call-threshold=0 %{access} -S \
; RUN:   | FileCheck %s --check-prefixes=CHECK,BEFORE

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i32 @f(ptr %p) sanitize_address sanitize_memory sanitize_thread {
entry:
  %v = load i32, ptr %p, align 4
  %q = getelementptr inbounds i8, ptr %p, i64 4
  store i32 %v, ptr %q, align 4
  ret i32 %v
}
; CHECK-LABEL: define i32 @f(
; ASAN:     load i8, ptr %{{[0-9]+}}
; ASANCALL: call void @__asan_load4(i64 %{{[0-9]+}})
; BEFORE:   call void @__asan_load4(i64 %{{[0-9]+}})
; CHECK:    %v = load i32, ptr %p, align 4
; CHECK:    call void @__sanitizer_cov_trace_args(i32 -2147483648, i32 4,
; MSAN:     %_msld = load i32, ptr %{{[0-9]+}}
; KMSAN:    call {{.*}} @__msan_metadata_ptr_for_load_4(
; KMSAN:    %_msld = load i32, ptr %{{[0-9]+}}
; BEFORE-NOT: call void @__asan_
; BEFORE:   call void @__asan_store4(i64 %{{[0-9]+}})
; CHECK:    store i32 %v, ptr %q, align 4
; CHECK:    call void @__sanitizer_cov_trace_args(i32 -2147418112, i32 4,
; CHECK-NOT: {{i32 -21[0-9]{8},}}
; BEFORE-NOT: call void @__asan_
; CHECK:    ret i32
