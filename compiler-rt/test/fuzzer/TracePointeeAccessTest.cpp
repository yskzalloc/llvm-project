// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

// No branch and no comparison depends on the input, Fold() takes the same
// plain pointers every time, which carry no dereferenceable contract, and the
// entry point is not instrumented: nothing of the input reaches trace-args but
// the values Fold() itself loads through the pointer, as access records
// (-sanitizer-coverage-trace-pointee-access).
#include <cstddef>
#include <cstdint>
#include <cstring>

struct Pair {
  uint64_t A, B;
};

__attribute__((noinline)) void Fold(const Pair *P, uint64_t *Out) {
  *Out = P->A ^ (P->B << 1);
}

// Not instrumented itself: its own arguments, the input's address and size,
// would be values of their own.
extern "C" __attribute__((no_sanitize("coverage"))) int
LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
  static Pair P;
  static uint64_t Out;
  memset(&P, 0, sizeof(P));
  memcpy(&P, Data, Size < sizeof(P) ? Size : sizeof(P));
  Fold(&P, &Out);
  return 0;
}
