#!/usr/bin/env python3
"""Join the trace-args/trace-ret records of a test program with the call sites
`sancov -symbolize-dataflow` found in its binary.

Usage: sancov_dataflow.py <records> <sancov json>

The program prints one line per callback invocation:

  ARGS <offset> <rest...>
  RET <offset> <rest...>

where <offset> is the return address of the callback, in hex, less the load
bias of the binary, so that it compares with the addresses sancov reads out of
the file. For every record this prints

  ARGS <rest...> in <frame> [<- <frame>...]

each <frame> being <function>@<line>, innermost first: the frame sancov resolved
the record's call site to, then every frame it was inlined into.

A record matches the call site at its return address minus one, which is how
sancov defines a trace-args/trace-ret call site on every target.
"""

import json
import sys


def main():
    records_path, json_path = sys.argv[1:3]
    with open(json_path) as f:
        report = json.load(f)
    if len(report) != 1:
        sys.exit(f"expected the report of one binary, got {list(report)}")
    points = {int(p["pc"], 16): p for p in next(iter(report.values()))}

    with open(records_path) as f:
        for line in f:
            fields = line.split(maxsplit=2)
            if len(fields) < 2 or fields[0] not in ("ARGS", "RET"):
                continue
            kind, ret_addr = fields[0], int(fields[1], 16)
            rest = fields[2].strip() if len(fields) > 2 else ""
            point = points.get(ret_addr - 1)
            if point is None:
                print(f"{kind} {rest} UNMATCHED at 0x{ret_addr:x}")
                continue
            if point["kind"] != kind.lower():
                print(f"{kind} {rest} MISMATCHED {point['kind']} at {point['pc']}")
                continue
            frames = " <- ".join(
                f"{fr['function']}@{fr['line']}" for fr in point["frames"]
            )
            print(f"{kind} {rest} in {frames}")


if __name__ == "__main__":
    main()
