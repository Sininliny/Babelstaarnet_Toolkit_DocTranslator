import Foundation

/// What the checks report to.
///
/// Deliberately tiny. The point of a check in this project is to fail loudly
/// on a machine with nothing installed, so the harness has no dependencies,
/// no discovery, and no configuration — a function, a name, and a boolean.
final class Report {
    private(set) var passed = 0
    private(set) var failures: [(group: String, message: String)] = []
    private var group = ""

    func begin(_ group: String) {
        self.group = group
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passed += 1
        } else {
            failures.append((group, message()))
        }
    }

    func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String
    ) {
        if actual == expected {
            passed += 1
        } else {
            failures.append(
                (group, "\(message()) — got \(actual), wanted \(expected)")
            )
        }
    }

    func near(
        _ actual: Double,
        _ expected: Double,
        _ tolerance: Double,
        _ message: @autoclosure () -> String
    ) {
        if abs(actual - expected) <= tolerance {
            passed += 1
        } else {
            failures.append(
                (group, "\(message()) — got \(actual), wanted ~\(expected)")
            )
        }
    }

    func summarize() -> Int32 {
        if failures.isEmpty {
            print("All \(passed) checks passed.")
            return 0
        }
        print("\(passed) passed, \(failures.count) failed:\n")
        for failure in failures {
            print("  ✗ [\(failure.group)] \(failure.message)")
        }
        return 1
    }
}
