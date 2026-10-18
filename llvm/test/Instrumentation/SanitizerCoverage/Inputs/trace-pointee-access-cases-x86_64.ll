; The accesses of access-cases.c below, as clang -O2 -g emits them for
; x86_64-linux-gnu.
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
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

define dso_local i32 @a01_fields(ptr nofree noundef readonly captures(none) %o) local_unnamed_addr !dbg !28 {
entry:
    #dbg_value(ptr %o, !50, !DIExpression(), !51)
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !52
  %0 = load i32, ptr %in, align 8, !dbg !53, !tbaa !54
    #dbg_value(ptr %o, !60, !DIExpression(), !63)
  %y.i = getelementptr inbounds nuw i8, ptr %o, i64 12, !dbg !65
  %1 = load i16, ptr %y.i, align 4, !dbg !66, !tbaa !67
  %conv.i = sext i16 %1 to i32, !dbg !68
  %add = add nsw i32 %0, %conv.i, !dbg !69
  %arrayidx = getelementptr inbounds nuw i8, ptr %o, i64 19, !dbg !70
  %2 = load i8, ptr %arrayidx, align 1, !dbg !70, !tbaa !71
  %conv = zext i8 %2 to i32, !dbg !70
  %add1 = add nsw i32 %add, %conv, !dbg !72
  ret i32 %add1, !dbg !73
}

define dso_local void @a02_update(ptr nofree noundef writeonly captures(none) initializes((8, 12), (24, 32)) %o, i32 noundef %v) local_unnamed_addr !dbg !74 {
entry:
    #dbg_value(ptr %o, !78, !DIExpression(), !80)
    #dbg_value(i32 %v, !79, !DIExpression(), !80)
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !81
  store i32 %v, ptr %in, align 8, !dbg !82, !tbaa !54
  %conv = sitofp i32 %v to double, !dbg !83
  %mul = fmul nnan double %conv, 2.000000e+00, !dbg !84
  %d = getelementptr inbounds nuw i8, ptr %o, i64 24, !dbg !85
  store double %mul, ptr %d, align 8, !dbg !86, !tbaa !87
  ret void, !dbg !88
}

define dso_local i32 @a03_counter(ptr nofree noundef captures(none) %o) local_unnamed_addr !dbg !89 {
entry:
    #dbg_value(ptr %o, !91, !DIExpression(), !92)
  %0 = load i64, ptr %o, align 8, !dbg !93, !tbaa !94
  %inc = add nsw i64 %0, 1, !dbg !95
  store i64 %inc, ptr %o, align 8, !dbg !96, !tbaa !94
  %conv = trunc i64 %inc to i32, !dbg !97
  ret i32 %conv, !dbg !98
}

define dso_local i32 @a04_cond(ptr nofree noundef readonly captures(none) %o, i32 noundef %c) local_unnamed_addr !dbg !99 {
entry:
    #dbg_value(ptr %o, !103, !DIExpression(), !105)
    #dbg_value(i32 %c, !104, !DIExpression(), !105)
  %tobool.not = icmp eq i32 %c, 0, !dbg !106
  br i1 %tobool.not, label %cond.end, label %cond.true, !dbg !107

cond.true:                                        ; preds = %entry
  %in = getelementptr inbounds nuw i8, ptr %o, i64 8, !dbg !108
  %0 = load i32, ptr %in, align 8, !dbg !109, !tbaa !54
  br label %cond.end, !dbg !110

cond.end:                                         ; preds = %entry, %cond.true
  %cond = phi i32 [ %0, %cond.true ], [ 0, %entry ], !dbg !111
  ret i32 %cond, !dbg !112
}

define dso_local i32 @a05_walk(ptr nofree noundef readonly captures(address_is_null) %n) local_unnamed_addr !dbg !113 {
entry:
    #dbg_value(ptr %n, !122, !DIExpression(), !124)
    #dbg_value(i32 0, !123, !DIExpression(), !124)
  %tobool.not4 = icmp eq ptr %n, null, !dbg !125
  br i1 %tobool.not4, label %for.end, label %for.body, !dbg !127

for.body:                                         ; preds = %entry, %for.body
  %s.06 = phi i32 [ %add, %for.body ], [ 0, %entry ]
  %n.addr.05 = phi ptr [ %1, %for.body ], [ %n, %entry ]
    #dbg_value(i32 %s.06, !123, !DIExpression(), !124)
    #dbg_value(ptr %n.addr.05, !122, !DIExpression(), !124)
  %val = getelementptr inbounds nuw i8, ptr %n.addr.05, i64 8, !dbg !128
  %0 = load i32, ptr %val, align 8, !dbg !128, !tbaa !130
  %add = add nsw i32 %0, %s.06, !dbg !134
    #dbg_value(i32 %add, !123, !DIExpression(), !124)
  %1 = load ptr, ptr %n.addr.05, align 8, !dbg !135, !tbaa !136
    #dbg_value(ptr %1, !122, !DIExpression(), !124)
  %tobool.not = icmp eq ptr %1, null, !dbg !137
  br i1 %tobool.not, label %for.end, label %for.body, !dbg !138, !llvm.loop !139

for.end:                                          ; preds = %for.body, %entry
  %s.0.lcssa = phi i32 [ 0, %entry ], [ %add, %for.body ], !dbg !124
  ret i32 %s.0.lcssa, !dbg !143
}

define dso_local i32 @a06_container_of(ptr nofree noundef readonly captures(none) %l) local_unnamed_addr !dbg !144 {
entry:
    #dbg_value(ptr %l, !148, !DIExpression(), !150)
  %add.ptr = getelementptr inbounds i8, ptr %l, i64 -8, !dbg !151
    #dbg_value(ptr %add.ptr, !149, !DIExpression(), !150)
  %0 = load i32, ptr %add.ptr, align 8, !dbg !152, !tbaa !153
  ret i32 %0, !dbg !157
}

define dso_local void @a07_copy_big(ptr nofree noundef writeonly captures(none) initializes((0, 32)) %dst, ptr nofree noundef readonly captures(none) %src) local_unnamed_addr !dbg !158 {
entry:
    #dbg_value(ptr %dst, !171, !DIExpression(), !173)
    #dbg_value(ptr %src, !172, !DIExpression(), !173)
  tail call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 8 dereferenceable(32) %dst, ptr noundef nonnull align 8 dereferenceable(32) %src, i64 32, i1 false), !dbg !174, !tbaa.struct !175
  ret void, !dbg !177
}

declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg)

define dso_local i32 @a08_volatile(ptr nofree noundef captures(address) %p) local_unnamed_addr !dbg !178 {
entry:
    #dbg_value(ptr %p, !184, !DIExpression(), !185)
  %0 = load volatile i32, ptr %p, align 4, !dbg !186, !tbaa !187
  ret i32 %0, !dbg !188
}

define dso_local i64 @a09_acquire(ptr nofree noundef captures(none) %p) local_unnamed_addr !dbg !189 {
entry:
    #dbg_value(ptr %p, !194, !DIExpression(), !195)
  %0 = load atomic i64, ptr %p acquire, align 8, !dbg !196
  ret i64 %0, !dbg !197
}

define dso_local void @a10_release(ptr nofree noundef captures(none) %p, i64 noundef %v) local_unnamed_addr !dbg !198 {
entry:
    #dbg_value(ptr %p, !202, !DIExpression(), !204)
    #dbg_value(i64 %v, !203, !DIExpression(), !204)
  store atomic i64 %v, ptr %p release, align 8, !dbg !205
  ret void, !dbg !206
}

define dso_local i64 @a11_fetch_add(ptr nofree noundef captures(none) %p) local_unnamed_addr !dbg !207 {
entry:
    #dbg_value(ptr %p, !209, !DIExpression(), !210)
  %0 = atomicrmw add ptr %p, i64 1 seq_cst, align 8, !dbg !211
  ret i64 %0, !dbg !212
}

define dso_local range(i32 0, 32) i32 @a12_bitfield(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !213 {
entry:
    #dbg_value(ptr %p, !223, !DIExpression(), !224)
  %bf.load = load i8, ptr %p, align 4, !dbg !225
  %bf.lshr = lshr i8 %bf.load, 3, !dbg !226
  %bf.cast = zext nneg i8 %bf.lshr to i32, !dbg !227
  ret i32 %bf.cast, !dbg !228
}

define dso_local i32 @a13_static(ptr nofree noundef readonly align 4 captures(none) dereferenceable(16) %a) local_unnamed_addr !dbg !229 {
entry:
    #dbg_value(ptr %a, !234, !DIExpression(), !235)
  %arrayidx = getelementptr inbounds nuw i8, ptr %a, i64 4, !dbg !236
  %0 = load i32, ptr %arrayidx, align 4, !dbg !236, !tbaa !187
  %arrayidx1 = getelementptr inbounds nuw i8, ptr %a, i64 8, !dbg !237
  %1 = load i32, ptr %arrayidx1, align 4, !dbg !237, !tbaa !187
  %add = add nsw i32 %1, %0, !dbg !238
  ret i32 %add, !dbg !239
}

define dso_local i128 @a14_int128(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !240 {
entry:
    #dbg_value(ptr %p, !246, !DIExpression(), !247)
  %0 = load i128, ptr %p, align 16, !dbg !248, !tbaa !249
  ret i128 %0, !dbg !251
}

define dso_local x86_fp80 @a15_long_double(ptr nofree noundef readonly captures(none) %p) local_unnamed_addr !dbg !252 {
entry:
    #dbg_value(ptr %p, !258, !DIExpression(), !259)
  %0 = load x86_fp80, ptr %p, align 16, !dbg !260, !tbaa !261
  ret x86_fp80 %0, !dbg !263
}

define dso_local i32 @a16_index(ptr nofree noundef readonly captures(none) %a, i32 noundef %i) local_unnamed_addr !dbg !264 {
entry:
    #dbg_value(ptr %a, !268, !DIExpression(), !270)
    #dbg_value(i32 %i, !269, !DIExpression(), !270)
  %idxprom = sext i32 %i to i64, !dbg !271
  %arrayidx = getelementptr inbounds [4 x i8], ptr %a, i64 %idxprom, !dbg !271
  %0 = load i32, ptr %arrayidx, align 4, !dbg !272, !tbaa !187
  ret i32 %0, !dbg !273
}

define dso_local void @a17_out(ptr nofree noundef writeonly captures(none) initializes((0, 6)) %out) local_unnamed_addr !dbg !274 {
entry:
    #dbg_value(ptr %out, !279, !DIExpression(), !280)
  store i32 1, ptr %out, align 4, !dbg !281, !tbaa !282
  %y = getelementptr inbounds nuw i8, ptr %out, i64 4, !dbg !283
  store i16 2, ptr %y, align 4, !dbg !284, !tbaa !285
  ret void, !dbg !286
}


!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!16, !17, !18, !19, !20, !21, !22}
!llvm.errno.tbaa = !{!23}

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
!15 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed_char)
!16 = !{i32 7, !"Dwarf Version", i32 5}
!17 = !{i32 2, !"Debug Info Version", i32 3}
!18 = !{i32 1, !"long-double-type", !"x86_fp80"}
!19 = !{i32 8, !"PIC Level", i32 2}
!20 = !{i32 7, !"PIE Level", i32 2}
!21 = !{i32 7, !"uwtable", i32 2}
!22 = !{i32 7, !"debug-info-assignment-tracking", i1 true}
!23 = !{!24, !25, i64 0}
!24 = !{!"__libc_errno", !25, i64 0}
!25 = !{!"int", !26, i64 0}
!26 = !{!"omnipotent char", !27, i64 0}
!27 = !{!"Simple C/C++ TBAA"}
!28 = distinct !DISubprogram(name: "a01_fields", scope: !1, file: !1, line: 14, type: !29, scopeLine: 14, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !49, keyInstructions: true)
!29 = !DISubroutineType(types: !30)
!30 = !{!3, !31}
!31 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !32, size: 64)
!32 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "outer", file: !1, line: 3, size: 256, elements: !33)
!33 = !{!34, !36, !42, !47}
!34 = !DIDerivedType(tag: DW_TAG_member, name: "id", scope: !32, file: !1, line: 3, baseType: !35, size: 64)
!35 = !DIBasicType(name: "long", size: 64, encoding: DW_ATE_signed)
!36 = !DIDerivedType(tag: DW_TAG_member, name: "in", scope: !32, file: !1, line: 3, baseType: !37, size: 64, offset: 64)
!37 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "inner", file: !1, line: 2, size: 64, elements: !38)
!38 = !{!39, !40}
!39 = !DIDerivedType(tag: DW_TAG_member, name: "x", scope: !37, file: !1, line: 2, baseType: !3, size: 32)
!40 = !DIDerivedType(tag: DW_TAG_member, name: "y", scope: !37, file: !1, line: 2, baseType: !41, size: 16, offset: 32)
!41 = !DIBasicType(name: "short", size: 16, encoding: DW_ATE_signed)
!42 = !DIDerivedType(tag: DW_TAG_member, name: "tag", scope: !32, file: !1, line: 3, baseType: !43, size: 32, offset: 128)
!43 = !DICompositeType(tag: DW_TAG_array_type, baseType: !44, size: 32, elements: !45)
!44 = !DIBasicType(name: "unsigned char", size: 8, encoding: DW_ATE_unsigned_char)
!45 = !{!46}
!46 = !DISubrange(count: 4)
!47 = !DIDerivedType(tag: DW_TAG_member, name: "d", scope: !32, file: !1, line: 3, baseType: !48, size: 64, offset: 192)
!48 = !DIBasicType(name: "double", size: 64, encoding: DW_ATE_float)
!49 = !{!50}
!50 = !DILocalVariable(name: "o", arg: 1, scope: !28, file: !1, line: 14, type: !31)
!51 = !DILocation(line: 0, scope: !28)
!52 = !DILocation(line: 14, column: 45, scope: !28)
!53 = !DILocation(line: 14, column: 48, scope: !28)
!54 = !{!55, !25, i64 8}
!55 = !{!"outer", !56, i64 0, !57, i64 8, !26, i64 16, !59, i64 24}
!56 = !{!"long", !26, i64 0}
!57 = !{!"inner", !25, i64 0, !58, i64 4}
!58 = !{!"short", !26, i64 0}
!59 = !{!"double", !26, i64 0}
!60 = !DILocalVariable(name: "o", arg: 1, scope: !61, file: !1, line: 10, type: !31)
!61 = distinct !DISubprogram(name: "helper", scope: !1, file: !1, line: 10, type: !29, scopeLine: 10, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagLocalToUnit | DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !62, keyInstructions: true)
!62 = !{!60}
!63 = distinct !DILocation(line: 0, scope: !61, inlinedAt: !64)
!64 = distinct !DILocation(line: 14, column: 52, scope: !28)
!65 = distinct !DILocation(line: 11, column: 16, scope: !61, inlinedAt: !64)
!66 = distinct !DILocation(line: 11, column: 16, scope: !61, inlinedAt: !64, atomGroup: 1, atomRank: 3)
!67 = !{!55, !58, i64 12}
!68 = distinct !DILocation(line: 11, column: 10, scope: !61, inlinedAt: !64, atomGroup: 1, atomRank: 2)
!69 = !DILocation(line: 14, column: 50, scope: !28)
!70 = !DILocation(line: 14, column: 64, scope: !28)
!71 = !{!26, !26, i64 0}
!72 = !DILocation(line: 14, column: 62, scope: !28, atomGroup: 1, atomRank: 2)
!73 = !DILocation(line: 14, column: 35, scope: !28, atomGroup: 1, atomRank: 1)
!74 = distinct !DISubprogram(name: "a02_update", scope: !1, file: !1, line: 15, type: !75, scopeLine: 15, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !77, keyInstructions: true)
!75 = !DISubroutineType(types: !76)
!76 = !{null, !31, !3}
!77 = !{!78, !79}
!78 = !DILocalVariable(name: "o", arg: 1, scope: !74, file: !1, line: 15, type: !31)
!79 = !DILocalVariable(name: "v", arg: 2, scope: !74, file: !1, line: 15, type: !3)
!80 = !DILocation(line: 0, scope: !74)
!81 = !DILocation(line: 15, column: 46, scope: !74)
!82 = !DILocation(line: 15, column: 51, scope: !74, atomGroup: 1, atomRank: 1)
!83 = !DILocation(line: 15, column: 63, scope: !74)
!84 = !DILocation(line: 15, column: 65, scope: !74, atomGroup: 2, atomRank: 2)
!85 = !DILocation(line: 15, column: 59, scope: !74)
!86 = !DILocation(line: 15, column: 61, scope: !74, atomGroup: 2, atomRank: 1)
!87 = !{!55, !59, i64 24}
!88 = !DILocation(line: 15, column: 72, scope: !74, atomGroup: 3, atomRank: 1)
!89 = distinct !DISubprogram(name: "a03_counter", scope: !1, file: !1, line: 16, type: !29, scopeLine: 16, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !90, keyInstructions: true)
!90 = !{!91}
!91 = !DILocalVariable(name: "o", arg: 1, scope: !89, file: !1, line: 16, type: !31)
!92 = !DILocation(line: 0, scope: !89)
!93 = !DILocation(line: 16, column: 41, scope: !89)
!94 = !{!55, !56, i64 0}
!95 = !DILocation(line: 16, column: 41, scope: !89, atomGroup: 1, atomRank: 2)
!96 = !DILocation(line: 16, column: 41, scope: !89, atomGroup: 1, atomRank: 1)
!97 = !DILocation(line: 16, column: 52, scope: !89, atomGroup: 2, atomRank: 2)
!98 = !DILocation(line: 16, column: 45, scope: !89, atomGroup: 2, atomRank: 1)
!99 = distinct !DISubprogram(name: "a04_cond", scope: !1, file: !1, line: 17, type: !100, scopeLine: 17, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !102, keyInstructions: true)
!100 = !DISubroutineType(types: !101)
!101 = !{!3, !31, !3}
!102 = !{!103, !104}
!103 = !DILocalVariable(name: "o", arg: 1, scope: !99, file: !1, line: 17, type: !31)
!104 = !DILocalVariable(name: "c", arg: 2, scope: !99, file: !1, line: 17, type: !3)
!105 = !DILocation(line: 0, scope: !99)
!106 = !DILocation(line: 17, column: 47, scope: !99, atomGroup: 2, atomRank: 2)
!107 = !DILocation(line: 17, column: 47, scope: !99, atomGroup: 2, atomRank: 1)
!108 = !DILocation(line: 17, column: 54, scope: !99)
!109 = !DILocation(line: 17, column: 57, scope: !99)
!110 = !DILocation(line: 17, column: 47, scope: !99)
!111 = !DILocation(line: 17, column: 47, scope: !99, atomGroup: 1, atomRank: 2)
!112 = !DILocation(line: 17, column: 40, scope: !99, atomGroup: 1, atomRank: 1)
!113 = distinct !DISubprogram(name: "a05_walk", scope: !1, file: !1, line: 18, type: !114, scopeLine: 18, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !121, keyInstructions: true)
!114 = !DISubroutineType(types: !115)
!115 = !{!3, !116}
!116 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !117, size: 64)
!117 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "node", file: !1, line: 4, size: 128, elements: !118)
!118 = !{!119, !120}
!119 = !DIDerivedType(tag: DW_TAG_member, name: "next", scope: !117, file: !1, line: 4, baseType: !116, size: 64)
!120 = !DIDerivedType(tag: DW_TAG_member, name: "val", scope: !117, file: !1, line: 4, baseType: !3, size: 32, offset: 64)
!121 = !{!122, !123}
!122 = !DILocalVariable(name: "n", arg: 1, scope: !113, file: !1, line: 18, type: !116)
!123 = !DILocalVariable(name: "s", scope: !113, file: !1, line: 19, type: !3)
!124 = !DILocation(line: 0, scope: !113)
!125 = !DILocation(line: 20, column: 3, scope: !126, atomGroup: 9, atomRank: 1)
!126 = distinct !DILexicalBlock(scope: !113, file: !1, line: 20, column: 3)
!127 = !DILocation(line: 20, column: 3, scope: !126, atomGroup: 10, atomRank: 1)
!128 = !DILocation(line: 21, column: 13, scope: !129)
!129 = distinct !DILexicalBlock(scope: !126, file: !1, line: 20, column: 3)
!130 = !{!131, !25, i64 8}
!131 = !{!"node", !132, i64 0, !25, i64 8}
!132 = !{!"p1 _ZTS4node", !133, i64 0}
!133 = !{!"any pointer", !26, i64 0}
!134 = !DILocation(line: 21, column: 7, scope: !129, atomGroup: 4, atomRank: 2)
!135 = !DILocation(line: 20, column: 20, scope: !129, atomGroup: 5, atomRank: 2)
!136 = !{!131, !132, i64 0}
!137 = !DILocation(line: 20, column: 3, scope: !126, atomGroup: 2, atomRank: 1)
!138 = !DILocation(line: 20, column: 3, scope: !126, atomGroup: 3, atomRank: 1)
!139 = distinct !{!139, !140, !141, !142}
!140 = !DILocation(line: 20, column: 3, scope: !126)
!141 = !DILocation(line: 21, column: 13, scope: !126)
!142 = !{!"llvm.loop.mustprogress"}
!143 = !DILocation(line: 22, column: 3, scope: !113, atomGroup: 8, atomRank: 1)
!144 = distinct !DISubprogram(name: "a06_container_of", scope: !1, file: !1, line: 24, type: !145, scopeLine: 24, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !147, keyInstructions: true)
!145 = !DISubroutineType(types: !146)
!146 = !{!3, !12}
!147 = !{!148, !149}
!148 = !DILocalVariable(name: "l", arg: 1, scope: !144, file: !1, line: 24, type: !12)
!149 = !DILocalVariable(name: "it", scope: !144, file: !1, line: 25, type: !4)
!150 = !DILocation(line: 0, scope: !144)
!151 = !DILocation(line: 26, column: 33, scope: !144, atomGroup: 1, atomRank: 2)
!152 = !DILocation(line: 27, column: 14, scope: !144, atomGroup: 3, atomRank: 2)
!153 = !{!154, !25, i64 0}
!154 = !{!"item", !25, i64 0, !155, i64 8}
!155 = !{!"list_head", !156, i64 0, !156, i64 8}
!156 = !{!"p1 _ZTS9list_head", !133, i64 0}
!157 = !DILocation(line: 27, column: 3, scope: !144, atomGroup: 3, atomRank: 1)
!158 = distinct !DISubprogram(name: "a07_copy_big", scope: !1, file: !1, line: 29, type: !159, scopeLine: 29, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !170, keyInstructions: true)
!159 = !DISubroutineType(types: !160)
!160 = !{null, !161, !168}
!161 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !162, size: 64)
!162 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "big", file: !1, line: 5, size: 256, elements: !163)
!163 = !{!164, !165, !166, !167}
!164 = !DIDerivedType(tag: DW_TAG_member, name: "a", scope: !162, file: !1, line: 5, baseType: !35, size: 64)
!165 = !DIDerivedType(tag: DW_TAG_member, name: "b", scope: !162, file: !1, line: 5, baseType: !35, size: 64, offset: 64)
!166 = !DIDerivedType(tag: DW_TAG_member, name: "c", scope: !162, file: !1, line: 5, baseType: !35, size: 64, offset: 128)
!167 = !DIDerivedType(tag: DW_TAG_member, name: "d", scope: !162, file: !1, line: 5, baseType: !35, size: 64, offset: 192)
!168 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !169, size: 64)
!169 = !DIDerivedType(tag: DW_TAG_const_type, baseType: !162)
!170 = !{!171, !172}
!171 = !DILocalVariable(name: "dst", arg: 1, scope: !158, file: !1, line: 29, type: !161)
!172 = !DILocalVariable(name: "src", arg: 2, scope: !158, file: !1, line: 29, type: !168)
!173 = !DILocation(line: 0, scope: !158)
!174 = !DILocation(line: 29, column: 68, scope: !158, atomGroup: 1, atomRank: 1)
!175 = !{i64 0, i64 8, !176, i64 8, i64 8, !176, i64 16, i64 8, !176, i64 24, i64 8, !176}
!176 = !{!56, !56, i64 0}
!177 = !DILocation(line: 29, column: 74, scope: !158, atomGroup: 2, atomRank: 1)
!178 = distinct !DISubprogram(name: "a08_volatile", scope: !1, file: !1, line: 30, type: !179, scopeLine: 30, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !183, keyInstructions: true)
!179 = !DISubroutineType(types: !180)
!180 = !{!3, !181}
!181 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !182, size: 64)
!182 = !DIDerivedType(tag: DW_TAG_volatile_type, baseType: !3)
!183 = !{!184}
!184 = !DILocalVariable(name: "p", arg: 1, scope: !178, file: !1, line: 30, type: !181)
!185 = !DILocation(line: 0, scope: !178)
!186 = !DILocation(line: 30, column: 44, scope: !178, atomGroup: 1, atomRank: 2)
!187 = !{!25, !25, i64 0}
!188 = !DILocation(line: 30, column: 37, scope: !178, atomGroup: 1, atomRank: 1)
!189 = distinct !DISubprogram(name: "a09_acquire", scope: !1, file: !1, line: 31, type: !190, scopeLine: 31, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !193, keyInstructions: true)
!190 = !DISubroutineType(types: !191)
!191 = !{!35, !192}
!192 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !35, size: 64)
!193 = !{!194}
!194 = !DILocalVariable(name: "p", arg: 1, scope: !189, file: !1, line: 31, type: !192)
!195 = !DILocation(line: 0, scope: !189)
!196 = !DILocation(line: 31, column: 36, scope: !189, atomGroup: 2, atomRank: 2)
!197 = !DILocation(line: 31, column: 29, scope: !189, atomGroup: 1, atomRank: 1)
!198 = distinct !DISubprogram(name: "a10_release", scope: !1, file: !1, line: 32, type: !199, scopeLine: 32, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !201, keyInstructions: true)
!199 = !DISubroutineType(types: !200)
!200 = !{null, !192, !35}
!201 = !{!202, !203}
!202 = !DILocalVariable(name: "p", arg: 1, scope: !198, file: !1, line: 32, type: !192)
!203 = !DILocalVariable(name: "v", arg: 2, scope: !198, file: !1, line: 32, type: !35)
!204 = !DILocation(line: 0, scope: !198)
!205 = !DILocation(line: 32, column: 37, scope: !198, atomGroup: 1, atomRank: 1)
!206 = !DILocation(line: 32, column: 79, scope: !198, atomGroup: 2, atomRank: 1)
!207 = distinct !DISubprogram(name: "a11_fetch_add", scope: !1, file: !1, line: 33, type: !190, scopeLine: 33, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !208, keyInstructions: true)
!208 = !{!209}
!209 = !DILocalVariable(name: "p", arg: 1, scope: !207, file: !1, line: 33, type: !192)
!210 = !DILocation(line: 0, scope: !207)
!211 = !DILocation(line: 33, column: 38, scope: !207, atomGroup: 2, atomRank: 2)
!212 = !DILocation(line: 33, column: 31, scope: !207, atomGroup: 1, atomRank: 1)
!213 = distinct !DISubprogram(name: "a12_bitfield", scope: !1, file: !1, line: 34, type: !214, scopeLine: 34, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !222, keyInstructions: true)
!214 = !DISubroutineType(types: !215)
!215 = !{!216, !217}
!216 = !DIBasicType(name: "unsigned int", size: 32, encoding: DW_ATE_unsigned)
!217 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !218, size: 64)
!218 = distinct !DICompositeType(tag: DW_TAG_structure_type, name: "bits", file: !1, line: 8, size: 32, elements: !219)
!219 = !{!220, !221}
!220 = !DIDerivedType(tag: DW_TAG_member, name: "a", scope: !218, file: !1, line: 8, baseType: !216, size: 3, flags: DIFlagBitField, extraData: i64 0)
!221 = !DIDerivedType(tag: DW_TAG_member, name: "b", scope: !218, file: !1, line: 8, baseType: !216, size: 5, offset: 3, flags: DIFlagBitField, extraData: i64 0)
!222 = !{!223}
!223 = !DILocalVariable(name: "p", arg: 1, scope: !213, file: !1, line: 34, type: !217)
!224 = !DILocation(line: 0, scope: !213)
!225 = !DILocation(line: 34, column: 51, scope: !213)
!226 = !DILocation(line: 34, column: 51, scope: !213, atomGroup: 1, atomRank: 3)
!227 = !DILocation(line: 34, column: 51, scope: !213, atomGroup: 1, atomRank: 2)
!228 = !DILocation(line: 34, column: 41, scope: !213, atomGroup: 1, atomRank: 1)
!229 = distinct !DISubprogram(name: "a13_static", scope: !1, file: !1, line: 35, type: !230, scopeLine: 35, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !233, keyInstructions: true)
!230 = !DISubroutineType(types: !231)
!231 = !{!3, !232}
!232 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !3, size: 64)
!233 = !{!234}
!234 = !DILocalVariable(name: "a", arg: 1, scope: !229, file: !1, line: 35, type: !232)
!235 = !DILocation(line: 0, scope: !229)
!236 = !DILocation(line: 35, column: 42, scope: !229)
!237 = !DILocation(line: 35, column: 49, scope: !229)
!238 = !DILocation(line: 35, column: 47, scope: !229, atomGroup: 1, atomRank: 2)
!239 = !DILocation(line: 35, column: 35, scope: !229, atomGroup: 1, atomRank: 1)
!240 = distinct !DISubprogram(name: "a14_int128", scope: !1, file: !1, line: 36, type: !241, scopeLine: 36, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !245, keyInstructions: true)
!241 = !DISubroutineType(types: !242)
!242 = !{!243, !244}
!243 = !DIBasicType(name: "__int128", size: 128, encoding: DW_ATE_signed)
!244 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !243, size: 64)
!245 = !{!246}
!246 = !DILocalVariable(name: "p", arg: 1, scope: !240, file: !1, line: 36, type: !244)
!247 = !DILocation(line: 0, scope: !240)
!248 = !DILocation(line: 36, column: 43, scope: !240, atomGroup: 1, atomRank: 2)
!249 = !{!250, !250, i64 0}
!250 = !{!"__int128", !26, i64 0}
!251 = !DILocation(line: 36, column: 36, scope: !240, atomGroup: 1, atomRank: 1)
!252 = distinct !DISubprogram(name: "a15_long_double", scope: !1, file: !1, line: 37, type: !253, scopeLine: 37, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !257, keyInstructions: true)
!253 = !DISubroutineType(types: !254)
!254 = !{!255, !256}
!255 = !DIBasicType(name: "long double", size: 128, encoding: DW_ATE_float)
!256 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !255, size: 64)
!257 = !{!258}
!258 = !DILocalVariable(name: "p", arg: 1, scope: !252, file: !1, line: 37, type: !256)
!259 = !DILocation(line: 0, scope: !252)
!260 = !DILocation(line: 37, column: 54, scope: !252, atomGroup: 1, atomRank: 2)
!261 = !{!262, !262, i64 0}
!262 = !{!"long double", !26, i64 0}
!263 = !DILocation(line: 37, column: 47, scope: !252, atomGroup: 1, atomRank: 1)
!264 = distinct !DISubprogram(name: "a16_index", scope: !1, file: !1, line: 38, type: !265, scopeLine: 38, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !267, keyInstructions: true)
!265 = !DISubroutineType(types: !266)
!266 = !{!3, !232, !3}
!267 = !{!268, !269}
!268 = !DILocalVariable(name: "a", arg: 1, scope: !264, file: !1, line: 38, type: !232)
!269 = !DILocalVariable(name: "i", arg: 2, scope: !264, file: !1, line: 38, type: !3)
!270 = !DILocation(line: 0, scope: !264)
!271 = !DILocation(line: 38, column: 39, scope: !264)
!272 = !DILocation(line: 38, column: 39, scope: !264, atomGroup: 1, atomRank: 2)
!273 = !DILocation(line: 38, column: 32, scope: !264, atomGroup: 1, atomRank: 1)
!274 = distinct !DISubprogram(name: "a17_out", scope: !1, file: !1, line: 39, type: !275, scopeLine: 39, flags: DIFlagPrototyped | DIFlagAllCallsDescribed, spFlags: DISPFlagDefinition | DISPFlagOptimized, unit: !0, retainedNodes: !278, keyInstructions: true)
!275 = !DISubroutineType(types: !276)
!276 = !{null, !277}
!277 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !37, size: 64)
!278 = !{!279}
!279 = !DILocalVariable(name: "out", arg: 1, scope: !274, file: !1, line: 39, type: !277)
!280 = !DILocation(line: 0, scope: !274)
!281 = !DILocation(line: 39, column: 42, scope: !274, atomGroup: 1, atomRank: 1)
!282 = !{!57, !25, i64 0}
!283 = !DILocation(line: 39, column: 52, scope: !274)
!284 = !DILocation(line: 39, column: 54, scope: !274, atomGroup: 2, atomRank: 1)
!285 = !{!57, !58, i64 4}
!286 = !DILocation(line: 39, column: 59, scope: !274, atomGroup: 3, atomRank: 1)
