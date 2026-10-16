// Check that `sancov -symbolize-dataflow` maps every observation a program
// built with -fsanitize-coverage=trace-args,trace-ret records to the source
// parameter it holds, exactly, through the compiler's debug-only source map:
// split structs, the parameter after one, floating-point and stack-passed
// arguments, a byval struct, an indirect return, a C++ reference, `this`, and
// a non-trivially-copyable object passed by address. Inputs/sancov_dataflow.py
// decodes the recorded values into the source fields sancov located in them.
//
// The IR argument numbering differs between x86-64 and AArch64 for the split
// struct; the source parameters do not.
//
// REQUIRES: has_sancovcc, target={{(x86_64|aarch64).*}}
// UNSUPPORTED: android
// RUN: %clangxx -O2 -g -fsanitize-coverage=trace-args,trace-ret %s -o %t
// RUN: %run %t > %t.records
// RUN: %sancovcc  -symbolize-dataflow %t > %t.json
// RUN: %python %S/Inputs/sancov_dataflow.py --source %t.records %t.json | \
// RUN:   FileCheck %s --implicit-check-not=UNMATCHED --implicit-check-not=MISMATCHED \
// RUN:     --implicit-check-not=heuristic
//
// Without debug information beyond the line tables the test configurations
// add, the observations are the same, but nothing maps them to the source.
// RUN: %clangxx -O2 -fsanitize-coverage=trace-args,trace-ret %s -o %t.nog
// RUN: %run %t.nog > %t.nog.records
// RUN: %sancovcc  -symbolize-dataflow %t.nog > %t.nog.json
// RUN: %python %S/Inputs/sancov_dataflow.py --source %t.nog.records %t.nog.json | \
// RUN:   FileCheck %s --check-prefix=NOG --implicit-check-not=UNMATCHED \
// RUN:     --implicit-check-not=exact
// NOG: ARGS {{.*}} -> unresolved ({{no debug information|no subprogram for the call site}})

#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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

Record Records[128];
unsigned NumRecords;
volatile bool Recording;

// Called from the callbacks: instrumenting it would recurse.
__attribute__((no_sanitize("coverage"))) void
record(bool IsRet, uintptr_t RetAddr, uint32_t ArgIdx, uint32_t Size,
       uint64_t Val, const uint64_t *Offsets, uint32_t NumFields) {
  if (!Recording || NumRecords == sizeof(Records) / sizeof(Records[0]))
    return;
  Record &R = Records[NumRecords++];
  R = {IsRet, RetAddr, ArgIdx, Size, Val, NumFields, {}};
  for (uint32_t I = 0; I < NumFields && I < 4; I++) {
    uint64_t V = 0;
    memcpy(&V, reinterpret_cast<const uint8_t *>(Val) + Offsets[2 * I],
           Offsets[2 * I + 1] < 8 ? Offsets[2 * I + 1] : 8);
    R.Fields[I] = V;
  }
}

int findLoadBias(dl_phdr_info *Info, size_t, void *Bias) {
  *static_cast<uintptr_t *>(Bias) = Info->dlpi_addr;
  return 1;
}
} // namespace

extern "C" {
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

// Gives unusedPiece a side effect, so that its call is not removed.
volatile long Sink;

struct Mix {
  double D;
  long L;
};
struct Pair {
  int X, Y;
};
struct Big {
  long A, B, C, D;
};
struct Foo {
  int A;
  long B;
};

// A struct split into an SSE and an integer piece on x86-64, one [2 x i64] on
// AArch64; both map to m's two members, and z stays z.
// CHECK-DAG: ARGS {{.*}} in afterSplit(Mix, int)@[[@LINE+3]] -> exact m#1 bits[0,64) {D=0x3ff8000000000000}
// CHECK-DAG: ARGS {{.*}} in afterSplit(Mix, int)@[[@LINE+2]] -> exact m#1 bits[64,128) {L=0x7}
// CHECK-DAG: ARGS {{.*}} val=0x9 in afterSplit(Mix, int)@[[@LINE+1]] -> exact z#2 {z=0x9}
__attribute__((noinline)) long afterSplit(Mix m, int z) {
  return m.L + z + (long)m.D;
}

// m.D unused: on x86-64 it is an IR argument of its own the function does not
// use, which callers may pass anything for (here poison, after dead argument
// elimination); its debug record went with it, so it maps to nothing. On
// AArch64 it is an element of an IR argument that is used.
// CHECK-DAG: ARGS idx=0 {{.*}} in unusedPiece(Mix)@[[@LINE+3]] -> {{unresolved \(no source map|exact m#1 bits\[0,64\)}}
// CHECK-DAG: ARGS {{.*}} in unusedPiece(Mix)@[[@LINE+2]] -> exact m#1 bits[64,128) {L=0x7}
// CHECK-DAG: RET {{.*}} in unusedPiece(Mix)@[[@LINE+1]] -> exact long {return=0x7}
__attribute__((noinline)) long unusedPiece(Mix m) { Sink = m.L; return m.L; }

// A small struct coerced into one register.
// CHECK-DAG: ARGS {{.*}} in small(Pair)@[[@LINE+1]] -> exact p#1 {X=0x3, Y=0x4}
__attribute__((noinline)) int small(Pair p) { return p.X * p.Y; }

// Floating point, in SSE or FP registers.
// CHECK-DAG: ARGS {{.*}} in fp(float, double)@[[@LINE+2]] -> exact f#1 {f=0x3fc00000}
// CHECK-DAG: ARGS {{.*}} in fp(float, double)@[[@LINE+1]] -> exact d#2 {d=0x4004000000000000}
__attribute__((noinline)) double fp(float f, double d) { return f + d; }

// The last two go on the stack on both targets.
// CHECK-DAG: ARGS {{.*}} val=0x8 in stack({{.*}})@{{[0-9]+}} -> exact a8#9 {a8=0x8}
// CHECK-DAG: ARGS {{.*}} val=0x9 in stack({{.*}})@{{[0-9]+}} -> exact a9#10 {a9=0x9}
__attribute__((noinline)) long stack(long a0, long a1, long a2, long a3,
                                     long a4, long a5, long a6, long a7,
                                     long a8, long a9) {
  return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9;
}

// In memory: a byval object on x86-64, its address on AArch64, which the IR
// says is dereferenceable(32); either way the parameter's storage, read.
// CHECK-DAG: ARGS {{.*}} in big(Big)@[[@LINE+1]] -> exact &b#1
__attribute__((noinline)) long big(Big b) { return b.A + b.D; }

// The indirect return takes IR argument 0; x is IR argument 1 but still
// source parameter 1, and the return is the buffer of type Big.
// CHECK-DAG: ARGS idx=1 {{.*}} in makeBig(long)@[[@LINE+2]] -> exact x#1 {x=0x5}
// CHECK-DAG: RET size=32 fields=0x5,0x6,0x7,0x8 in makeBig(long)@{{[0-9]+}} -> exact Big {A=0x5, B=0x6, C=0x7, D=0x8}
__attribute__((noinline)) Big makeBig(long x) {
  return {x, x + 1, x + 2, x + 3};
}

// A reference and `this` are pointers to their objects, which the IR says are
// dereferenceable(sizeof the object): the bytes behind them are read, and cut
// into the members of the object.
// CHECK-DAG: ARGS {{.*}} size=16 fields={{.*}} in cref(Foo const&)@[[@LINE+1]] -> exact r#1 ->{A=0x1, B=0x2}
__attribute__((noinline)) long cref(const Foo &r) { return r.A + r.B; }

struct Counter {
  int Base;
  // CHECK-DAG: ARGS idx=0 size=4 fields=0x7 in Counter::scale(int) const@[[@LINE+2]] -> exact this#1 ->{Base=0x7}
  // CHECK-DAG: ARGS idx=1 {{.*}} in Counter::scale(int) const@[[@LINE+1]] -> exact f#2 {f=0x6}
  __attribute__((noinline)) int scale(int f) const { return Base * f; }
};

// Not trivially copyable: passed by the address of a temporary, which the IR
// says is dereferenceable(16), so the parameter itself is read behind it.
struct NT {
  long V[2];
  NT(const NT &O) : V{O.V[0], O.V[1]} {}
  NT(long A) : V{A, A} {}
};
// CHECK-DAG: ARGS idx=0 size=16 fields=0x3,0x3 in nontrivial(NT, int)@[[@LINE+2]] -> exact &n#1 {V=0x30000000000000003}
// CHECK-DAG: ARGS idx=1 {{.*}} in nontrivial(NT, int)@[[@LINE+1]] -> exact z#2 {z=0x2}
__attribute__((noinline)) long nontrivial(NT n, int z) {
  return n.V[0] + n.V[1] + z;
}

int main() {
  Foo F = {1, 2};
  Counter C = {7};
  // Opaque, so that unusedPiece is not folded into a constant.
  volatile double VD = 1.5;
  volatile long VL = 7;
  Recording = true;
  volatile long R = afterSplit({1.5, 7}, 9) + unusedPiece({VD, VL}) +
                    small({3, 4}) + fp(1.5f, 2.5) +
                    stack(0, 1, 2, 3, 4, 5, 6, 7, 8, 9) + big({1, 2, 3, 4}) +
                    makeBig(5).D + cref(F) + C.scale(6) + nontrivial(NT(3), 2);
  Recording = false;

  uintptr_t Bias = 0;
  dl_iterate_phdr(findLoadBias, &Bias);
  for (unsigned I = 0; I < NumRecords; I++) {
    const Record &Rec = Records[I];
    printf("%s 0x%lx", Rec.IsRet ? "RET" : "ARGS",
           static_cast<unsigned long>(Rec.RetAddr - Bias));
    if (!Rec.IsRet)
      printf(" idx=%u", Rec.ArgIdx);
    printf(" size=%u", Rec.Size);
    if (Rec.NumFields) {
      printf(" fields=");
      for (uint32_t F = 0; F < Rec.NumFields && F < 4; F++)
        printf("%s0x%llx", F ? "," : "", (unsigned long long)Rec.Fields[F]);
    } else {
      printf(" val=0x%llx", (unsigned long long)Rec.Val);
    }
    printf("\n");
  }
  return R == 0;
}
