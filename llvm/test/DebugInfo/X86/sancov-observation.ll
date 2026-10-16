; The !sancov.dataflow attachment of SanitizerCoverage trace-args is lowered to
; DW_TAG_LLVM_sancov_observation children of the function's subprogram, each
; referring to the DIE of the parameter it maps an observation piece to.
;
; RUN: llc -mtriple=x86_64-linux-gnu -O2 -filetype=obj %s -o %t.o
; RUN: llvm-dwarfdump --debug-info %t.o | FileCheck %s
; RUN: llvm-dwarfdump --verify %t.o | FileCheck %s --check-prefix=VERIFY
; VERIFY: No errors.
;
; With split DWARF the observations go where the subprogram goes.
; RUN: llc -mtriple=x86_64-linux-gnu -O2 -filetype=obj -split-dwarf-file=%t.dwo -split-dwarf-output=%t.dwo %s -o %t.split.o
; RUN: llvm-dwarfdump --debug-info %t.dwo | FileCheck %s
; RUN: llvm-dwarfdump --debug-info %t.split.o | FileCheck %s --check-prefix=SKELETON
; SKELETON-NOT: DW_TAG_LLVM_sancov_observation
;
; The attachment refers to debug information, and goes with it.
; RUN: opt -strip-debug -S %s | FileCheck %s --check-prefix=STRIP
; RUN: opt -passes=strip-nonlinetable-debuginfo -S %s | FileCheck %s --check-prefix=STRIP
; STRIP-NOT: !sancov.dataflow
; STRIP-NOT: !DILocalVariable

; CHECK:      DW_TAG_subprogram
; CHECK:        DW_AT_name ("f")
; CHECK:      [[P:0x[0-9a-f]+]]: DW_TAG_formal_parameter
; CHECK:        DW_AT_name ("p")
; CHECK:      [[Q:0x[0-9a-f]+]]: DW_TAG_formal_parameter
; CHECK:        DW_AT_name ("q")
; CHECK:      DW_TAG_LLVM_sancov_observation
; CHECK-NEXT:   DW_AT_LLVM_sancov_ir_arg (0x00)
; CHECK-NEXT:   DW_AT_LLVM_sancov_element (0x00)
; CHECK-NEXT:   DW_AT_LLVM_sancov_variable ([[P]])
; CHECK-NEXT:   DW_AT_LLVM_sancov_source_arg (0x01)
; CHECK-NEXT:   DW_AT_data_bit_offset (0x40)
; CHECK-NEXT:   DW_AT_bit_size (0x40)
; CHECK:      DW_TAG_LLVM_sancov_observation
; CHECK-NEXT:   DW_AT_LLVM_sancov_ir_arg (0x01)
; CHECK-NEXT:   DW_AT_LLVM_sancov_element (0x02)
; CHECK-NEXT:   DW_AT_LLVM_sancov_variable ([[P]])
; CHECK-NEXT:   DW_AT_LLVM_sancov_source_arg (0x01)
; CHECK-NEXT:   DW_AT_LLVM_sancov_value_bit_offset (0x20)
; CHECK-NEXT:   DW_AT_data_bit_offset (0x00)
; CHECK-NEXT:   DW_AT_bit_size (0x20)
; CHECK:      DW_TAG_LLVM_sancov_observation
; CHECK-NEXT:   DW_AT_LLVM_sancov_ir_arg (0x02)
; CHECK-NEXT:   DW_AT_LLVM_sancov_element (0x00)
; CHECK-NEXT:   DW_AT_LLVM_sancov_variable ([[Q]])
; CHECK-NEXT:   DW_AT_LLVM_sancov_source_arg (0x02)
; CHECK-NEXT:   DW_AT_LLVM_sancov_indirect (true)
; An entry for a variable with no DIE in this subprogram is dropped.
; CHECK-NOT:  DW_TAG_LLVM_sancov_observation
; CHECK:      NULL

define void @f(i64 %a, [3 x i32] %b, ptr %c) !dbg !10 !sancov.dataflow !20 {
entry:
    #dbg_value(i64 %a, !13, !DIExpression(DW_OP_LLVM_fragment, 64, 64), !15)
    #dbg_value(ptr %c, !14, !DIExpression(DW_OP_deref), !15)
  ret void, !dbg !15
}

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!2, !3}

!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, isOptimized: true, emissionKind: FullDebug)
!1 = !DIFile(filename: "obs.c", directory: "/")
!2 = !{i32 7, !"Dwarf Version", i32 5}
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !DICompositeType(tag: DW_TAG_structure_type, name: "pair", file: !1, size: 128, elements: !{})
!10 = distinct !DISubprogram(name: "f", scope: !1, file: !1, line: 1, type: !11, scopeLine: 1, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !16)
!11 = !DISubroutineType(types: !12)
!12 = !{null, !4, !4}
!13 = !DILocalVariable(name: "p", arg: 1, scope: !10, file: !1, line: 1, type: !4)
!14 = !DILocalVariable(name: "q", arg: 2, scope: !10, file: !1, line: 1, type: !4)
!15 = !DILocation(line: 1, column: 1, scope: !10)
!16 = !{!13, !14}
!17 = distinct !DISubprogram(name: "other", scope: !1, file: !1, line: 9, type: !11, scopeLine: 9, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0)
!18 = !DILocalVariable(name: "o", arg: 1, scope: !17, file: !1, line: 9, type: !4)
!20 = !{!21, !22, !23, !24}
!21 = !{i32 0, i32 0, !13, i1 false, i64 0, i64 64, i64 64}
!22 = !{i32 1, i32 2, !13, i1 false, i64 32, i64 0, i64 32}
!23 = !{i32 2, i32 0, !14, i1 true, i64 0, i64 0, i64 0}
!24 = !{i32 1, i32 0, !18, i1 false, i64 0, i64 0, i64 32}
