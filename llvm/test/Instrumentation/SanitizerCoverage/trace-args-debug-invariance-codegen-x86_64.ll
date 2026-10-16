; Debug information must not change the machine code of trace-args/trace-ret
; (x86-64 SysV). The input is what clang -O2 -g emits for the argument shapes of
; Inputs/trace-args-cases-x86_64.ll; stripping its debug information first stands in
; for the same source built without -g. Code generation runs as clang runs it
; at -O2 -g, with call-site information.
;
; REQUIRES: x86-registered-target
;
; RUN: opt -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret \
; RUN:   %S/Inputs/trace-args-cases-x86_64.ll -o %t.g.bc
; RUN: opt -strip-debug %S/Inputs/trace-args-cases-x86_64.ll \
; RUN:   | opt -passes='module(sancov-module)' -sanitizer-coverage-trace-args -sanitizer-coverage-trace-ret -o %t.nog.bc
; RUN: llc -O2 -filetype=obj -emit-call-site-info %t.g.bc -o %t.g.o
; RUN: llc -O2 -filetype=obj -emit-call-site-info %t.nog.bc -o %t.nog.o
;
; The debug build has debug information, the other has none.
; RUN: llvm-readobj --sections %t.g.o | FileCheck %s --check-prefix=G
; RUN: llvm-readobj --sections %t.nog.o | FileCheck %s --check-prefix=NOG
; G: Name: .debug_info
; NOG-NOT: Name: .debug_
;
; .text is byte-identical, and so are the observation descriptors, one per
; trace call, and their relocations.
; RUN: llvm-objcopy --dump-section=.text=%t.g.text --dump-section=__sancov_dataflow=%t.g.desc %t.g.o
; RUN: llvm-objcopy --dump-section=.text=%t.nog.text --dump-section=__sancov_dataflow=%t.nog.desc %t.nog.o
; RUN: cmp %t.g.text %t.nog.text
; RUN: cmp %t.g.desc %t.nog.desc
; RUN: llvm-objdump -r --section=__sancov_dataflow %t.g.o | sed 1,2d > %t.g.rel
; RUN: llvm-objdump -r --section=__sancov_dataflow %t.nog.o | sed 1,2d > %t.nog.rel
; RUN: diff %t.g.rel %t.nog.rel
; RUN: llvm-readobj --sections %t.nog.o | FileCheck %s --check-prefix=DESC
; DESC:      Name: __sancov_dataflow
; DESC-NEXT: Type: SHT_PROGBITS
; DESC-NEXT: Flags [
; DESC-NEXT:   SHF_ALLOC
; DESC-NEXT:   SHF_LINK_ORDER
; DESC-NEXT:   SHF_WRITE
; DESC-NEXT: ]
; DESC:      Size: 1248
;
; The source map is debug information: present with it, absent without it,
; and the only DWARF that refers to the trace calls' observations.
; RUN: llvm-dwarfdump --debug-info %t.g.o | FileCheck %s --check-prefix=MAP
; MAP-COUNT-36: DW_TAG_LLVM_sancov_observation
; MAP-NOT:       DW_TAG_LLVM_sancov_observation
;
; Stripping debug information from the object keeps the descriptors whole.
; RUN: llvm-objcopy --strip-debug %t.g.o %t.stripped.o
; RUN: llvm-readobj --sections %t.stripped.o | FileCheck %s --check-prefix=NOG
; RUN: llvm-objcopy --dump-section=__sancov_dataflow=%t.stripped.desc %t.stripped.o
; RUN: cmp %t.g.desc %t.stripped.desc
;
; And it does trace: the same calls in both, one per IR argument or
; first-class aggregate element, and one per return.
; RUN: llvm-objdump -d -r %t.g.o | FileCheck %s --check-prefix=ARGS
; RUN: llvm-objdump -d -r %t.nog.o | FileCheck %s --check-prefix=ARGS
; RUN: llvm-objdump -d -r %t.g.o | FileCheck %s --check-prefix=RET
; RUN: llvm-objdump -d -r %t.nog.o | FileCheck %s --check-prefix=RET
; ARGS-COUNT-36: R_{{[A-Z0-9_]+}} __sanitizer_cov_trace_args
; ARGS-NOT: __sanitizer_cov_trace_args
; RET-COUNT-16: R_{{[A-Z0-9_]+}} __sanitizer_cov_trace_ret
; RET-NOT: __sanitizer_cov_trace_ret
