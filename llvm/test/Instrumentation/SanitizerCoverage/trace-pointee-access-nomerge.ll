; Two stores in two branches, then a shared return: without nomerge on their
; records, tail merging gives both records one call instruction - one PC, one
; descriptor - after setting up different arguments for it. Each keeps its
; own call, and its own descriptor.
;
; REQUIRES: x86-registered-target, aarch64-registered-target
; RUN: opt < %s -passes='module(sancov-module)' -sanitizer-coverage-trace-args \
; RUN:   -sanitizer-coverage-trace-ret -sanitizer-coverage-trace-pointee-access -o %t.bc
; RUN: llc -O2 -filetype=obj %t.bc -o %t.x86_64.o
; RUN: llc -O2 -filetype=obj -mtriple=aarch64-linux-gnu %t.bc -o %t.aarch64.o
; RUN: llvm-objdump -d -r %t.x86_64.o | FileCheck %s
; RUN: llvm-objdump -d -r %t.aarch64.o | FileCheck %s
; RUN: llvm-readobj --sections %t.x86_64.o | FileCheck %s --check-prefix=DESC
; RUN: llvm-readobj --sections %t.aarch64.o | FileCheck %s --check-prefix=DESC
;
; Three argument records and two access records; one return record.
; CHECK-COUNT-5: R_{{[A-Z0-9_]+}} __sanitizer_cov_trace_args
; CHECK-NOT:     __sanitizer_cov_trace_args
; DESC:      Name: __sancov_dataflow
; DESC:      Size: 144

target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define i32 @f(ptr %p, i64 %v, i1 %c) {
entry:
  br i1 %c, label %a, label %b
a:
  %q = getelementptr inbounds i8, ptr %p, i64 8
  store i64 %v, ptr %q, align 8
  br label %done
b:
  %r = getelementptr inbounds i8, ptr %p, i64 16
  %t = trunc i64 %v to i32
  store i32 %t, ptr %r, align 4
  br label %done
done:
  ret i32 0
}
