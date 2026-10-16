; !pcsections, independently of any user: every PC an MDNode labels gets an
; entry of its own - the PC, then all auxiliary data the node lists after the
; section name - in instruction order, whatever the order of the nodes, and
; for instructions sharing a node too. That holds for plain instructions, for
; calls with and without a result, invokes, a node naming several sections
; and several auxiliary tuples, and the ULEB128 option; with every instruction
; selector (-O0 is GlobalISel, -O0 -global-isel=0 FastISel), the PC entry 64
; bits wide in the large code model.
;
; RUN: llc -mtriple=aarch64-unknown-linux-gnu -O0 < %s | FileCheck %s --check-prefixes=CHECK,SMALL
; RUN: llc -mtriple=aarch64-unknown-linux-gnu -O0 -global-isel=0 < %s | FileCheck %s --check-prefixes=CHECK,SMALL
; RUN: llc -mtriple=aarch64-unknown-linux-gnu -O2 < %s | FileCheck %s --check-prefixes=CHECK,SMALL
; RUN: llc -mtriple=aarch64-unknown-linux-gnu -O2 -code-model=large < %s | FileCheck %s --check-prefixes=CHECK,LARGE
;
; In an object, one relocated PC per labelled instruction, and sections whose
; size is the sum of their entries.
; RUN: llc -mtriple=aarch64-unknown-linux-gnu -O2 -filetype=obj < %s -o %t.o
; RUN: llvm-readobj --sections --relocations %t.o | FileCheck %s --check-prefix=OBJ

; Entries follow the instructions, not the nodes: sec_a, sec_b, sec_a.
; CHECK-LABEL: order:
; CHECK:       [[O0:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    ldr
; CHECK:       [[O1:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    {{ldr|add}}
; CHECK:       [[O2:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    {{ldr|add}}
; CHECK:         .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[O0]]-[[B]]
; LARGE-NEXT:  .xword [[O0]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK:         .section sec_b,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[O1]]-[[B]]
; LARGE-NEXT:  .xword [[O1]]-[[B]]
; CHECK-NEXT:    .xword 2
; CHECK:         .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[O2]]-[[B]]
; LARGE-NEXT:  .xword [[O2]]-[[B]]
; CHECK-NEXT:    .word 1

; One node, two instructions, two sections, two tuples for the first: each
; instruction gets all of it.
; CHECK-LABEL: multi:
; CHECK:       [[M0:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    str
; CHECK:       [[M1:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    str
; CHECK:         .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[M0]]-[[B]]
; LARGE-NEXT:  .xword [[M0]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK-NEXT:    .byte 7
; CHECK-NEXT:    .hword 8
; CHECK-NEXT:    .section sec_b,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[M0]]-[[B]]
; LARGE-NEXT:  .xword [[M0]]-[[B]]
; CHECK-NEXT:    .xword 2
; CHECK-NEXT:    .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[M1]]-[[B]]
; LARGE-NEXT:  .xword [[M1]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK-NEXT:    .byte 7
; CHECK-NEXT:    .hword 8
; CHECK-NEXT:    .section sec_b,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[M1]]-[[B]]
; LARGE-NEXT:  .xword [[M1]]-[[B]]
; CHECK-NEXT:    .xword 2

; Calls, with and without a result, are labelled at the call; the function's
; own entry keeps its [begin][size] encoding; ULEB128 compresses the data.
; CHECK-LABEL: calls:
; CHECK:       [[C0:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    bl callee
; CHECK:       [[C1:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    bl callee_ret
; CHECK:       [[C2:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    bl callee
; CHECK:         .section sec_f,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:    .word [[FB:.Lfunc_begin[0-9]+]]-[[B]]
; LARGE-NEXT:    .xword [[FB:.Lfunc_begin[0-9]+]]-[[B]]
; CHECK-NEXT:    .word {{.Lfunc_end[0-9]+}}-[[FB]]
; CHECK-NEXT:    .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[C0]]-[[B]]
; LARGE-NEXT:  .xword [[C0]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[C1]]-[[B]]
; LARGE-NEXT:  .xword [[C1]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK-NEXT:    .section sec_c,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[C2]]-[[B]]
; LARGE-NEXT:  .xword [[C2]]-[[B]]
; CHECK-NEXT:    .ascii "\254\002"
; CHECK-NEXT:    .ascii "\360\242\004"

; An invoke is a call too: the call is labelled, not the EH_LABELs around it
; or the branch to the normal destination.
; CHECK-LABEL: invokes:
; CHECK-NOT:   .Lpcsection{{[0-9]+}}:
; CHECK:       [[I0:.Lpcsection[0-9]+]]:
; CHECK-NEXT:    bl callee
; CHECK-NOT:   .Lpcsection{{[0-9]+}}:
; CHECK:         .section sec_a,"awo",@progbits,.text
; CHECK-NEXT:  [[B:.Lpcsection_base[0-9]+]]:
; SMALL-NEXT:  .word [[I0]]-[[B]]
; LARGE-NEXT:  .xword [[I0]]-[[B]]
; CHECK-NEXT:    .word 1
; CHECK-NOT:   .Lpcsection_base

; sec_a: 2 x (4 + 4) + 2 x (4 + 4 + 1 + 2) + 2 x (4 + 4) + (4 + 4) bytes for 7
; PCs; sec_b: 3 x (4 + 8) for 3; sec_c: 4 + 2 + 3 for 1; sec_f: 4 + 4.
; OBJ:      Name: sec_a
; OBJ:      Size: 62
; OBJ:      Name: sec_b
; OBJ:      Size: 36
; OBJ:      Name: sec_f
; OBJ:      Size: 8
; OBJ:      Name: sec_c
; OBJ:      Size: 9
; OBJ:      Section ({{[0-9]+}}) .relasec_a {
; OBJ-COUNT-7: R_{{[A-Z0-9_]+}} .text
; OBJ-NEXT: }
; OBJ:      Section ({{[0-9]+}}) .relasec_b {
; OBJ-COUNT-3: R_{{[A-Z0-9_]+}} .text
; OBJ-NEXT: }

declare void @callee(i64)
declare i64 @callee_ret(i64)
declare i32 @__gxx_personality_v0(...)

define i64 @order(ptr %p, ptr %q) {
entry:
  %a = load volatile i64, ptr %p, !pcsections !0
  %b = load volatile i64, ptr %q, !pcsections !2
  %c = load volatile i64, ptr %p, !pcsections !0
  %s = add i64 %a, %b
  %t = add i64 %s, %c
  ret i64 %t
}

define void @multi(ptr %p) {
entry:
  store volatile i64 1, ptr %p, !pcsections !4
  store volatile i64 2, ptr %p, !pcsections !4
  ret void
}

define void @calls(i64 %x) !pcsections !6 {
entry:
  call void @callee(i64 %x), !pcsections !0
  %r = call i64 @callee_ret(i64 %x), !pcsections !0
  call void @callee(i64 %r), !pcsections !7
  ret void
}

define void @invokes(i64 %x) personality ptr @__gxx_personality_v0 {
entry:
  invoke void @callee(i64 %x) to label %ok unwind label %lp, !pcsections !0
ok:
  ret void
lp:
  %l = landingpad { ptr, i32 } cleanup
  resume { ptr, i32 } %l
}

!0 = !{!"sec_a", !1}
!1 = !{i32 1}
!2 = !{!"sec_b", !3}
!3 = !{i64 2}
!4 = !{!"sec_a", !1, !5, !"sec_b", !3}
!5 = !{i8 7, i16 8}
!6 = !{!"sec_f"}
!7 = !{!"sec_c!C", !8}
!8 = !{i32 300, i64 70000}
