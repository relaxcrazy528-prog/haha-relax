#!/usr/bin/env python3
"""Run the same core scenarios without XCTest (for Command Line Tools-only hosts).

This is an explicitly small assertion adapter, not the XCTest framework. Full
XCTest remains the canonical CI suite and requires a complete Xcode installation.
"""
from pathlib import Path
import argparse
import re
import subprocess

ADAPTER = r'''
@MainActor private var failures: [String] = []
@MainActor private func record(_ message: String, _ line: UInt) { failures.append("line \(line): \(message)") }
@MainActor private func expectEqual<T: Equatable>(_ lhs: @autoclosure () -> T, _ rhs: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) {
    let a = lhs(), b = rhs(); if a != b { record("\(a) != \(b)", line) }
}
@MainActor private func expectTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value() { record("expected true", line) }
}
@MainActor private func expectFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if value() { record("expected false", line) }
}
private enum ValidationError: Error { case missingValue }
@MainActor private func requireValue<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let result = try value() else { record("missing required value", line); throw ValidationError.missingValue }; return result
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path('build/portable-check'))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    build = args.build_dir.resolve()
    build.mkdir(parents=True, exist_ok=True)
    cache = build / 'module-cache'
    cache.mkdir(exist_ok=True)
    test = (repo / 'Tests/KeepOnlineCoreTests/SessionEngineTests.swift').read_text()
    methods = re.findall(r'func (test\w+)\(\) async( throws)?', test)
    names = [name for name, _ in methods]
    test = test.replace('import XCTest\n', '').replace('@testable import', 'import')
    test = test.replace('SessionEngineTests: XCTestCase', 'SessionEngineScenarios')
    for before, after in [('XCTAssertEqual','expectEqual'),('XCTAssertTrue','expectTrue'),
                          ('XCTAssertFalse','expectFalse'),('XCTUnwrap','requireValue')]:
        test = test.replace(before, after)
    calls = ''
    for name, throwing in methods:
        if throwing:
            calls += f'\n        do {{ let before = failures.count; try await scenarios.{name}(); print("\\(failures.count == before ? "PASS" : "FAIL"): {name}") }} catch {{ failures.append("{name}: \\(error)") }}\n'
        else:
            calls += f'\n        do {{ let before = failures.count; await scenarios.{name}(); print("\\(failures.count == before ? "PASS" : "FAIL"): {name}") }}\n'
    runner = '''
@main @MainActor enum PortableValidation {
    static func main() async {
        let scenarios = SessionEngineScenarios()
        %s
        for failure in failures { print(failure) }
        print("Portable core scenarios: %d; failures: \\(failures.count)")
        if !failures.isEmpty { exit(1) }
    }
}
''' % (calls, len(names))
    source = build / 'PortableValidation.swift'
    source.write_text(test + ADAPTER + runner)
    base = ['swiftc', '-swift-version', '6', '-module-cache-path', str(cache)]
    sources = sorted((repo / 'Sources/KeepOnlineCore').glob('*.swift'))
    subprocess.run(base + ['-emit-library', '-emit-module', '-module-name', 'KeepOnlineCore',
                    '-emit-module-path', str(build / 'KeepOnlineCore.swiftmodule'),
                    *map(str, sources), '-o', str(build / 'libKeepOnlineCore.dylib')], check=True)
    subprocess.run(base + ['-parse-as-library', '-I', str(build), '-L', str(build), '-lKeepOnlineCore',
                    '-Xlinker', '-rpath', '-Xlinker', str(build), str(source),
                    '-o', str(build / 'PortableValidation')], check=True)
    subprocess.run([str(build / 'PortableValidation')], check=True)


if __name__ == '__main__':
    main()
