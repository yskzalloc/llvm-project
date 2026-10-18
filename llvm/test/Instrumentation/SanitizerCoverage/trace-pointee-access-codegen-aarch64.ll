; Access records (AArch64 AAPCS64), compiled as clang -O2 -g compiles: debug
; information changes neither the machine code nor the descriptors, and the
; records add no memory access the program did not make. The input is
; Inputs/trace-pointee-access-cases-aarch64.ll; stripping its debug information
; stands in for the same source built without -g.
;
; REQUIRES: aarch64-registered-target
;
; DEFINE: %{access} = -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret \
; DEFINE:   -sanitizer-coverage-trace-pointee-access -sanitizer-coverage-trace-pointee-access-volatile \
; DEFINE:   -sanitizer-coverage-trace-pointee-access-atomic
; RUN: opt -passes='module(sancov-module)' %{access} %S/Inputs/trace-pointee-access-cases-aarch64.ll -o %t.g.bc
; RUN: opt -strip-debug %S/Inputs/trace-pointee-access-cases-aarch64.ll \
; RUN:   | opt -passes='module(sancov-module)' %{access} -o %t.nog.bc
; RUN: llc -O2 -filetype=obj -emit-call-site-info %t.g.bc -o %t.g.o
; RUN: llc -O2 -filetype=obj -emit-call-site-info %t.nog.bc -o %t.nog.o
; RUN: llvm-objcopy --dump-section=.text=%t.g.text --dump-section=__sancov_dataflow=%t.g.desc %t.g.o
; RUN: llvm-objcopy --dump-section=.text=%t.nog.text --dump-section=__sancov_dataflow=%t.nog.desc %t.nog.o
; RUN: cmp %t.g.text %t.nog.text
; RUN: cmp %t.g.desc %t.nog.desc
; RUN: llvm-objdump -r --section=__sancov_dataflow %t.g.o | sed 1,2d > %t.g.rel
; RUN: llvm-objdump -r --section=__sancov_dataflow %t.nog.o | sed 1,2d > %t.nog.rel
; RUN: diff %t.g.rel %t.nog.rel
;
; 22 argument and 21 access records, 17 returns: one descriptor of 24 bytes
; each. The source map describes the 22 arguments only.
; RUN: llvm-objdump -d -r %t.nog.o | FileCheck %s --check-prefix=CALLS
; CALLS-COUNT-43: R_{{[A-Z0-9_]+}} __sanitizer_cov_trace_args
; CALLS-NOT: __sanitizer_cov_trace_args
; RUN: llvm-readobj --sections %t.nog.o | FileCheck %s --check-prefix=DESC
; DESC:      Name: __sancov_dataflow
; DESC:      Size: 1440
; RUN: llvm-dwarfdump --debug-info %t.g.o | FileCheck %s --check-prefix=MAP
; MAP-COUNT-22: DW_TAG_LLVM_sancov_observation
; MAP-NOT:      DW_TAG_LLVM_sancov_observation
;
; Every memory access of the selected machine code that is not a stack slot
; is one of the program's, the same with and without access records: the
; records read nothing. (The instruction scheduler may order independent loads
; differently once calls separate them, so the accesses are compared as a
; set.) (A value the target cannot move to an
; integer register directly, such as a long double, is split through a stack
; slot, as it is for an argument value.)
; RUN: opt -strip-debug %S/Inputs/trace-pointee-access-cases-aarch64.ll \
; RUN:   | opt -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -o %t.base.bc
; RUN: llc -O2 -stop-after=finalize-isel %t.base.bc -o - | grep -oE ':: \(.*\)$' \
; RUN:   | grep -v '[%]stack\.\|[%]fixed-stack\.' | sed -E 's/, !tbaa ![0-9]+//' | sort > %t.base.mem
; RUN: llc -O2 -stop-after=finalize-isel %t.nog.bc -o - | grep -oE ':: \(.*\)$' \
; RUN:   | grep -v '[%]stack\.\|[%]fixed-stack\.' | sed -E 's/, !tbaa ![0-9]+//' | sort > %t.access.mem
; RUN: diff %t.base.mem %t.access.mem
; RUN: FileCheck %s --check-prefix=MEM --input-file=%t.access.mem
; MEM-DAG: :: (load (s32) from %ir.in
; MEM-DAG: :: (load (s16) from %ir.y.i
