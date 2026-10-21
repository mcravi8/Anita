import Foundation

@main struct RecordLimitChecks {
    @MainActor static func require(_ value: Bool, _ message: String) { if !value { fputs("FAILED: \(message)\n", stderr); exit(1) } }
    struct Run { var status: String }
    @MainActor static func main() throws {
        let busy = ["starting", "answering", "stopping"]

        // Finished runs are dropped oldest first once there are too many; runs still going are never dropped.
        var runs: [String: Run] = [:], order: [String] = []
        for i in 0..<400 {
            let id = "run-\(i)"; runs[id] = Run(status: i % 50 == 0 ? "answering" : "completed"); order.append(id)
            BuddyRecordLimit.prune(order: &order, records: &runs) { !busy.contains($0.status) }
        }
        require(runs.count <= 300, "the number of records is bounded (\(runs.count))")
        require(runs.keys.contains("run-399") && runs.keys.contains("run-390"), "the newest records are kept")
        require(runs.keys.contains("run-0") && runs.keys.contains("run-50") && runs.keys.contains("run-100"), "runs that are still going are never dropped, however old")
        require(!runs.keys.contains("run-1") && !runs.keys.contains("run-2"), "the oldest finished records are the ones dropped")
        require(Set(order) == Set(runs.keys), "the order list stays in step with the records")
        var small: [String: Run] = ["a": Run(status: "completed")], smallOrder = ["a"]
        BuddyRecordLimit.prune(order: &smallOrder, records: &small) { !busy.contains($0.status) }
        require(small.count == 1, "a short list is left alone")
        var allBusy: [String: Run] = [:], busyOrder: [String] = []
        for i in 0..<350 { allBusy["b\(i)"] = Run(status: "answering"); busyOrder.append("b\(i)") }
        BuddyRecordLimit.prune(order: &busyOrder, records: &allBusy) { !busy.contains($0.status) }
        require(allBusy.count == 350, "nothing that is still going is ever dropped, even over the limit")

        // The approval journal archives its oldest settled records before it fills up, and never the ones that guard against repeats.
        var journal: [String: [String: Any]] = [:]
        for i in 0..<9500 {
            let status: String
            switch i { case 0..<5: status = "uncertain"; case 5..<10: status = "pending"; case 10..<15: status = "answered"; default: status = ["completed", "declined", "cancelled", "failed", "expired"][i % 5] }
            journal["rec-\(i)"] = ["id": "rec-\(i)", "status": status, "createdAt": String(format: "2026-01-01T%02d:%02d:%02dZ", i / 3600, (i / 60) % 60, i % 60)]
        }
        let ids = BuddyActionHistory.archivable(journal, live: ["rec-20"])
        require(ids.count == 4500, "the journal is brought down to 5,000 records (\(ids.count))")
        require(ids.allSatisfy { BuddyActionHistory.settled.contains(journal[$0]!["status"] as! String) }, "only settled records are archived")
        require(!ids.contains("rec-0") && !ids.contains("rec-7") && !ids.contains("rec-12"), "uncertain, pending and answered records always stay")
        require(!ids.contains("rec-20"), "a record that is still live in memory always stays")
        let sorted = ids.sorted { Int($0.dropFirst(4))! < Int($1.dropFirst(4))! }
        require(sorted.first == "rec-15" && !ids.contains("rec-9499"), "the oldest settled records go first")
        require(BuddyActionHistory.archivable(Dictionary(uniqueKeysWithValues: journal.prefix(8999).map { ($0.key, $0.value) }), live: []).isEmpty, "a journal below the trigger is left alone")
        // Records saved before timestamps existed are treated as the oldest.
        var legacy = journal; for i in 15..<60 { legacy["rec-\(i)"]?["createdAt"] = nil }
        let legacyIDs = BuddyActionHistory.archivable(legacy, live: [])
        require((15..<60).allSatisfy { legacyIDs.contains("rec-\($0)") }, "records without a timestamp are archived first")
        print("PASS: in-memory records are bounded without dropping a live run, and the approval journal archives only settled old records")
    }
}
