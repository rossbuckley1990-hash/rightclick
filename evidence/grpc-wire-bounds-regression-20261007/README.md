# Existing protobuf wire decoder bounds

This repair changes the existing decoder used by gRPC reflection and unary calls. It adds no stream, provider, authority or agent operation.

The exact PR49 baseline `bd5ed53f02c5cf76fc35796e665ef2c076296dd2` codec declares an `Int.max` field length and then traps when adding the already-consumed prefix length. It also accepts a tenth varint byte containing more than one payload bit, discarding overflowing data. Both negative controls were compiled and run as isolated native subprocesses.

The repaired codec rejects the overflowing tenth byte before shifting and compares a declared field length with the remaining bytes before addition or allocation. Both malformed inputs now throw controlled errors. Six XCTest methods pass against the exact isolated source, preserving full-width integers, zero-length and normal fields, following-field cursor position, and truncated-input rejection. Independent raw-byte review also preserves `UInt64.max` and rejects all 254 overflowing tenth bytes.

Reproduce the native crash/rejection controls in a new output directory:

```sh
python3 evidence/grpc-wire-bounds-regression-20261007/reproduce.py --output /private/tmp/rightclick-wire-bounds-reproduction
```

Run the integrated package boundary tests:

```sh
swift test --filter GRPCWireCodecBoundsTests
```

The retained six-test run compiled only the codec source and tests. Integrated package tests, actual native provider transport and platform CI remain separate release requirements. Native toolchain setup errors were corrected before the six-test run; they were not classified as product regressions.
