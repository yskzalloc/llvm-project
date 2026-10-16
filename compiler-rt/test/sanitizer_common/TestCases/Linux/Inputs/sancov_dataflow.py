#!/usr/bin/env python3
"""Join the trace-args/trace-ret records of a test program with the call sites
`sancov -symbolize-dataflow` found in its binary.

Usage: sancov_dataflow.py [--source] <records> <sancov json>

The program prints one line per callback invocation:

  ARGS <offset> <rest...>
  RET <offset> <rest...>

where <offset> is the return address of the callback, in hex, less the load
bias of the binary, so that it compares with the addresses sancov reads out of
the file. For every record this prints

  ARGS <rest...> in <frame> [<- <frame>...]

each <frame> being <function>@<line>, innermost first: the frame sancov resolved
the record's call site to, then every frame it was inlined into.

With --source, each line goes on with what sancov resolved the observation to,

  ... -> <provenance> <parameter or type> [<field>=<value>...]

decoding from the recorded value the source fields sancov located in it, so
that a split struct reads as its members, and from the bytes recorded behind a
pointer the members of what it points to, as ->{<member>=<value>...}.

A record matches the call site at its return address minus one, which is how
sancov defines a trace-args/trace-ret call site on every target.
"""

import json
import sys


def describe_source(point, rest):
    source = point.get("source", {})
    prov = source.get("provenance", "unresolved")
    if prov == "unresolved":
        return f" -> unresolved ({source.get('method', '?')})"
    if point["kind"] == "args":
        param = source.get("parameter", {})
        what = ("&" if source.get("indirect") else "") + param.get("name", "?")
        what += f"#{param.get('number', '?')}"
    else:
        what = source.get("type", "?")
    pieces = source.get("pieces", [])
    # The summary names the bits of the parameter when they are not all of it.
    if point["kind"] == "args" and " bits [" in source.get("summary", ""):
        what += "".join(
            f" bits[{p['parameter_bit_offset']},"
            f"{p['parameter_bit_offset'] + p['bit_size']})"
            for p in pieces
        )
    text = f" -> {prov} {what}"
    # Decode the fields a value observation holds.
    opts = dict(f.split("=", 1) for f in rest.split() if "=" in f)
    if "val" in opts:
        val = int(opts["val"], 16)
        decoded = []
        for field in source.get("fields", []):
            if "value_bit_offset" not in field:
                continue
            off, bits = field["value_bit_offset"], field["bit_size"]
            if off + bits > 64:
                continue
            decoded.append(
                f"{field['name']}=0x{(val >> off) & ((1 << bits) - 1):x}"
            )
        if decoded:
            text += " {" + ", ".join(decoded) + "}"
    elif "fields" in opts and "pointee" in point.get("observation", {}).get(
        "flags", []
    ):
        # A raw snapshot of what a pointer points to, in 8-byte words from
        # offset 0: cut it into the members of the pointee, or, if the pointer
        # is the address of the parameter, of the parameter.
        data = b"".join(
            int(v, 16).to_bytes(8, "little") for v in opts["fields"].split(",")
        )
        if source.get("indirect"):
            members, prefix = source.get("fields", []), ""
        else:
            members, prefix = source.get("pointee", {}).get("fields", []), "->"
        decoded = []
        for field in members:
            if not field.get("observed", True) or not field.get("complete", True):
                continue
            off, bits = field["bit_offset"], field["bit_size"]
            if off + bits > 8 * len(data):
                continue
            word = int.from_bytes(data, "little") >> off
            decoded.append(f"{field['name']}=0x{word & ((1 << bits) - 1):x}")
        if decoded:
            text += f" {prefix}{{" + ", ".join(decoded) + "}"
    elif "fields" in opts:
        names = [f["name"] for f in source.get("fields", [])]
        values = opts["fields"].split(",")
        if len(names) >= len(values):
            text += (
                " {" + ", ".join(f"{n}={v}" for n, v in zip(names, values)) + "}"
            )
    return text


def main():
    args = sys.argv[1:]
    with_source = "--source" in args
    args = [a for a in args if a != "--source"]
    records_path, json_path = args[:2]
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
            text = f"{kind} {rest} in {frames}"
            if with_source:
                text += describe_source(point, rest)
            print(text)


if __name__ == "__main__":
    main()
