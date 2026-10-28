// Compile after a normal Debug app build (no user library or sandbox DB is used):
// mkdir -p .build/benchmark evidence/M6
// xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
//   -I .build/DerivedData/Build/Products/Debug \
//   -I .build/SourcePackages/checkouts/GRDB.swift/Sources/GRDBSQLite \
//   scripts/benchmark_scan.swift PersonalSpace/Data/Records.swift \
//   PersonalSpace/Data/LibraryDatabase.swift PersonalSpace/Library/FolderScanner.swift \
//   PersonalSpace/Library/FolderAccess.swift PersonalSpace/ManagedFiles/ManagedFileStore.swift \
//   PersonalSpace/Documents/DocumentTextExtractor.swift \
//   .build/DerivedData/Build/Products/Debug/GRDB.o -lsqlite3 -o .build/benchmark/benchmark_scan
// .build/benchmark/benchmark_scan > evidence/M6/benchmark.txt
import CryptoKit
import Darwin
import Foundation

@main
struct ScanBenchmark {
    private static let fileCount = 10_000

    private static func elapsedMS(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func payload(_ index: Int) -> Data {
        Data("SYNTHETIC PERSONALSPACE M6 BENCHMARK\nRecord \(index)\nNo personal data. Generated only for read-only scanning verification.\n".utf8)
    }

    private static func relativePath(_ index: Int) -> String {
        let directory = String(format: "batch-%03d", index / 100)
        let name = String(format: index % 1_000 == 0 ? "订单合成-%05d.txt" : "合成资料-%05d.txt", index)
        return directory + "/" + name
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BenchmarkFailure(message: message) }
    }

    static func main() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let relativeRun = ".build/benchmark/run-" + UUID().uuidString
        let run = repository.appendingPathComponent(relativeRun, isDirectory: true)
        let source = run.appendingPathComponent("SyntheticSource", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        print("PersonalSpace M6 — actual native scanner benchmark")
        print("timestamp_utc=\(Date().ISO8601Format())")
        print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        #if arch(arm64)
        print("architecture=arm64")
        #elseif arch(x86_64)
        print("architecture=x86_64")
        #endif
        print("logical_processors=\(ProcessInfo.processInfo.processorCount)")
        print("physical_memory_gib=\(String(format: "%.2f", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824))")
        print("profile=benchmark Swift -O; existing Debug GRDB.o; same FolderScanner/LibraryDatabase source as app")
        print("scope=CLI synthetic workspace; not app UI, authorization, or scrolling benchmark")
        print("run_directory=\(relativeRun)")
        print("synthetic_files=\(fileCount); directories=100; content=small UTF-8 text")

        let generationStart = DispatchTime.now().uptimeNanoseconds
        for group in 0..<100 {
            try manager.createDirectory(at: source.appendingPathComponent(String(format: "batch-%03d", group)),
                                        withIntermediateDirectories: false)
        }
        for index in 0..<fileCount {
            try payload(index).write(to: source.appendingPathComponent(relativePath(index)))
        }
        print("generation_ms=\(String(format: "%.3f", elapsedMS(since: generationStart)))")
        let sampleIndices = Array(Set(stride(from: 0, to: fileCount, by: 417)).union([0, 4_999, 9_999])).sorted()
        var hashes: [Int: SHA256.Digest] = [:]
        for index in sampleIndices {
            hashes[index] = SHA256.hash(data: try Data(contentsOf: source.appendingPathComponent(relativePath(index))))
        }

        let database = try LibraryDatabase(path: run.appendingPathComponent("Benchmark.sqlite").path)
        // This tool calls the real scanner directly. It never resolves or opens
        // an app source bookmark and never uses the user's production database.
        try await database.saveSource(id: "benchmark-source", name: "合成性能来源", path: source.path, bookmark: Data())
        let firstStart = DispatchTime.now().uptimeNanoseconds
        try FolderScanner.scan(root: source, sourceID: "benchmark-source", database: database)
        let firstMS = elapsedMS(since: firstStart)
        let first = try await database.files(FileQuery(sourceID: "benchmark-source"))
        try require(first.total == fileCount, "Initial scan did not index exactly 10000 files")
        print("first_scan_ms=\(String(format: "%.3f", firstMS))")
        print("first_scan_count=\(first.total)")
        print("default_visible_result_count=\(first.files.count)")

        let rescanStart = DispatchTime.now().uptimeNanoseconds
        try FolderScanner.scan(root: source, sourceID: "benchmark-source", database: database)
        let rescanMS = elapsedMS(since: rescanStart)
        let rescanned = try await database.files(FileQuery(sourceID: "benchmark-source"))
        try require(rescanned.total == fileCount, "Rescan created missing or duplicate entries")
        print("rescan_ms=\(String(format: "%.3f", rescanMS))")
        print("rescan_count=\(rescanned.total)")

        var queryTimes: [Double] = []
        for _ in 0..<20 {
            let start = DispatchTime.now().uptimeNanoseconds
            let result = try await database.files(FileQuery(search: "合成资料-09999", sourceID: "benchmark-source"))
            queryTimes.append(elapsedMS(since: start))
            try require(result.total == 1 && result.files.first?.relativePath == relativePath(9_999),
                        "Unique name query did not return the correct original path")
        }
        let orderedTimes = queryTimes.sorted()
        print("unique_name_query=合成资料-09999; matches=1; repetitions=20")
        print("name_query_first_ms=\(String(format: "%.3f", queryTimes[0]))")
        print("name_query_median_ms=\(String(format: "%.3f", (orderedTimes[9] + orderedTimes[10]) / 2))")
        print("name_query_p95_ms=\(String(format: "%.3f", orderedTimes[18]))")
        let shortStart = DispatchTime.now().uptimeNanoseconds
        let short = try await database.files(FileQuery(search: "订单", sourceID: "benchmark-source"))
        let shortMS = elapsedMS(since: shortStart)
        try require(short.total == 10, "Short Chinese query did not find all ten synthetic order names")
        print("chinese_short_name_query=订单; matches=\(short.total); elapsed_ms=\(String(format: "%.3f", shortMS))")

        for index in sampleIndices {
            let data = try Data(contentsOf: source.appendingPathComponent(relativePath(index)))
            try require(SHA256.hash(data: data) == hashes[index] && data == payload(index),
                        "A sampled synthetic source changed")
        }
        let reopened = try LibraryDatabase(path: run.appendingPathComponent("Benchmark.sqlite").path)
        let persisted = try await reopened.files(FileQuery(sourceID: "benchmark-source"))
        try require(persisted.total == fileCount, "Database reopen lost indexed files")
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        print("peak_process_rss_mib=\(String(format: "%.2f", Double(usage.ru_maxrss) / 1_048_576))")
        print("source_content_sample_sha256=PASS; unchanged_samples=\(sampleIndices.count)")
        print("reopened_database_count=\(persisted.total)")
        print("result=PASS")
    }
}

private struct BenchmarkFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
