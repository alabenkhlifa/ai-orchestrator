/// Compares two dotted-numeric version strings (specs/36 Task 10, AC-11:
/// "no action when no newer version is published").
///
/// A reasonable *minimal correct* comparison, not a full semver library:
/// purely numeric, dot-separated component-wise comparison. `"1.2.10"` is
/// newer than `"1.2.9"` (numeric, not lexicographic, comparison per
/// component). Missing trailing components compare as `0` (`"1.2"` ==
/// `"1.2.0"`). A non-numeric component (a pre-release/build-metadata
/// suffix, garbage input) reads as `0` via `Int(component) ?? 0` —
/// deliberately permissive rather than throwing, since a malformed
/// `latest_version` in an otherwise validly-signed appcast should degrade to
/// "not newer" (no action) rather than crash the periodic check.
public enum AppVersionComparator {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateComponents = components(candidate)
        let currentComponents = components(current)
        let count = max(candidateComponents.count, currentComponents.count)

        for index in 0..<count {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if candidatePart != currentPart {
                return candidatePart > currentPart
            }
        }

        return false
    }

    static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }
}
