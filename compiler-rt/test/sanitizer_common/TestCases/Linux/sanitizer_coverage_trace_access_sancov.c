// Check that with -sanitizer-coverage-trace-pointee-access the loads and stores
// a function makes through its pointer arguments arrive at trace-args as access
// records with the values the program loaded and stored, one per access that
// executed, in execution order, and that `sancov -symbolize-dataflow` resolves
// each to the member it accessed. Nothing is read behind a plain pointer: the
// argument record of the pointer is its value alone.
//
// REQUIRES: has_sancovcc
// UNSUPPORTED: android
// RUN: %clang -O2 -g -fsanitize-coverage=trace-args,trace-ret \
// RUN:   -mllvm -sanitizer-coverage-trace-pointee-access %s -o %t
// RUN: %run %t > %t.records
// RUN: %sancovcc  -symbolize-dataflow %t > %t.json
// RUN: %python %S/Inputs/sancov_dataflow.py --source %t.records %t.json | \
// RUN:   FileCheck %s --implicit-check-not=UNMATCHED --implicit-check-not=MISMATCHED
//
// Without the option, no access records.
// RUN: %clang -O2 -g -fsanitize-coverage=trace-args,trace-ret %s -o %t.off
// RUN: %run %t.off > %t.off.records
// RUN: FileCheck %s --check-prefix=OFF < %t.off.records
// OFF-NOT: idx=21474
// OFF-NOT: idx=2147{{[5-9]}}

#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct Record {
  uintptr_t RetAddr;
  uint32_t ArgIdx;
  uint32_t Size;
  uint64_t Val;
  uint32_t NumFields;
};

static struct Record Records[64];
static unsigned NumRecords;
static volatile int Recording;

__attribute__((noinline)) void
__sanitizer_cov_trace_args(uint32_t arg_idx, uint32_t size, uint64_t val,
                           uint64_t *offsets, uint32_t num_fields) {
  if (!Recording || NumRecords == sizeof(Records) / sizeof(Records[0]))
    return;
  struct Record *R = &Records[NumRecords++];
  R->RetAddr = (uintptr_t)__builtin_return_address(0);
  R->ArgIdx = arg_idx;
  R->Size = size;
  R->Val = val;
  R->NumFields = num_fields;
}

__attribute__((noinline)) void __sanitizer_cov_trace_ret(uint32_t size,
                                                         uint64_t val,
                                                         uint64_t *offsets,
                                                         uint32_t num_fields) {}

static int findLoadBias(struct dl_phdr_info *Info, size_t Size, void *Bias) {
  *(uintptr_t *)Bias = Info->dlpi_addr;
  return 1;
}

struct Inner {
  int X;
  short Y;
};
struct State {
  long Id;
  struct Inner In;
  unsigned char Tag[4];
};

// Two loads, of two members; the pointer itself is reported by value only.
// CHECK:      ARGS idx=0 size=8 val=0x{{[0-9a-f]+}} in get@[[@LINE+3]]
// CHECK-NEXT: ACCESS arg=0 load size=4 val=0x5 in get@[[@LINE+2]] -> exact S->In.X=0x5
// CHECK-NEXT: ACCESS arg=0 load size=2 val=0x6 in get@[[@LINE+1]] -> exact S->In.Y=0x6
__attribute__((noinline)) long get(struct State *S) { return S->In.X + S->In.Y; }

// A store reports the value stored.
// CHECK-NEXT: ARGS idx=0 size=8
// CHECK-NEXT: ARGS idx=1 size=4 val=0x2a
// CHECK-NEXT: ACCESS arg=0 store size=1 val=0x2a in set_tag@[[@LINE+1]] -> exact S->Tag[2]=0x2a
__attribute__((noinline)) void set_tag(struct State *S, int V) { S->Tag[2] = V; }

// Called first with C == 0: no record of the load it did not make.
// CHECK-NEXT: ARGS idx=0 size=8
// CHECK-NEXT: ARGS idx=1 size=4 val=0x0
// CHECK-NEXT: ARGS idx=0 size=8
// CHECK-NEXT: ARGS idx=1 size=4 val=0x1
// CHECK-NEXT: ACCESS arg=0 load size=8 val=0x64 in maybe@[[@LINE+2]] -> exact S->Id=0x64
__attribute__((noinline)) long maybe(struct State *S, int C) {
  return C ? S->Id : 0;
}

// The same member, loaded and stored around an opaque call that changes it:
// every access in order, with the value it had then.
// CHECK-NEXT: ARGS idx=0 size=8
// CHECK-NEXT: ACCESS arg=0 load size=8 val=0x64 in bump@[[@LINE+9]] -> exact S->Id=0x64
// CHECK-NEXT: ACCESS arg=0 store size=8 val=0x65 in bump@[[@LINE+8]] -> exact S->Id=0x65
// CHECK-NEXT: ARGS idx=0 size=8
// CHECK-NEXT: ACCESS arg=0 load size=8 val=0x65 in twice@[[@LINE+10]] -> exact P->Id=0x65
// CHECK-NEXT: ACCESS arg=0 store size=8 val=0xca in twice@[[@LINE+9]] -> exact P->Id=0xca
// CHECK-NEXT: ACCESS arg=0 load size=8 val=0xca in bump@[[@LINE+6]] -> exact S->Id=0xca
// CHECK-NEXT: ACCESS arg=0 store size=8 val=0xcb in bump@[[@LINE+5]] -> exact S->Id=0xcb
__attribute__((noinline)) void twice(struct State *P);
__attribute__((noinline)) long bump(struct State *S) {
  S->Id++;
  twice(S);
  return ++S->Id;
}
__attribute__((noinline)) void twice(struct State *P) { P->Id *= 2; }

int main(void) {
  struct State S = {100, {5, 6}, {0, 0, 0, 0}};

  Recording = 1;
  volatile long R = get(&S);
  set_tag(&S, 42);
  R += maybe(&S, 0);
  R += maybe(&S, 1);
  R += bump(&S);
  Recording = 0;

  uintptr_t Bias = 0;
  dl_iterate_phdr(findLoadBias, &Bias);
  for (unsigned I = 0; I < NumRecords; I++) {
    const struct Record *Rec = &Records[I];
    printf("ARGS 0x%lx idx=%u size=%u val=0x%llx\n",
           (unsigned long)(Rec->RetAddr - Bias), Rec->ArgIdx, Rec->Size,
           (unsigned long long)Rec->Val);
  }
  return S.Tag[2] != 42 || R == 0;
}
