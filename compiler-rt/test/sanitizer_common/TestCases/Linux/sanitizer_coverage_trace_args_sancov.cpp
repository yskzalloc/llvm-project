// Check that `sancov -symbolize-dataflow` resolves the call sites a C++ program
// built with -fsanitize-coverage=trace-args,trace-ret reports from to the
// function each record belongs to: the program records the return address of
// every callback, and every record has to land on a call site sancov found in
// the binary, of the same kind, naming the right function. The observations
// are those of IR functions: `this` and a reference come with the bytes the IR
// says they point to, a plain pointer is a pointer value only, and an inlined
// callee reports nothing.
//
// REQUIRES: has_sancovcc
// UNSUPPORTED: android
// RUN: %clangxx -O2 -g -fsanitize-coverage=trace-args,trace-ret %s -o %t
// RUN: %run %t > %t.records
// RUN: %sancovcc  -symbolize-dataflow %t > %t.json
// RUN: %python %S/Inputs/sancov_dataflow.py %t.records %t.json | \
// RUN:   FileCheck %s --implicit-check-not=UNMATCHED --implicit-check-not=MISMATCHED \
// RUN:     --implicit-check-not=helper

#include <link.h>
#include <stdint.h>
#include <stdio.h>

namespace {
struct Record {
  bool IsRet;
  uintptr_t RetAddr;
  uint32_t ArgIdx;
  uint32_t Size;
  uint64_t Val;
  uint32_t NumFields;
  uint64_t Fields[4];
};

Record Records[64];
unsigned NumRecords;
// Volatile: the optimizer runs before the callbacks are inserted, so it would
// otherwise see nothing read the flag between setting and clearing it.
volatile bool Recording;

// Called from the callbacks: instrumenting it would recurse.
__attribute__((no_sanitize("coverage"))) void record(bool IsRet, uintptr_t RetAddr, uint32_t ArgIdx, uint32_t Size,
            uint64_t Val, const uint64_t *Offsets, uint32_t NumFields) {
  if (!Recording || NumRecords == sizeof(Records) / sizeof(Records[0]))
    return;
  Record &R = Records[NumRecords++];
  R = {IsRet, RetAddr, ArgIdx, Size, Val, NumFields, {}};
  // With fields, Val is the address of the object and Offsets holds a
  // {byte offset, byte size} pair per field.
  for (uint32_t I = 0; I < NumFields && I < 4; I++) {
    const uint8_t *Field =
        reinterpret_cast<const uint8_t *>(Val) + Offsets[2 * I];
    uint64_t V = 0;
    __builtin_memcpy(&V, Field,
                     Offsets[2 * I + 1] < 8 ? Offsets[2 * I + 1] : 8);
    R.Fields[I] = V;
  }
}

int findLoadBias(dl_phdr_info *Info, size_t, void *Bias) {
  // The main program comes first.
  *static_cast<uintptr_t *>(Bias) = Info->dlpi_addr;
  return 1;
}
} // namespace

extern "C" {
// The consumers under test override compiler-rt's weak defaults. Neither
// callback is told the function it reports for: the call site is, which is
// what sancov resolves.
__attribute__((noinline)) void
__sanitizer_cov_trace_args(uint32_t arg_idx, uint32_t size, uint64_t val,
                           uint64_t *offsets, uint32_t num_fields) {
  record(false, reinterpret_cast<uintptr_t>(__builtin_return_address(0)),
         arg_idx, size, val, offsets, num_fields);
}

__attribute__((noinline)) void __sanitizer_cov_trace_ret(uint32_t size,
                                                         uint64_t val,
                                                         uint64_t *offsets,
                                                         uint32_t num_fields) {
  record(true, reinterpret_cast<uintptr_t>(__builtin_return_address(0)), 0,
         size, val, offsets, num_fields);
}
}

struct Point {
  long X, Y;
};

struct Counter {
  int Base;
  // `this` is IR argument 0, dereferenceable(4): reported with the 4 bytes it
  // points to.
  // CHECK-DAG: ARGS idx=0 size=4 fields=0x7 in Counter::scale(int) const@[[@LINE+3]]
  // CHECK-DAG: ARGS idx=1 size=4 val=0x6 in Counter::scale(int) const@[[@LINE+2]]
  // CHECK-DAG: RET size=4 val=0x2a in Counter::scale(int) const@[[@LINE+1]]
  __attribute__((noinline)) int scale(int F) const { return Base * F; }
};

// Inlined into add, so its parameter is not observed: the arguments are those
// of IR functions.
static inline __attribute__((always_inline)) int helper(int V) {
  return V * 3 + 1;
}

// add's own parameters, at add's opening line, and its return.
// CHECK-DAG: ARGS idx=0 size=4 val=0x1111 in add(int, int)@[[@LINE+3]]
// CHECK-DAG: ARGS idx=1 size=4 val=0x2222 in add(int, int)@[[@LINE+2]]
// CHECK-DAG: RET size=4 val=0x5556 in add(int, int)@[[@LINE+3]]
__attribute__((noinline)) int add(int A, int B) {
  int H = helper(A);
  return H + B;
}

// A pointer to a struct the IR knows nothing about is reported as the address
// it holds; the struct is not read.
// CHECK-DAG: ARGS idx=0 size=8 val=0x{{[0-9a-f]+}} in sum(Point const*)@[[@LINE+2]]
// CHECK-DAG: RET size=8 val=0x30 in sum(Point const*)@[[@LINE+1]]
__attribute__((noinline)) long sum(const Point *P) { return P->X + P->Y; }

// A reference is dereferenceable(sizeof(Point)): its 16 bytes are read.
// CHECK-DAG: ARGS idx=0 size=16 fields=0x10,0x20 in area(Point const&)@[[@LINE+2]]
// CHECK-DAG: RET size=8 val=0x200 in area(Point const&)@[[@LINE+1]]
__attribute__((noinline)) long area(const Point &P) { return P.X * P.Y; }

int main() {
  Point P = {0x10, 0x20};
  Counter C = {7};

  Recording = true;
  volatile int R1 = add(0x1111, 0x2222);
  volatile long R2 = sum(&P) + area(P);
  volatile int R3 = C.scale(6);
  Recording = false;

  uintptr_t Bias = 0;
  dl_iterate_phdr(findLoadBias, &Bias);
  for (unsigned I = 0; I < NumRecords; I++) {
    const Record &R = Records[I];
    printf("%s 0x%lx", R.IsRet ? "RET" : "ARGS",
           static_cast<unsigned long>(R.RetAddr - Bias));
    if (!R.IsRet)
      printf(" idx=%u", R.ArgIdx);
    printf(" size=%u", R.Size);
    if (R.NumFields) {
      printf(" fields=");
      for (uint32_t F = 0; F < R.NumFields && F < 4; F++)
        printf("%s0x%llx", F ? "," : "", (unsigned long long)R.Fields[F]);
    } else {
      printf(" val=0x%llx", (unsigned long long)R.Val);
    }
    printf("\n");
  }
  return R1 + R2 + R3 == 0;
}
