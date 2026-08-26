import DocCore
import Foundation

/// Choosing a model for the machine it will run on, and giving the disk back
/// afterwards.
///
/// None of this needs MLX, a GPU, or a download, which is the point of it
/// living in `DocCore`: the arithmetic that decides whether a Mac can hold a
/// model is a fact about sizes, and the code that deletes four gigabytes off
/// somebody's disk is ordinary file handling that had better be checked.
func runModelChecks(_ report: Report) {
    runCatalogueChecks(report)
    runStorageChecks(report)
    runMachineChecks(report)
}

/// A Mac, described. Everything about the recommendation is a function of
/// these four numbers, so the checks fabricate them rather than asking the
/// machine the suite happens to be running on.
private func mac(
    memoryGB: Int,
    freeDiskGB: Int = 500,
    appleSilicon: Bool = true
) -> MachineCapability {
    // Binary gigabytes, because that is what `physicalMemory` reports and the
    // difference is not cosmetic: a "16 GB" Mac has 17.2 thousand million
    // bytes, and the model that fits in three quarters of the one does not
    // necessarily fit in three quarters of the other.
    MachineCapability(
        isAppleSilicon: appleSilicon,
        chip: "Apple M-something",
        memoryBytes: Int64(memoryGB) << 30,
        cores: 10,
        freeDiskBytes: Int64(freeDiskGB) << 30
    )
}

private func runCatalogueChecks(_ report: Report) {
    report.begin("models/recommendation")

    // The whole reason for asking the machine: the same default on every Mac
    // is wrong in both directions. On eight gigabytes a 7B model does not run
    // slowly, it swaps; on sixty-four the 3B leaves most of the machine idle
    // while a smaller model misreads figures.
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(for: mac(memoryGB: 8)).id,
        LocalModelCatalogue.qwen2_5VL3B.id,
        "an eight-gigabyte Mac is offered the 3B and no more"
    )

    // A model already downloaded beats a larger one that is not, and this is
    // the rule that keeps an app update from being a betrayal: without it,
    // the model somebody has been using for months becomes "not in use" the
    // moment they upgrade, the app wants five gigabytes fetched before it can
    // read a page, and the screen that offers to reclaim disk space offers to
    // delete the working model.
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(
            for: mac(memoryGB: 16),
            alreadyOnDisk: [LocalModelCatalogue.qwen2_5VL3B.id]
        ).id,
        LocalModelCatalogue.qwen2_5VL3B.id,
        "a model already on the Mac is used rather than a larger download"
    )
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(
            for: mac(memoryGB: 16),
            alreadyOnDisk: [
                LocalModelCatalogue.qwen2_5VL3B.id,
                LocalModelCatalogue.qwen3VL4B.id
            ]
        ).id,
        LocalModelCatalogue.qwen3VL4B.id,
        "and the largest of them where there are several"
    )
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(
            for: mac(memoryGB: 16),
            alreadyOnDisk: [LocalModelCatalogue.qwen2_5VL32B.id]
        ).id,
        LocalModelCatalogue.qwen2_5VL7B.id,
        "but one this Mac cannot hold is not used just because it is here"
    )
    report.equal(
        LocalModelCatalogue.largestVisionModel(for: mac(memoryGB: 16)).id,
        LocalModelCatalogue.qwen2_5VL7B.id,
        "and what the Mac could run is still asked separately, so the "
            + "interface can offer it"
    )
    // Nothing in the catalogue fits, so the smallest is offered anyway — with
    // the obstacle attached rather than an empty screen. An app that answers
    // "no model" to "which model" has told the reader nothing.
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(for: mac(memoryGB: 4)).id,
        LocalModelCatalogue.qwen2VL2B.id,
        "and a Mac too small for any of them is shown the smallest"
    )
    report.expect(
        LocalModelCatalogue.obstacle(
            to: LocalModelCatalogue.qwen2VL2B,
            on: mac(memoryGB: 4)
        ) != nil,
        "with what is in the way of it said plainly"
    )
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(for: mac(memoryGB: 16)).id,
        LocalModelCatalogue.qwen2_5VL7B.id,
        "sixteen gigabytes takes the 7B"
    )
    report.equal(
        LocalModelCatalogue.recommendedVisionModel(for: mac(memoryGB: 64)).id,
        LocalModelCatalogue.qwen2_5VL32B.id,
        "and sixty-four takes the largest reader there is"
    )

    // Being wrong upwards is the expensive direction, so the comparison is
    // against the working set — weights plus the page image expanded into
    // tokens — rather than against the download size.
    report.expect(
        LocalModelCatalogue.qwen2_5VL7B.workingSetBytes
            > LocalModelCatalogue.qwen2_5VL7B.approximateBytes,
        "a model costs more memory to run than it takes on disk"
    )
    report.expect(
        !mac(memoryGB: 8).canHold(
            workingSet: LocalModelCatalogue.qwen2_5VL32B.workingSetBytes
        ),
        "and the large model is refused where it would not fit"
    )

    report.begin("models/second-model")

    // A separate text model is the exception, not the plan. One model doing
    // both jobs costs one download and one set of resident weights; two is
    // only worth it where both fit at once.
    report.expect(
        LocalModelCatalogue.recommendedTextModel(
            for: mac(memoryGB: 16),
            alongside: LocalModelCatalogue.qwen2_5VL7B
        ) == nil,
        "a sixteen-gigabyte Mac holding a 7B reader is not offered a second"
    )
    report.equal(
        LocalModelCatalogue.recommendedTextModel(
            for: mac(memoryGB: 64),
            alongside: LocalModelCatalogue.qwen2_5VL7B
        )?.id,
        LocalModelCatalogue.qwen3_30B_A3B.id,
        "and one with room for both is"
    )
    report.expect(
        !LocalModelCatalogue.canHoldBoth(
            LocalModelCatalogue.qwen2_5VL32B,
            LocalModelCatalogue.qwen3_30B_A3B,
            on: mac(memoryGB: 64)
        ),
        "two of the largest models at once is refused even on a large Mac"
    )

    report.begin("models/obstacles")

    // An engine that says "unavailable" and stops is the failure this whole
    // app is written against, so every refusal says what is in the way.
    report.expect(
        LocalModelCatalogue.obstacle(
            to: LocalModelCatalogue.qwen2_5VL3B,
            on: mac(memoryGB: 32)
        ) == nil,
        "a model that fits has nothing in the way of it"
    )
    report.expect(
        LocalModelCatalogue.obstacle(
            to: LocalModelCatalogue.qwen2_5VL32B,
            on: mac(memoryGB: 16)
        )?.contains("memory") == true,
        "one that does not fit in memory says so, with both numbers"
    )
    report.expect(
        LocalModelCatalogue.obstacle(
            to: LocalModelCatalogue.qwen2_5VL7B,
            on: mac(memoryGB: 32, freeDiskGB: 2)
        )?.contains("on disk") == true,
        "and one that would not fit on the disk says that instead"
    )
    report.expect(
        LocalModelCatalogue.obstacle(
            to: LocalModelCatalogue.qwen2VL2B,
            on: mac(memoryGB: 32, appleSilicon: false)
        ) != nil,
        "an Intel Mac is told the app's own models cannot run there at all"
    )
    report.expect(
        LocalModelCatalogue.all.allSatisfy {
            LocalModelCatalogue.model(id: $0.id) != nil
        },
        "every model in the catalogue can be found by its identifier"
    )
}

private func runStorageChecks(_ report: Report) {
    report.begin("models/storage")

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("laesesalen-checks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    func install(_ id: String, weights: Bool = true, bytes: Int = 2_048) {
        guard let directory = LocalModelStorage.directory(for: id, in: root)
        else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let name = weights ? "model.safetensors" : "config.json"
        try? Data(repeating: 7, count: bytes).write(
            to: directory.appendingPathComponent(name)
        )
    }

    // An identifier is two components and nothing else. This is the path a
    // deletion is performed on and the identifier reaching it came out of a
    // preferences file, so the validation is the guard rather than a tidiness
    // rule.
    report.expect(
        LocalModelStorage.directory(for: "../../../Documents", in: root) == nil,
        "a relative path is not a model identifier"
    )
    report.expect(
        LocalModelStorage.directory(for: "mlx-community", in: root) == nil,
        "and neither is one component"
    )
    report.expect(
        LocalModelStorage.directory(for: "a/b/c", in: root) == nil,
        "and neither is three"
    )
    report.expect(
        LocalModelStorage.directory(for: "mlx-community/x", in: root) != nil,
        "an organisation and a repository is"
    )

    install(LocalModelCatalogue.qwen2_5VL3B.id)
    install(LocalModelCatalogue.qwen3_8B.id)
    install("mlx-community/Some-Model-Nobody-Offers-Any-More")
    install("mlx-community/Interrupted-Download", weights: false)

    report.expect(
        LocalModelStorage.isOnDisk(LocalModelCatalogue.qwen2_5VL3B.id, in: root),
        "a model with weights in it is on disk"
    )
    report.expect(
        !LocalModelStorage.isOnDisk(
            "mlx-community/Interrupted-Download",
            in: root
        ),
        "a directory with no weights in it is not — that is a half download, "
            + "and treating it as a model makes the first page a silent fetch"
    )
    report.equal(
        LocalModelStorage.installed(in: root).count,
        4,
        "everything under the models directory is found"
    )
    report.expect(
        LocalModelStorage.installed(in: root)
            .first { $0.id.hasSuffix("Nobody-Offers-Any-More") }?
            .isOrphan == true,
        "including a model this version of the app no longer offers"
    )
    report.expect(
        LocalModelStorage.totalBytes(in: root) > 0,
        "and the total is what the reader is being asked about"
    )

    // The two kinds of unused download, and the second is the one nothing
    // else on any screen would ever mention again.
    let spare = LocalModelStorage.unused(
        keeping: [LocalModelCatalogue.qwen2_5VL3B.id],
        in: root
    )
    report.equal(spare.count, 3, "everything not in use is offered for removal")
    report.expect(
        !spare.contains { $0.id == LocalModelCatalogue.qwen2_5VL3B.id },
        "and the model in use is not"
    )

    report.expect(
        (try? LocalModelStorage.remove("../../Documents", in: root)) == nil,
        "removing something that is not a model identifier fails"
    )
    let freed = try? LocalModelStorage.remove(
        LocalModelCatalogue.qwen3_8B.id,
        in: root
    )
    report.expect((freed ?? 0) > 0, "removing a model reports what it freed")
    report.expect(
        !LocalModelStorage.isOnDisk(LocalModelCatalogue.qwen3_8B.id, in: root),
        "and it is gone"
    )
    report.equal(
        try? LocalModelStorage.remove(LocalModelCatalogue.qwen3_8B.id, in: root),
        0,
        "removing it twice is not an error, and frees nothing the second time"
    )
}

private func runMachineChecks(_ report: Report) {
    report.begin("models/machine")

    let here = MachineCapability.thisMac()
    report.expect(here.memoryBytes > 0, "the machine reports its memory")
    report.expect(!here.chip.isEmpty, "and what chip it has")
    report.expect(
        here.usableMemoryBytes < here.memoryBytes,
        "a model is never offered the whole machine: the window, the page "
            + "images and everything else the reader has open live in the rest"
    )
    report.expect(
        !here.summary.isEmpty,
        "and it can say all that in one line the reader can check"
    )

    // Free space is a property of a volume. Asking about a directory that
    // does not exist yet — which is every first run — must not report zero
    // and refuse the download.
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("no-such-directory-\(UUID().uuidString)")
        .appendingPathComponent("nor-this-one")
    report.expect(
        MachineCapability.freeBytes(at: missing) > 0,
        "free space is found for a directory that has not been created yet"
    )
}
