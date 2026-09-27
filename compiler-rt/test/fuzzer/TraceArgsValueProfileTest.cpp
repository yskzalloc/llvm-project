// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception

// No branch and no comparison depends on the input: inputs differ only in the
// values -fsanitize-coverage=trace-args,trace-ret reports - Fold()'s
// arguments, the bytes behind its reference argument, which the IR says are
// dereferenceable, and its return value.
#include <cstddef>
#include <cstdint>
#include <cstring>

struct Pair {
  uint64_t A, B;
};

__attribute__((noinline)) uint64_t Fold(const Pair &P, uint8_t Tag) {
  return P.A ^ (P.B << 1) ^ Tag;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
  Pair P = {0, 0};
  memcpy(&P, Data, Size < sizeof(P) ? Size : sizeof(P));
  volatile uint64_t R = Fold(P, Size ? Data[0] : 0);
  (void)R;
  return 0;
}
