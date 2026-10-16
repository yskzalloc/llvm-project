; !pcsections of a call label the call instruction itself, with every
; instruction selector: SelectionDAG at -O2 and the fast selector at -O0. A
; call without a result has no value to carry the metadata through SelectionDAG,
; and the copies that set up the arguments are not labelled. -O0 selects with
; GlobalISel, -O0 -global-isel=0 with FastISel.
;
; Each PC is followed by its own copy of the auxiliary data, also for calls that
; share one MDNode, and the entries are in instruction order.
;
; RUN: llc -mtriple=aarch64-linux-gnu -O0 < %s | FileCheck %s
; RUN: llc -mtriple=aarch64-linux-gnu -O0 -global-isel=0 < %s | FileCheck %s
; RUN: llc -mtriple=aarch64-linux-gnu -O2 < %s | FileCheck %s
; RUN: llc -mtriple=aarch64-linux-gnu -O2 -filetype=obj < %s -o %t.o
; RUN: llvm-readobj --sections %t.o | FileCheck %s --check-prefix=OBJ

declare void @callee(i32)
declare i32 @callee_ret(i32)

define void @calls(i32 %x) {
; CHECK-LABEL: calls:
; CHECK-NOT:   .Lpcsection
; CHECK:       .Lpcsection0:
; CHECK-NEXT:    bl	callee
; CHECK-NOT:   .Lpcsection
; CHECK:       .Lpcsection1:
; CHECK-NEXT:    bl	callee
; CHECK-NOT:   .Lpcsection
; CHECK:       .Lpcsection2:
; CHECK-NEXT:    bl	callee_ret
; CHECK-NOT:   .Lpcsection
; CHECK:       .Lpcsection3:
; CHECK-NEXT:    bl	callee
; CHECK-NOT:   .Lpcsection
; CHECK:         .section foo,"awo",@progbits,.text
; CHECK-NEXT:  .Lpcsection_base0:
; CHECK-NEXT:    .word .Lpcsection0-.Lpcsection_base0
; CHECK-NEXT:    .word 10
; CHECK-NEXT:  .Lpcsection_base1:
; CHECK-NEXT:    .word .Lpcsection1-.Lpcsection_base1
; CHECK-NEXT:    .word 10
; CHECK-NEXT:  .Lpcsection_base2:
; CHECK-NEXT:    .word .Lpcsection2-.Lpcsection_base2
; CHECK-NEXT:    .word 20
; CHECK-NEXT:  .Lpcsection_base3:
; CHECK-NEXT:    .word .Lpcsection3-.Lpcsection_base3
; CHECK-NEXT:    .word 30
; CHECK-NOT:   .Lpcsection_base
entry:
  call void @callee(i32 %x), !pcsections !0
  call void @callee(i32 1), !pcsections !0
  %r = call i32 @callee_ret(i32 2), !pcsections !2
  call void @callee(i32 %r), !pcsections !4
  ret void
}

; OBJ:      Name: foo
; OBJ:      Size: 32

!0 = !{!"foo", !1}
!1 = !{i32 10}
!2 = !{!"foo", !3}
!3 = !{i32 20}
!4 = !{!"foo", !5}
!5 = !{i32 30}
