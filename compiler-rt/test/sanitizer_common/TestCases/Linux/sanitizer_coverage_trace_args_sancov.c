// Check that `sancov -symbolize-dataflow` resolves the call sites a C program
// built with -fsanitize-coverage=trace-args,trace-ret reports from to the
// function each record belongs to, and that the records carry the IR-level
// observations: arg_idx is the IR argument position, a struct the ABI passes
// or returns in memory is reported with the elements of its IR type, and an
// inlined callee, which is no IR function of its own, reports nothing.
// See sanitizer_coverage_trace_args_sancov.cpp for the C++ counterpart.
//
// REQUIRES: has_sancovcc
// UNSUPPORTED: android
// RUN: %clang -O2 -g -fsanitize-coverage=trace-args,trace-ret %s -o %t
// RUN: %run %t > %t.records
// RUN: %sancovcc  -symbolize-dataflow %t > %t.json
// RUN: %python %S/Inputs/sancov_dataflow.py %t.records %t.json | \
// RUN:   FileCheck %s --implicit-check-not=UNMATCHED --implicit-check-not=MISMATCHED \
// RUN:     --implicit-check-not=helper

#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct Record {
  int IsRet;
  uintptr_t RetAddr;
  uint32_t ArgIdx;
  uint32_t Size;
  uint64_t Val;
  uint32_t NumFields;
  uint64_t Fields[4];
};

static struct Record Records[64];
static unsigned NumRecords;
// Volatile: the optimizer runs before the callbacks are inserted, so it would
// otherwise see nothing read the flag between setting and clearing it.
static volatile int Recording;

// Called from the callbacks: instrumenting it would recurse.
__attribute__((no_sanitize("coverage"))) static void record(int IsRet, uintptr_t RetAddr, uint32_t ArgIdx, uint32_t Size,
                   uint64_t Val, const uint64_t *Offsets, uint32_t NumFields) {
  if (!Recording || NumRecords == sizeof(Records) / sizeof(Records[0]))
    return;
  struct Record *R = &Records[NumRecords++];
  memset(R, 0, sizeof(*R));
  R->IsRet = IsRet;
  R->RetAddr = RetAddr;
  R->ArgIdx = ArgIdx;
  R->Size = Size;
  R->Val = Val;
  R->NumFields = NumFields;
  // With fields, Val is the address of the object and Offsets holds a
  // {byte offset, byte size} pair per field.
  for (uint32_t I = 0; I < NumFields && I < 4; I++) {
    uint64_t Bytes = Offsets[2 * I + 1] < 8 ? Offsets[2 * I + 1] : 8;
    memcpy(&R->Fields[I], (const uint8_t *)(uintptr_t)Val + Offsets[2 * I],
           Bytes);
  }
}

static int findLoadBias(struct dl_phdr_info *Info, size_t Size, void *Bias) {
  // The main program comes first.
  *(uintptr_t *)Bias = Info->dlpi_addr;
  return 1;
}

// The consumers under test override compiler-rt's weak defaults.
__attribute__((noinline)) void
__sanitizer_cov_trace_args(uint32_t arg_idx, uint32_t size, uint64_t val,
                           uint64_t *offsets, uint32_t num_fields) {
  record(0, (uintptr_t)__builtin_return_address(0), arg_idx, size, val, offsets,
         num_fields);
}

__attribute__((noinline)) void __sanitizer_cov_trace_ret(uint32_t size,
                                                         uint64_t val,
                                                         uint64_t *offsets,
                                                         uint32_t num_fields) {
  record(1, (uintptr_t)__builtin_return_address(0), 0, size, val, offsets,
         num_fields);
}

// Large enough that the ABI passes and returns it in memory.
struct Triple {
  long A, B, C;
};

// Inlined into scale, so its parameter is not observed: the arguments are
// those of IR functions.
static inline __attribute__((always_inline)) long helper(long V) {
  return V * 3 + 1;
}

// The indirect return takes IR argument 0, so T is IR argument 1 and F 2. T is
// passed in memory: as a byval object, reported with its fields, on x86-64, and
// by address on AArch64, a pointer the IR says is dereferenceable(24), reported
// with the 24 bytes behind it. The return is the buffer it was written to.
// CHECK-DAG: ARGS idx=1 size=24 fields=0x1,0x2,0x3 in scale@[[@LINE+3]]
// CHECK-DAG: ARGS idx=2 size=8 val=0x10 in scale@[[@LINE+2]]
// CHECK-DAG: RET size=24 fields=0x10,0x20,0xa in scale@[[@LINE+3]]
__attribute__((noinline)) struct Triple scale(struct Triple T, long F) {
  struct Triple R = {T.A * F, T.B * F, helper(T.C)};
  return R;
}

// CHECK-DAG: ARGS idx=0 size=8 val=0x7 in negate@[[@LINE+2]]
// CHECK-DAG: RET size=8 val=0xfffffffffffffff9 in negate@[[@LINE+1]]
__attribute__((noinline)) long negate(long V) { return -V; }

// A pointer is reported as the address it holds: C says nothing about how much
// of what it points to may be read. An array parameter of static size does,
// so the IR has it dereferenceable that far, and the bytes are read.
// CHECK-DAG: ARGS idx=0 size=8 val=0x{{[0-9a-f]+}} in first@[[@LINE+1]]
__attribute__((noinline)) long first(const struct Triple *T) { return T->A; }
// CHECK-DAG: ARGS idx=0 size=24 fields=0x1,0x2,0x3 in last@[[@LINE+2]]
__attribute__((noinline)) long
last(const struct Triple T[static 1]) {
  return T->C;
}

int main(void) {
  struct Triple T = {1, 2, 3};

  Recording = 1;
  volatile struct Triple R1 = scale(T, 0x10);
  volatile long R2 = negate(7) + first(&T) + last(&T);
  Recording = 0;

  uintptr_t Bias = 0;
  dl_iterate_phdr(findLoadBias, &Bias);
  for (unsigned I = 0; I < NumRecords; I++) {
    const struct Record *R = &Records[I];
    printf("%s 0x%lx", R->IsRet ? "RET" : "ARGS",
           (unsigned long)(R->RetAddr - Bias));
    if (!R->IsRet)
      printf(" idx=%u", R->ArgIdx);
    printf(" size=%u", R->Size);
    if (R->NumFields) {
      printf(" fields=");
      for (uint32_t F = 0; F < R->NumFields && F < 4; F++)
        printf("%s0x%llx", F ? "," : "", (unsigned long long)R->Fields[F]);
    } else {
      printf(" val=0x%llx", (unsigned long long)R->Val);
    }
    printf("\n");
  }
  return R1.A + R2 == 0;
}
