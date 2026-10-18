; The accesses of access-cases.c below, as clang -O2 -g emits them for
; aarch64-linux-gnu.
;
; // Accesses through pointer arguments, for -sanitizer-coverage-trace-pointee-access.
; struct inner { int x; short y; };
; struct outer { long id; struct inner in; unsigned char tag[4]; double d; };
; struct node { struct node *next; int val; };
; struct big { long a, b, c, d; };
; struct list_head { struct list_head *next, *prev; };
; struct item { int key; struct list_head link; };
; struct bits { unsigned a : 3, b : 5; };
;
; static inline __attribute__((always_inline)) int helper(struct outer *o) {
;   return o->in.y;
; }
;
; int a01_fields(struct outer *o) { return o->in.x + helper(o) + o->tag[3]; }
; void a02_update(struct outer *o, int v) { o->in.x = v; o->d = v * 2.0; }
; int a03_counter(struct outer *o) { o->id++; return (int)o->id; }
; int a04_cond(struct outer *o, int c) { return c ? o->in.x : 0; }
; int a05_walk(struct node *n) {
;   int s = 0;
;   for (; n; n = n->next)
;     s += n->val;
;   return s;
; }
; int a06_container_of(struct list_head *l) {
;   struct item *it =
;       (struct item *)((char *)l - __builtin_offsetof(struct item, link));
;   return it->key;
; }
; void a07_copy_big(struct big *dst, const struct big *src) { *dst = *src; }
; int a08_volatile(volatile int *p) { return *p; }
; long a09_acquire(long *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
; void a10_release(long *p, long v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
; long a11_fetch_add(long *p) { return __atomic_fetch_add(p, 1, __ATOMIC_SEQ_CST); }
; unsigned a12_bitfield(struct bits *p) { return p->b; }
; int a13_static(int a[static 4]) { return a[1] + a[2]; }
; __int128 a14_int128(__int128 *p) { return *p; }
; long double a15_long_double(long double *p) { return *p; }
; int a16_index(int *a, int i) { return a[i]; }
; void a17_out(struct inner *out) { out->x = 1; out->y = 2; }
source_filename = "access-cases.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i8:8:32-i16:16:32-i64:64-i128:128-n32:64-S128-Fn32"
target triple = "aarch64-unknown-linux-gnu"

define dso_local i32 @a01_fields(ptr nofree noundef readonly captures(none) %o) local_unnamed_addr !dbg !35 {
entry:
    #dbg_value(ptr %o, !57, !DIExpression(), !58)
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !59
  %0 = load i32, ptr %in, align 8, !dbg !60, !tbaa !61
    #dbg_value(ptr %o, !67, !DIExpression(), !70)
  %y.i = getelementptr inbounds nuw i8, ptr %o, i64 12, !dbg !72
  %1 = load i16, ptr %y.i, align 4, !dbg !73, !tbaa !74
  %conv.i = sext i16 %1 to i32, !dbg !75
  %add = add nsw i32 %0, %conv.i, !dbg !76
  %arrayidx = getelementptr inbounds nuw i8, ptr %o, i64 19, !dbg !77
  %2 = load i8, ptr %arrayidx, align 1, !dbg !77, !tbaa !78
  %conv = zext i8 %2 to i32, !dbg !77
  %add1 = add nsw i32 %add, %conv, !dbg !79
  ret i32 %add1, !dbg !80
}

define dso_local void @a02_update(ptr nofree noundef writeonly captures(none) initializes((8, 12), (24, 32)) %o, i32 noundef %v) local_unnamed_addr !dbg !81 {
entry:
    #dbg_value(ptr %o, !85, !DIExpression(), !87)
    #dbg_value(i32 %v, !86, !DIExpression(), !87)
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !88
  store i32 %v, ptr %in, align 8, !dbg !89, !tbaa !61
  %conv = sitofp i32 %v to double, !dbg !90
  %mul = fmul nnan double %conv, 2.000000e+00, !dbg !91
  %d = getelementptr inbounds nuw i8, ptr %o, i64 24, !dbg !92
  store double %mul, ptr %d, align 8, !dbg !93, !tbaa !94
  ret void, !dbg !95
}

define dso_local i32 @a03_counter(ptr nofree noundef captures(none) %o) local_unnamed_addr !dbg !96 {
entry:
    #dbg_value(ptr %o, !98, !DIExpression(), !99)
  %0 = load i64, ptr %o, align 8, !dbg !100, !tbaa !101
  %inc = add nsw i64 %0, 1, !dbg !102
  store i64 %inc, ptr %o, align 8, !dbg !103, !tbaa !101
  %conv = trunc i64 %inc to i32, !dbg !104
  ret i32 %conv, !dbg !105
}

define dso_local i32 @a04_cond(ptr nofree noundef readonly captures(none) %o, i32 noundef %c) local_unnamed_addr !dbg !106 {
entry:
    #dbg_value(ptr %o, !110, !DIExpression(), !112)
    #dbg_value(i32 %c, !111, !DIExpression(), !112)
  %tobool.not = icmp eq i32 %c, 0, !dbg !113
  br i1 %tobool.not, label %cond.end, label %cond.true, !dbg !114

cond.true:                                        ; preds = %entry
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !115
  %0 = load i32, ptr %in, align 8, !dbg !116, !tbaa !61
  br label %cond.end, !dbg !117

cond.end:                                         ; preds = %entry, %cond.true
  %cond = phi i32 [ %0, %cond.true ], [ 0, %entry ], !dbg !118
  ret i32 %cond, !dbg !119
}

define dso_local i32 @a05_walk(ptr nofree noundef readonly captures(address_is_null) %n) local_unnamed_addr !dbg !120 {
entry:
    #dbg_value(ptr %n, !129, !DIExpression(), !131)
    #dbg_value(i32 0, !130, !DIExpression(), !131)
  %tobool.not4 = icmp eq ptr %n, null, !dbg !132
  br i1 %tobool.not4, label %for.end, label %for.body, !dbg !134

for.body:                                         ; preds = %entry, %for.body
  %s.06 = phi i32 [ %add, %for.body ], [ 0, %entry ]
  %n.addr.05 = phi ptr [ %1, %for.body ], [ %n, %entry ]
    #dbg_value(i32 %s.06, !130, !DIExpression(), !131)
    #dbg_value(ptr %n.addr.05, !129, !DIExpression(), !131)
  %val = getelementptr inbounds nuw i8, ptr %n.addr.05, i64 8, !dbg !135
  %0 = load i32, ptr %val, align 8, !dbg !135, !tbaa !137
  %add = add nsw i32 %0, %s.06, !dbg !141
    #dbg_value(i32 %add, !130, !DIExpression(), !131)
  %1 = load ptr, ptr %n.addr.05, align 8, !dbg !142, !tbaa !143
    #dbg_value(ptr %1, !129, !DIExpression(), !131)
  %tobool.not = icmp eq ptr %1, null, !dbg !144
  br i1 %tobool.not, label %for.end, label %for.body, !dbg !145, !llvm.loop !146

for.end:                                          ; preds = %for.body, %entry
  %s.0.lcssa = phi i32 [ 0, %entry ], [ %add, %for.body ], !dbg !131
  ret i32 %s.0.lcssa, !dbg !150
}

define dso_local i32 @a06_container_of(ptr nofree noundef readonly captures(none) %l) local_unnamed_addr !dbg !151 {
entry:
    #dbg_value(ptr %l, !155, !DIExpression(), !157)
  %add.ptr = getelementptr inbounds i8, ptr %l, i64 -8, !dbg !158
    #dbg_value(ptr %add.ptr, !156, !DIExpression(), !157)
  %0 = load i32, ptr %add.ptr, align 8, !dbg !159, !tbaa !160
  ret i32 %0, !dbg !164
}

define dso_local void @a07_copy_big(ptr nofree noundef writeonly captures(none) initializes((0, 32)) %dst, ptr nofree noundef readonly captures(none) %src) local_unnamed_addr !dbg !165 {
entry:
    #dbg_value(ptr %dst, !178, !DIExpression(), !180)
    #dbg_value(ptr %src, !179, !DIExpression(), !180)
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(32) %dst, ptr noundef nonnull align 8 dereferenceable(32) %src, i64 32, i1 false), !dbg !181, !tbaa.struct !182
  ret void, !dbg !184
}

declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg)

define dso_local i32 @a08_volatile(ptr nofree noundef captures(address) %p) local_unnamed_addr !dbg !185 {
entry:
    #dbg_value(ptr %p, !191, !DIExpression(), !192)
  %0 = load volatile i32, ptr %p, align 4, !dbg !193, !tbaa !194
  ret i32 %0, !dbg !195
}

define dso_local i64 @a09_acquire(ptr nofree noundef captures(none) %p) local_unnamed_addr !dbg !196 {
entry:
    #dbg_value(ptr %p, !201, !DIExpression(), !202)
  %0 = load atomic i64, ptr %p acquire, align 8, !dbg !203
  ret i64 %0, !dbg !204
}

define dso_local void @a10_release(ptr nofree noundef captures(none) %p, i64 noundef %v) local_unnamed_addr !dbg !205 {
entry:
    #dbg_value(ptr %p, !209, !DIExpression(), !211)
    #dbg_value(i64 %v, !210, !DIExpression(), !211)
  store atomic i64 %v, ptr %p release, align 8, !dbg !212
  ret void, !dbg !213
}

define dso_local i64 @a11_fetch_add(ptr nofree noundef captures(none) %p) local_unnamed_addr !dbg !214 {
entry:
    #dbg_value(ptr %p, !216, !DIExpression(), !217)
  %0 = atomicrmw add ptr %p, i64 1 seq_cst, align 8, !dbg !218
  ret i64 %0, !dbg !219
}

define dso_local range(i32 0, 32) i32 @a12_bitfield(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !220 {
entry:
    #dbg_value(ptr %p, !230, !DIExpression(), !231)
  %bf.load = load i8, ptr %p, align 4, !dbg !232
  %bf.lshr = lshr i8 %bf.load, 3, !dbg !233
  %bf.cast = zext nneg i8 %bf.lshr to i32, !dbg !234
  ret i32 %bf.cast, !dbg !235
}

define dso_local i32 @a13_static(ptr nofree noundef readonly align 4 captures(none) dereferenceable(16) %a) local_unnamed_addr !dbg !236 {
entry:
    #dbg_value(ptr %a, !241, !DIExpression(), !242)
  %arrayidx = getelementptr inbounds nuw i8, ptr %a, i64 4, !dbg !243
  %0 = load i32, ptr %arrayidx, align 4, !dbg !243, !tbaa !194
  %arrayidx1 = getelementptr inbounds nuw i8, ptr %a, i64 8, !dbg !244
  %1 = load i32, ptr %arrayidx1, align 4, !dbg !244, !tbaa !194
  %add = add nsw i32 %1, %0, !dbg !245
  ret i32 %add, !dbg !246
}

define dso_local i128 @a14_int128(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !247 {
entry:
    #dbg_value(ptr %p, !253, !DIExpression(), !254)
  %0 = load i128, ptr %p, align 16, !dbg !255, !tbaa !256
  ret i128 %0, !dbg !258
}

define dso_local fp128 @a15_long_double(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !259 {
entry:
    #dbg_value(ptr %p, !265, !DIExpression(), !266)
  %0 = load fp128, ptr %p, align 16, !dbg !267, !tbaa !268
  ret fp128 %0, !dbg !270
}

define dso_local i32 @a16_index(ptr nofree noundef readonly captures(none) %a, i32 noundef %i) local_unnamed_addr !dbg !271 {
entry:
    #dbg_value(ptr %a, !275, !DIExpression(), !277)
    #dbg_value(i32 %i, !276, !DIExpression(), !277)
  %idxprom = sext i32 %i to i64, !dbg !278
  %arrayidx = getelementptr inbounds [4 x i8], ptr %a, i64 %idxprom, !dbg !278
  %0 = load i32, ptr %arrayidx, align 4, !dbg !279, !tbaa !194
  ret i32 %0, !dbg !280
}

define dso_local void @a17_out(ptr nofree noundef writeonly captures(none) initializes((0, 6)) %out) local_unnamed_addr !dbg !281 {
entry:
    #dbg_value(ptr %out, !286, !DIExpression(), !287)
  store i32 1, ptr %out, align 4, !dbg !288, !tbaa !289
  %y = getelementptr inbounds nuw i8, ptr %out, i64 4, !dbg !290
  store i16 2, ptr %y, align 4, !dbg !291, !tbaa !292
  ret void, !dbg !293
}


!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!16, !17, !18, !19, !20, !21, !22, !23, !24, !25, !26, !27, !28, !29}
!llvm.errno.tbaa = !{!30}

!0 = distinct !DICompileUnit(language: DW_LANG_C11, file: !1, isOptimized: true, runtimeVersion: 0, emissionKind: FullDebug, retainedTypes: !2, splitDebugInlining: false, nameTableKind: None)
!1 = !DIFile(filename: "access-cases.c", directory: "/home/debian-sid/kcov-dataflow/pointee-access/cases", checksumkind: CSK_MD5, checksum: "67353d11f25f8e35dd4ac30eccc7954e")
!2 = !{!3, !4, !14}
!3 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!4 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !5, size: 64)
!5 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "item", file: !1, line: 7, size: 192, elements: !6)
!6 = !{!7, !8}
!7 = !DIDerivedType(tag: DW_TAG_member, name: "key", scope: !5, file: !1, line: 7, baseType: !3, size: 32)
!8 = !DIDerivedType(tag: DW_TAG_member, name: "link", scope: !5, file: !1, line: 7, baseType: !9, size: 128, offset: 64)
!9 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "list_head", file: !1, line: 6, size: 128, elements: !10)
!10 = !{!11, !13}
!11 = !DIDerivedType(tag: DW_TAG_member, name: "next", scope: !9, file: !1, line: 6, baseType: !12, size: 64)
!12 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !9, size: 64)
!13 = !DIDerivedType(tag: DW_TAG_member, name: "prev", scope: !9, file: !1, line: 6, baseType: !12, size: 64, offset: 64)
!14 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !15, size: 64)
!15 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_unsigned_char)
!16 = !{i32 7, !"Dwarf Version", i32 5}
!17 = !{i32 2, !"Debug Info Version", i32 3}
!18 = !{i32 1, !"long-double-type", !"fp128"}
!19 = !{i32 1, !"ptrauth-elf-got", i32 0}
!20 = !{i32 1, !"ptrauth-init-fini", i32 0}
!21 = !{i32 1, !"ptrauth-init-fini-address-discrimination", i32 0}
!22 = !{i32 1, !"ptrauth-sign-personality", i32 0}
!23 = !{i32 1, !"aarch64-elf-pauthabi-platform", i32 268435458}
!24 = !{i32 1, !"aarch64-elf-pauthabi-version", i32 0}
!25 = !{i32 8, !"PIC Level", i32 2}
!26 = !{i32 7, !"PIE Level", i32 2}
!27 = !{i32 7, !"uwtable", i32 2}
!28 = !{i32 7, !"frame-pointer", i32 4}
!29 = !{i32 7, !"debug-info-assignment-tracking", i1 true}
!30 = !{!31, !32, i64 0}
!31 = !{!"__libc_errno", !32, i64 0}
!32 = !{!"int", !33, i64 0}
!33 = !{!"omnipotent char", !34, i64 0}
!34 = !{!"Simple C/C++ TBAA"}
!35 = distinct !DISubprogram(name: "a01_fields", scope: !1, file: !1, line: 14, type: !36, scopeLine: 14, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !56, keyInstructions: true)
!36 = !DISubroutineType(types: !37)
!37 = !{!3, !38}
!38 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !39, size: 64)
!39 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "outer", file: !1, line: 3, size: 256, elements: !40)
!40 = !{!41, !43, !49, !54}
!41 = !DIDerivedType(tag: DW_TAG_member, name: "id", scope: !39, file: !1, line: 3, baseType: !42, size: 64)
!42 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!43 = !DIDerivedType(tag: DW_TAG_member, name: "in", scope: !39, file: !1, line: 3, baseType: !44, size: 64, offset: 64)
!44 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "inner", file: !1, line: 2, size: 64, elements: !45)
!45 = !{!46, !47}
!46 = !DIDerivedType(tag: DW_TAG_member, name: "x", scope: !44, file: !1, line: 2, baseType: !3, size: 32)
!47 = !DIDerivedType(tag: DW_TAG_member, name: "y", scope: !44, file: !1, line: 2, baseType: !48, size: 16, offset: 32)
!48 = !DIBasicType(name: "short", size: 16, encoding: DW_ATE_signed)
!49 = !DIDerivedType(tag: DW_TAG_member, name: "tag", scope: !39, file: !1, line: 3, baseType: !50, size: 32, offset: 128)
!50 = !DICompositeType(tag: DW_TAG_array_type, baseType: !51, size: 32, elements: !52)
!51 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!52 = !{!53}
!53 = !DISubrange(count: 4)
!54 = !DIDerivedType(tag: DW_TAG_member, name: "d", scope: !39, file: !1, line: 3, baseType: !55, size: 64, offset: 192)
!55 = !DIBasicType(name: "double", size: 64, encoding: DW_ATE_float)
!56 = !{!57}
!57 = !DILocalVariable(name: "o", arg: 1, scope: !35, file: !1, line: 14, type: !38)
!58 = !DILocation(line: 0, scope: !35)
!59 = !DILocation(line: 14, column: 45, scope: !35)
!60 = !DILocation(line: 14, column: 48, scope: !35)
!61 = !{!62, !32, i64 8}
!62 = !{!"outer", !63, i64 0, !64, i64 8, !33, i64 16, !66, i64 24}
!63 = !{!"long", !33, i64 0}
!64 = !{!"inner", !32, i64 0, !65, i64 4}
!65 = !{!"short", !33, i64 0}
!66 = !{!"double", !33, i64 0}
!67 = !DILocalVariable(name: "o", arg: 1, scope: !68, file: !1, line: 10, type: !38)
!68 = distinct !DISubprogram(name: "helper", scope: !1, file: !1, line: 10, type: !36, scopeLine: 10, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !69, keyInstructions: true)
!69 = !{!67}
!70 = distinct !DILocation(line: 0, scope: !68, inlinedAt: !71)
!71 = distinct !DILocation(line: 14, column: 52, scope: !35)
!72 = distinct !DILocation(line: 11, column: 16, scope: !68, inlinedAt: !71)
!73 = distinct !DILocation(line: 11, column: 16, scope: !68, inlinedAt: !71, atomGroup: 1, atomRank: 3)
!74 = !{!62, !65, i64 12}
!75 = distinct !DILocation(line: 11, column: 10, scope: !68, inlinedAt: !71, atomGroup: 1, atomRank: 2)
!76 = !DILocation(line: 14, column: 50, scope: !35)
!77 = !DILocation(line: 14, column: 64, scope: !35)
!78 = !{!33, !33, i64 0}
!79 = !DILocation(line: 14, column: 62, scope: !35, atomGroup: 1, atomRank: 2)
!80 = !DILocation(line: 14, column: 35, scope: !35, atomGroup: 1, atomRank: 1)
!81 = distinct !DISubprogram(name: "a02_update", scope: !1, file: !1, line: 15, type: !82, scopeLine: 15, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !84, keyInstructions: true)
!82 = !DISubroutineType(types: !83)
!83 = !{null, !38, !3}
!84 = !{!85, !86}
!85 = !DILocalVariable(name: "o", arg: 1, scope: !81, file: !1, line: 15, type: !38)
!86 = !DILocalVariable(name: "v", arg: 2, scope: !81, file: !1, line: 15, type: !3)
!87 = !DILocation(line: 0, scope: !81)
!88 = !DILocation(line: 15, column: 46, scope: !81)
!89 = !DILocation(line: 15, column: 51, scope: !81, atomGroup: 1, atomRank: 1)
!90 = !DILocation(line: 15, column: 63, scope: !81)
!91 = !DILocation(line: 15, column: 65, scope: !81, atomGroup: 2, atomRank: 2)
!92 = !DILocation(line: 15, column: 59, scope: !81)
!93 = !DILocation(line: 15, column: 61, scope: !81, atomGroup: 2, atomRank: 1)
!94 = !{!62, !66, i64 24}
!95 = !DILocation(line: 15, column: 72, scope: !81, atomGroup: 3, atomRank: 1)
!96 = distinct !DISubprogram(name: "a03_counter", scope: !1, file: !1, line: 16, type: !36, scopeLine: 16, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !97, keyInstructions: true)
!97 = !{!98}
!98 = !DILocalVariable(name: "o", arg: 1, scope: !96, file: !1, line: 16, type: !38)
!99 = !DILocation(line: 0, scope: !96)
!100 = !DILocation(line: 16, column: 41, scope: !96)
!101 = !{!62, !63, i64 0}
!102 = !DILocation(line: 16, column: 41, scope: !96, atomGroup: 1, atomRank: 2)
!103 = !DILocation(line: 16, column: 41, scope: !96, atomGroup: 1, atomRank: 1)
!104 = !DILocation(line: 16, column: 52, scope: !96, atomGroup: 2, atomRank: 2)
!105 = !DILocation(line: 16, column: 45, scope: !96, atomGroup: 2, atomRank: 1)
!106 = distinct !DISubprogram(name: "a04_cond", scope: !1, file: !1, line: 17, type: !107, scopeLine: 17, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !109, keyInstructions: true)
!107 = !DISubroutineType(types: !108)
!108 = !{!3, !38, !3}
!109 = !{!110, !111}
!110 = !DILocalVariable(name: "o", arg: 1, scope: !106, file: !1, line: 17, type: !38)
!111 = !DILocalVariable(name: "c", arg: 2, scope: !106, file: !1, line: 17, type: !3)
!112 = !DILocation(line: 0, scope: !106)
!113 = !DILocation(line: 17, column: 47, scope: !106, atomGroup: 2, atomRank: 2)
!114 = !DILocation(line: 17, column: 47, scope: !106, atomGroup: 2, atomRank: 1)
!115 = !DILocation(line: 17, column: 54, scope: !106)
!116 = !DILocation(line: 17, column: 57, scope: !106)
!117 = !DILocation(line: 17, column: 47, scope: !106)
!118 = !DILocation(line: 17, column: 47, scope: !106, atomGroup: 1, atomRank: 2)
!119 = !DILocation(line: 17, column: 40, scope: !106, atomGroup: 1, atomRank: 1)
!120 = distinct !DISubprogram(name: "a05_walk", scope: !1, file: !1, line: 18, type: !121, scopeLine: 18, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !128, keyInstructions: true)
!121 = !DISubroutineType(types: !122)
!122 = !{!3, !123}
!123 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !124, size: 64)
!124 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "node", file: !1, line: 4, size: 128, elements: !125)
!125 = !{!126, !127}
!126 = !DIDerivedType(tag: DW_TAG_member, name: "next", scope: !124, file: !1, line: 4, baseType: !123, size: 64)
!127 = !DIDerivedType(tag: DW_TAG_member, name: "val", scope: !124, file: !1, line: 4, baseType: !3, size: 32, offset: 64)
!128 = !{!129, !130}
!129 = !DILocalVariable(name: "n", arg: 1, scope: !120, file: !1, line: 18, type: !123)
!130 = !DILocalVariable(name: "s", scope: !120, file: !1, line: 19, type: !3)
!131 = !DILocation(line: 0, scope: !120)
!132 = !DILocation(line: 20, column: 3, scope: !133, atomGroup: 9, atomRank: 1)
!133 = distinct !DILexicalBlock(scope: !120, file: !1, line: 20, column: 3)
!134 = !DILocation(line: 20, column: 3, scope: !133, atomGroup: 10, atomRank: 1)
!135 = !DILocation(line: 21, column: 13, scope: !136)
!136 = distinct !DILexicalBlock(scope: !133, file: !1, line: 20, column: 3)
!137 = !{!138, !32, i64 8}
!138 = !{!"node", !139, i64 0, !32, i64 8}
!139 = !{!"p1 _ZTS4node", !140, i64 0}
!140 = !{!"any pointer", !33, i64 0}
!141 = !DILocation(line: 21, column: 7, scope: !136, atomGroup: 4, atomRank: 2)
!142 = !DILocation(line: 20, column: 20, scope: !136, atomGroup: 5, atomRank: 2)
!143 = !{!138, !139, i64 0}
!144 = !DILocation(line: 20, column: 3, scope: !133, atomGroup: 2, atomRank: 1)
!145 = !DILocation(line: 20, column: 3, scope: !133, atomGroup: 3, atomRank: 1)
!146 = distinct !{!146, !147, !148, !149}
!147 = !DILocation(line: 20, column: 3, scope: !133)
!148 = !DILocation(line: 21, column: 13, scope: !133)
!149 = !{!"llvm.loop.mustprogress"}
!150 = !DILocation(line: 22, column: 3, scope: !120, atomGroup: 8, atomRank: 1)
!151 = distinct !DISubprogram(name: "a06_container_of", scope: !1, file: !1, line: 24, type: !152, scopeLine: 24, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !154, keyInstructions: true)
!152 = !DISubroutineType(types: !153)
!153 = !{!3, !12}
!154 = !{!155, !156}
!155 = !DILocalVariable(name: "l", arg: 1, scope: !151, file: !1, line: 24, type: !12)
!156 = !DILocalVariable(name: "it", scope: !151, file: !1, line: 25, type: !4)
!157 = !DILocation(line: 0, scope: !151)
!158 = !DILocation(line: 26, column: 33, scope: !151, atomGroup: 1, atomRank: 2)
!159 = !DILocation(line: 27, column: 14, scope: !151, atomGroup: 3, atomRank: 2)
!160 = !{!161, !32, i64 0}
!161 = !{!"item", !32, i64 0, !162, i64 8}
!162 = !{!"list_head", !163, i64 0, !163, i64 8}
!163 = !{!"p1 _ZTS9list_head", !140, i64 0}
!164 = !DILocation(line: 27, column: 3, scope: !151, atomGroup: 3, atomRank: 1)
!165 = distinct !DISubprogram(name: "a07_copy_big", scope: !1, file: !1, line: 29, type: !166, scopeLine: 29, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !177, keyInstructions: true)
!166 = !DISubroutineType(types: !167)
!167 = !{null, !168, !175}
!168 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !169, size: 64)
!169 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "big", file: !1, line: 5, size: 256, elements: !170)
!170 = !{!171, !172, !173, !174}
!171 = !DIDerivedType(tag: DW_TAG_member, name: "a", scope: !169, file: !1, line: 5, baseType: !42, size: 64)
!172 = !DIDerivedType(tag: DW_TAG_member, name: "b", scope: !169, file: !1, line: 5, baseType: !42, size: 64, offset: 64)
!173 = !DIDerivedType(tag: DW_TAG_member, name: "c", scope: !169, file: !1, line: 5, baseType: !42, size: 64, offset: 128)
!174 = !DIDerivedType(tag: DW_TAG_member, name: "d", scope: !169, file: !1, line: 5, baseType: !42, size: 64, offset: 192)
!175 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !176, size: 64)
!176 = !DIDerivedType(tag: DW_TAG_const_type, baseType: !169)
!177 = !{!178, !179}
!178 = !DILocalVariable(name: "dst", arg: 1, scope: !165, file: !1, line: 29, type: !168)
!179 = !DILocalVariable(name: "src", arg: 2, scope: !165, file: !1, line: 29, type: !175)
!180 = !DILocation(line: 0, scope: !165)
!181 = !DILocation(line: 29, column: 68, scope: !165, atomGroup: 1, atomRank: 1)
!182 = !{i64 0, i64 8, !183, i64 8, i64 8, !183, i64 16, i64 8, !183, i64 24, i64 8, !183}
!183 = !{!63, !63, i64 0}
!184 = !DILocation(line: 29, column: 74, scope: !165, atomGroup: 2, atomRank: 1)
!185 = distinct !DISubprogram(name: "a08_volatile", scope: !1, file: !1, line: 30, type: !186, scopeLine: 30, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !190, keyInstructions: true)
!186 = !DISubroutineType(types: !187)
!187 = !{!3, !188}
!188 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !189, size: 64)
!189 = !DIDerivedType(tag: DW_TAG_volatile_type, baseType: !3)
!190 = !{!191}
!191 = !DILocalVariable(name: "p", arg: 1, scope: !185, file: !1, line: 30, type: !188)
!192 = !DILocation(line: 0, scope: !185)
!193 = !DILocation(line: 30, column: 44, scope: !185, atomGroup: 1, atomRank: 2)
!194 = !{!32, !32, i64 0}
!195 = !DILocation(line: 30, column: 37, scope: !185, atomGroup: 1, atomRank: 1)
!196 = distinct !DISubprogram(name: "a09_acquire", scope: !1, file: !1, line: 31, type: !197, scopeLine: 31, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !200, keyInstructions: true)
!197 = !DISubroutineType(types: !198)
!198 = !{!42, !199}
!199 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !42, size: 64)
!200 = !{!201}
!201 = !DILocalVariable(name: "p", arg: 1, scope: !196, file: !1, line: 31, type: !199)
!202 = !DILocation(line: 0, scope: !196)
!203 = !DILocation(line: 31, column: 36, scope: !196, atomGroup: 2, atomRank: 2)
!204 = !DILocation(line: 31, column: 29, scope: !196, atomGroup: 1, atomRank: 1)
!205 = distinct !DISubprogram(name: "a10_release", scope: !1, file: !1, line: 32, type: !206, scopeLine: 32, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !208, keyInstructions: true)
!206 = !DISubroutineType(types: !207)
!207 = !{null, !199, !42}
!208 = !{!209, !210}
!209 = !DILocalVariable(name: "p", arg: 1, scope: !205, file: !1, line: 32, type: !199)
!210 = !DILocalVariable(name: "v", arg: 2, scope: !205, file: !1, line: 32, type: !42)
!211 = !DILocation(line: 0, scope: !205)
!212 = !DILocation(line: 32, column: 37, scope: !205, atomGroup: 1, atomRank: 1)
!213 = !DILocation(line: 32, column: 79, scope: !205, atomGroup: 2, atomRank: 1)
!214 = distinct !DISubprogram(name: "a11_fetch_add", scope: !1, file: !1, line: 33, type: !197, scopeLine: 33, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !215, keyInstructions: true)
!215 = !{!216}
!216 = !DILocalVariable(name: "p", arg: 1, scope: !214, file: !1, line: 33, type: !199)
!217 = !DILocation(line: 0, scope: !214)
!218 = !DILocation(line: 33, column: 38, scope: !214, atomGroup: 2, atomRank: 2)
!219 = !DILocation(line: 33, column: 31, scope: !214, atomGroup: 1, atomRank: 1)
!220 = distinct !DISubprogram(name: "a12_bitfield", scope: !1, file: !1, line: 34, type: !221, scopeLine: 34, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !229, keyInstructions: true)
!221 = !DISubroutineType(types: !222)
!222 = !{!223, !224}
!223 = !DIBasicType(name: "unsigned int", size: 32, encoding: DW_ATE_unsigned)
!224 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !225, size: 64)
!225 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "bits", file: !1, line: 8, size: 32, elements: !226)
!226 = !{!227, !228}
!227 = !DIDerivedType(tag: DW_TAG_member, name: "a", scope: !225, file: !1, line: 8, baseType: !223, size: 3, flags: DIFlagBitField, extraData: i64 0)
!228 = !DIDerivedType(tag: DW_TAG_member, name: "b", scope: !225, file: !1, line: 8, baseType: !223, size: 5, offset: 3, flags: DIFlagBitField, extraData: i64 0)
!229 = !{!230}
!230 = !DILocalVariable(name: "p", arg: 1, scope: !220, file: !1, line: 34, type: !224)
!231 = !DILocation(line: 0, scope: !220)
!232 = !DILocation(line: 34, column: 51, scope: !220)
!233 = !DILocation(line: 34, column: 51, scope: !220, atomGroup: 1, atomRank: 3)
!234 = !DILocation(line: 34, column: 51, scope: !220, atomGroup: 1, atomRank: 2)
!235 = !DILocation(line: 34, column: 41, scope: !220, atomGroup: 1, atomRank: 1)
!236 = distinct !DISubprogram(name: "a13_static", scope: !1, file: !1, line: 35, type: !237, scopeLine: 35, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !240, keyInstructions: true)
!237 = !DISubroutineType(types: !238)
!238 = !{!3, !239}
!239 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !3, size: 64)
!240 = !{!241}
!241 = !DILocalVariable(name: "a", arg: 1, scope: !236, file: !1, line: 35, type: !239)
!242 = !DILocation(line: 0, scope: !236)
!243 = !DILocation(line: 35, column: 42, scope: !236)
!244 = !DILocation(line: 35, column: 49, scope: !236)
!245 = !DILocation(line: 35, column: 47, scope: !236, atomGroup: 1, atomRank: 2)
!246 = !DILocation(line: 35, column: 35, scope: !236, atomGroup: 1, atomRank: 1)
!247 = distinct !DISubprogram(name: "a14_int128", scope: !1, file: !1, line: 36, type: !248, scopeLine: 36, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !252, keyInstructions: true)
!248 = !DISubroutineType(types: !249)
!249 = !{!250, !251}
!250 = !DIBasicType(name: "__int128", size: 128, encoding: DW_ATE_signed)
!251 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !250, size: 64)
!252 = !{!253}
!253 = !DILocalVariable(name: "p", arg: 1, scope: !247, file: !1, line: 36, type: !251)
!254 = !DILocation(line: 0, scope: !247)
!255 = !DILocation(line: 36, column: 43, scope: !247, atomGroup: 1, atomRank: 2)
!256 = !{!257, !257, i64 0}
!257 = !{!"__int128", !33, i64 0}
!258 = !DILocation(line: 36, column: 36, scope: !247, atomGroup: 1, atomRank: 1)
!259 = distinct !DISubprogram(name: "a15_long_double", scope: !1, file: !1, line: 37, type: !260, scopeLine: 37, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !264, keyInstructions: true)
!260 = !DISubroutineType(types: !261)
!261 = !{!262, !263}
!262 = !DIBasicType(name: "long double", size: 128, encoding: DW_ATE_float)
!263 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !262, size: 64)
!264 = !{!265}
!265 = !DILocalVariable(name: "p", arg: 1, scope: !259, file: !1, line: 37, type: !263)
!266 = !DILocation(line: 0, scope: !259)
!267 = !DILocation(line: 37, column: 54, scope: !259, atomGroup: 1, atomRank: 2)
!268 = !{!269, !269, i64 0}
!269 = !{!"long double", !33, i64 0}
!270 = !DILocation(line: 37, column: 47, scope: !259, atomGroup: 1, atomRank: 1)
!271 = distinct !DISubprogram(name: "a16_index", scope: !1, file: !1, line: 38, type: !272, scopeLine: 38, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !274, keyInstructions: true)
!272 = !DISubroutineType(types: !273)
!273 = !{!3, !239, !3}
!274 = !{!275, !276}
!275 = !DILocalVariable(name: "a", arg: 1, scope: !271, file: !1, line: 38, type: !239)
!276 = !DILocalVariable(name: "i", arg: 2, scope: !271, file: !1, line: 38, type: !3)
!277 = !DILocation(line: 0, scope: !271)
!278 = !DILocation(line: 38, column: 39, scope: !271)
!279 = !DILocation(line: 38, column: 39, scope: !271, atomGroup: 1, atomRank: 2)
!280 = !DILocation(line: 38, column: 32, scope: !271, atomGroup: 1, atomRank: 1)
!281 = distinct !DISubprogram(name: "a17_out", scope: !1, file: !1, line: 39, type: !282, scopeLine: 39, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !285, keyInstructions: true)
!282 = !DISubroutineType(types: !283)
!283 = !{null, !284}
!284 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !44, size: 64)
!285 = !{!286}
!286 = !DILocalVariable(name: "out", arg: 1, scope: !281, file: !1, line: 39, type: !284)
!287 = !DILocation(line: 0, scope: !281)
!288 = !DILocation(line: 39, column: 42, scope: !281, atomGroup: 1, atomRank: 1)
!289 = !{!64, !32, i64 0}
!290 = !DILocation(line: 39, column: 52, scope: !281)
!291 = !DILocation(line: 39, column: 54, scope: !281, atomGroup: 2, atomRank: 1)
!292 = !{!64, !65, i64 4}
!293 = !DILocation(line: 39, column: 59, scope: !281, atomGroup: 3, atomRank: 1)
