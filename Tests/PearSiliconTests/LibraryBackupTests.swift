import CryptoKit
import Darwin
import Foundation
import Testing
@testable import PearSilicon

struct LibraryBackupTests {
    @Test(arguments: LibraryPlatform.allCases)
    func roundTripsTheEntireEntry(platform: LibraryPlatform) async throws {
        let fixture = try Fixture(platform: platform)
        defer { fixture.remove() }
        let service = fixture.service()
        let archive = try await service.backup(entry: fixture.entry, to: fixture.output)
        #expect(archive.pathExtension == "pearbackup")
        #expect(try permissions(archive) == 0o600)
        let restored = try await service.restore(from: archive, to: fixture.restoreRoot)
        #expect(restored.directoryURL == fixture.destination)
        #expect(restored.manifest == fixture.entry.manifest)
        #expect(restored.manifest.preparedDirectoryPath == fixture.entry.manifest.preparedDirectoryPath)
        #expect(try permissions(restored.directoryURL) == 0o710)
        for (path, data) in fixture.files {
            #expect(try Data(contentsOf: restored.directoryURL.appendingPathComponent(path)) == data)
            #expect(try Data(contentsOf: fixture.entry.directoryURL.appendingPathComponent(path)) == data)
        }
        #expect(try permissions(restored.directoryURL.appendingPathComponent(fixture.executable)) == 0o751)
        #expect(FileManager.default.fileExists(atPath: restored.directoryURL.appendingPathComponent("Data/empty-directory").path))
        #expect(try Data(contentsOf: restored.manifestURL) == Data(contentsOf: fixture.entry.manifestURL))
        try fixture.expectNoStaging()
    }

    @Test
    func streamsMultiChunkFilesAndResourceForksAndPreservesXattrs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let large = fixture.entry.directoryURL.appendingPathComponent("Data/large.bin")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let writer = try FileHandle(forWritingTo: large)
        var expectedHash = SHA256()
        for byte in UInt8(0)..<6 {
            let chunk = Data(repeating: byte, count: 1_024 * 1_024 + 31)
            try writer.write(contentsOf: chunk)
            expectedHash.update(data: chunk)
        }
        try writer.close()
        let resourceFork = Data((0..<(2 * 1_024 * 1_024 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        try setAttribute("com.apple.ResourceFork", data: resourceFork, at: large)
        try setAttribute("com.apple.cs.CodeDirectory", data: Data("synthetic-signature-metadata".utf8), at: large)
        try setAttribute("com.pearsilicon.empty", data: Data(), at: large)
        try setAttribute("com.pearsilicon.directory", data: Data("directory metadata".utf8), at: fixture.entry.dataURL)
        try setAttribute("com.pearsilicon.root", data: Data("root metadata".utf8), at: fixture.entry.directoryURL)
        let before = try fileStatus(large)
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let restored = try await fixture.service().restore(from: archive, to: fixture.restoreRoot)
        let copy = restored.dataURL.appendingPathComponent("large.bin")
        let reader = try FileHandle(forReadingFrom: copy)
        defer { try? reader.close() }
        var actualHash = SHA256()
        while let chunk = try reader.read(upToCount: 262_144), !chunk.isEmpty { actualHash.update(data: chunk) }
        #expect(Data(actualHash.finalize()) == Data(expectedHash.finalize()))
        #expect(try attribute("com.apple.ResourceFork", at: copy) == resourceFork)
        #expect(try attribute("com.apple.cs.CodeDirectory", at: copy) == Data("synthetic-signature-metadata".utf8))
        #expect(try attribute("com.pearsilicon.empty", at: copy).isEmpty)
        #expect(try attribute("com.pearsilicon.directory", at: restored.dataURL) == Data("directory metadata".utf8))
        #expect(try attribute("com.pearsilicon.root", at: restored.directoryURL) == Data("root metadata".utf8))
        let after = try fileStatus(copy)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
        #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    }

    @Test
    func preservesFrameworkSymlinkChains() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let framework = "Payload/Game.app/Contents/Frameworks/Test.framework"
        try fixture.write(framework + "/Versions/A/Test", Data("framework executable".utf8))
        try fixture.link(framework + "/Versions/Current", target: "A")
        try fixture.link(framework + "/Test", target: "Versions/Current/Test")
        let sourceTarget = fixture.entry.directoryURL.appendingPathComponent(framework + "/Versions/A/Test")
        #expect(chmod(sourceTarget.path, 0o751) == 0)
        let sourceLink = fixture.entry.directoryURL.appendingPathComponent(framework + "/Test")
        try setAttribute("com.pearsilicon.symlink", data: Data("link metadata".utf8), at: sourceLink)
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let restored = try await fixture.service().restore(from: archive, to: fixture.restoreRoot)
        let link = restored.directoryURL.appendingPathComponent(framework + "/Test")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "Versions/Current/Test")
        #expect(try Data(contentsOf: link) == Data("framework executable".utf8))
        #expect(try permissions(restored.directoryURL.appendingPathComponent(framework + "/Versions/A/Test")) == 0o751)
        #expect(try attribute("com.pearsilicon.symlink", at: link) == Data("link metadata".utf8))
    }

    @Test
    func supportsWineCDriveButRefusesHostZDrive() async throws {
        let fixture = try Fixture(platform: .wine)
        defer { fixture.remove() }
        try fixture.link("Prefix/dosdevices/c:", target: "../drive_c")
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let restored = try await fixture.service().restore(from: archive, to: fixture.restoreRoot)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.prefixURL.appendingPathComponent("dosdevices/c:").path) == "../drive_c")
        #expect(try Data(contentsOf: restored.prefixURL.appendingPathComponent("dosdevices/c:/Game/game.exe")) == fixture.files[fixture.executable])
        try fixture.link("Prefix/dosdevices/z:", target: "/")
        let rejected = fixture.root.appendingPathComponent("host-linked")
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: rejected) }
        #expect(!FileManager.default.fileExists(atPath: rejected.appendingPathExtension("pearbackup").path))
        try fixture.expectNoStaging()
    }

    @Test
    func flattensHardlinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.entry.dataURL.appendingPathComponent("Documents/save.dat")
        let alias = fixture.entry.dataURL.appendingPathComponent("save-hardlink.dat")
        #expect(Darwin.link(original.path, alias.path) == 0)
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let restored = try await fixture.service().restore(from: archive, to: fixture.restoreRoot)
        let a = restored.dataURL.appendingPathComponent("Documents/save.dat")
        let b = restored.dataURL.appendingPathComponent("save-hardlink.dat")
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        #expect(try fileStatus(a).st_ino != fileStatus(b).st_ino)
        #expect(try fileStatus(a).st_nlink == 1)
    }

    @Test
    func refusesFIFOsAndPrivilegedModesWithoutOpeningThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fifo = fixture.entry.directoryURL.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: fixture.output) }
        try FileManager.default.removeItem(at: fifo)
        let file = fixture.entry.directoryURL.appendingPathComponent(fixture.executable)
        #expect(chmod(file.path, 0o4755) == 0)
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: fixture.output) }
        try fixture.expectNoStaging()
    }

    @Test
    func refusesExistingBackupFilesAndDanglingSymlinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = fixture.output.appendingPathExtension("pearbackup")
        let sentinel = Data("keep existing backup".utf8)
        try sentinel.write(to: output)
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: fixture.output) }
        #expect(try Data(contentsOf: output) == sentinel)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: "missing-backup")
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: fixture.output) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: output.path) == "missing-backup")
        try fixture.expectNoStaging()
    }

    @Test
    func refusesExistingRestoreEvenWhenItIsAnEmptyDirectoryOrDanglingLink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        await expectFailure { _ = try await fixture.service().restore(from: archive, to: fixture.restoreRoot) }
        let sentinel = fixture.destination.appendingPathComponent("keep")
        try Data("old install".utf8).write(to: sentinel)
        await expectFailure { _ = try await fixture.service().restore(from: archive, to: fixture.restoreRoot) }
        #expect(try Data(contentsOf: sentinel) == Data("old install".utf8))
        try FileManager.default.removeItem(at: fixture.destination)
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: "missing-install")
        await expectFailure { _ = try await fixture.service().restore(from: archive, to: fixture.restoreRoot) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path) == "missing-install")
        try fixture.expectNoStaging()
    }

    @Test
    func exclusiveCommitsKeepTargetsThatAppearAfterAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = fixture.output.appendingPathExtension("pearbackup")
        let counter = Counter()
        let racingBackup = fixture.service(requireStopped: { _ in
            if await counter.next() == 2 { try Data("racing writer".utf8).write(to: output) }
        })
        await expectFailure { _ = try await racingBackup.backup(entry: fixture.entry, to: fixture.output) }
        #expect(try Data(contentsOf: output) == Data("racing writer".utf8))
        try FileManager.default.removeItem(at: output)
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let restoreCounter = Counter()
        let destination = fixture.destination
        let racingRestore = fixture.service(requireStopped: { _ in
            if await restoreCounter.next() == 2 {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("racing install".utf8).write(to: destination.appendingPathComponent("keep"))
            }
        })
        await expectFailure { _ = try await racingRestore.restore(from: archive, to: fixture.restoreRoot) }
        #expect(try Data(contentsOf: destination.appendingPathComponent("keep")) == Data("racing install".utf8))
        try fixture.expectNoStaging()
    }

    @Test
    func lateRestoreFailureCleansEvenUnreadableArchivedDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let unreadable = try fixture.rewrite(archive) { json in
            var root = try #require(json["root"] as? [String: Any])
            root["mode"] = 0
            json["root"] = root
            var nodes = try nodeArray(json)
            let index = try #require(nodes.firstIndex { $0["path"] as? String == "Data" })
            var metadata = try #require(nodes[index]["metadata"] as? [String: Any])
            metadata["mode"] = 0
            nodes[index]["metadata"] = metadata
            json["nodes"] = nodes
        }
        let counter = Counter()
        let destination = fixture.destination
        let service = fixture.service(requireStopped: { _ in
            if await counter.next() == 2 {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            }
        })
        do {
            _ = try await service.restore(from: unreadable, to: fixture.restoreRoot)
            Issue.record("A late destination conflict must not commit")
        } catch {
            #expect(error.localizedDescription.contains("already exists"))
        }
        #expect(await counter.value == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try fixture.expectNoStaging()
    }

    @Test
    func guardsDiskSpaceAndConfigurableLimits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let noSpace = LibraryBackupService(requireStopped: { _ in }, availableCapacity: { _ in 0 })
        await expectFailure { _ = try await noSpace.backup(entry: fixture.entry, to: fixture.output) }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        await expectFailure { _ = try await noSpace.restore(from: archive, to: fixture.restoreRoot) }
        for limits in [
            LibraryBackupService.Limits(maximumInventoryBytes: 64),
            LibraryBackupService.Limits(maximumEntries: 1),
            LibraryBackupService.Limits(maximumFileBytes: 1),
            LibraryBackupService.Limits(maximumPayloadBytes: 1),
        ] {
            let limited = fixture.service(limits: limits)
            await expectFailure { _ = try await limited.backup(entry: fixture.entry, to: fixture.root.appendingPathComponent("limited")) }
            await expectFailure { _ = try await limited.restore(from: archive, to: fixture.restoreRoot) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.expectNoStaging()
    }

    @Test
    func invokesRunningGuardsBeforeWorkAndBeforeBothCommits() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stopped = fixture.service(requireStopped: { _ in throw GuardFailure.running })
        await expectFailure { _ = try await stopped.backup(entry: fixture.entry, to: fixture.output) }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathExtension("pearbackup").path))
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        await expectFailure { _ = try await stopped.restore(from: archive, to: fixture.restoreRoot) }
        let backupCounter = Counter()
        let lateBackup = fixture.service(requireStopped: { _ in
            if await backupCounter.next() == 2 { throw GuardFailure.running }
        })
        await expectFailure { _ = try await lateBackup.backup(entry: fixture.entry, to: fixture.root.appendingPathComponent("late")) }
        let restoreCounter = Counter()
        let lateRestore = fixture.service(requireStopped: { entry in
            #expect(entry.directoryURL == fixture.destination)
            if await restoreCounter.next() == 2 { throw GuardFailure.running }
        })
        await expectFailure { _ = try await lateRestore.restore(from: archive, to: fixture.restoreRoot) }
        #expect(await backupCounter.value == 2)
        #expect(await restoreCounter.value == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.expectNoStaging()
    }

    @Test
    func detectsSourceMutationBeforeCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let file = fixture.entry.dataURL.appendingPathComponent("Documents/save.dat")
        let service = fixture.service(requireStopped: { _ in
            if await counter.next() == 2 { try Data("changed save".utf8).write(to: file) }
        })
        await expectFailure { _ = try await service.backup(entry: fixture.entry, to: fixture.output) }
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathExtension("pearbackup").path))
        #expect(try Data(contentsOf: file) == Data("changed save".utf8))
        try fixture.expectNoStaging()
    }

    @Test
    func propagatesCancellationAndCleansStaging() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        for restoring in [false, true] {
            let counter = Counter()
            let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let service = fixture.service(requireStopped: { _ in
                if await counter.next() == 2 {
                    continuation.yield(())
                    try await Task.sleep(for: .seconds(30))
                }
            })
            let work = Task {
                if restoring {
                    _ = try await service.restore(from: archive, to: fixture.restoreRoot)
                } else {
                    _ = try await service.backup(entry: fixture.entry, to: fixture.root.appendingPathComponent("cancelled"))
                }
            }
            for await _ in events { break }
            work.cancel()
            do {
                try await work.value
                Issue.record("Cancelled operation unexpectedly committed")
            } catch {
                #expect(error is CancellationError)
            }
            continuation.finish()
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancelled.pearbackup").path))
            try fixture.expectNoStaging()
        }
    }

    @Test
    func detectsCorruptionTruncationAndTrailingBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let original = try Data(contentsOf: archive)
        let inventoryLength = Int(integer(original, at: 12, count: 8))
        var variants = [Data]()
        for count in [0, 7, 19, 51, 52 + inventoryLength - 1, original.count - 1] { variants.append(Data(original.prefix(count))) }
        var badMagic = original
        badMagic[0] ^= 0xff
        variants.append(badMagic)
        var badInventory = original
        badInventory[52] ^= 1
        variants.append(badInventory)
        var badPayload = original
        badPayload[badPayload.count - 1] ^= 1
        variants.append(badPayload)
        var trailing = original
        trailing.append(0)
        variants.append(trailing)
        var hugeInventory = original
        hugeInventory.replaceSubrange(12..<20, with: bigEndian(UInt64.max, bytes: 8))
        variants.append(hugeInventory)
        var badVersion = original
        badVersion.replaceSubrange(8..<12, with: bigEndian(2, bytes: 4))
        variants.append(badVersion)
        for bytes in variants {
            let malicious = fixture.root.appendingPathComponent("corrupted.pearbackup")
            try bytes.write(to: malicious)
            await expectFailure { _ = try await fixture.service().restore(from: malicious, to: fixture.restoreRoot) }
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            try fixture.expectNoStaging()
        }
    }

    @Test
    func detectsCorruptedExtendedAttributeBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = Data("unique-root-attribute-value".utf8)
        try setAttribute("com.pearsilicon.root", data: marker, at: fixture.entry.directoryURL)
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        var bytes = try Data(contentsOf: archive)
        let range = try #require(bytes.range(of: marker))
        bytes[range.lowerBound] ^= 1
        let bad = fixture.root.appendingPathComponent("bad-attribute.pearbackup")
        try bytes.write(to: bad)
        await expectFailure { _ = try await fixture.service().restore(from: bad, to: fixture.restoreRoot) }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.expectNoStaging()
    }

    @Test
    func rejectsTraversalDuplicateAndCaseCollidingInventoryPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        for path in ["../escape", "/absolute", "Data/../../escape", "Data/./escape", "Data//escape", "Data/", "Data\\escape", "C:/escape", "Data/\u{0}escape", String(repeating: "x", count: 256)] {
            let bad = try fixture.rewrite(archive) { json in
                var nodes = try nodeArray(json)
                var node = try #require(nodes.first { $0["kind"] as? String == "file" })
                node["path"] = path
                nodes.append(node)
                json["nodes"] = nodes
            }
            await expectFailure { _ = try await fixture.service().restore(from: bad, to: fixture.restoreRoot) }
        }
        for collision in ["Data/Documents/save.dat", "data/documents/SAVE.dat"] {
            let bad = try fixture.rewrite(archive) { json in
                var nodes = try nodeArray(json)
                var node = try #require(nodes.first { $0["path"] as? String == "Data/Documents/save.dat" })
                node["path"] = collision
                nodes.append(node)
                json["nodes"] = nodes
            }
            await expectFailure { _ = try await fixture.service().restore(from: bad, to: fixture.restoreRoot) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.expectNoStaging()
    }

    @Test
    func rejectsSymlinkParentsEscapesChainsCyclesAndDanglingLinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let parentAttack = try fixture.rewrite(archive) { json in
            var nodes = try nodeArray(json)
            let index = try #require(nodes.firstIndex { $0["path"] as? String == "Data" })
            nodes[index]["kind"] = "symlink"
            nodes[index]["target"] = "Payload"
            json["nodes"] = nodes
        }
        await expectFailure { _ = try await fixture.service().restore(from: parentAttack, to: fixture.restoreRoot) }
        let targets: [[(String, String)]] = [
            [("Data/evil", "../../outside")],
            [("Data/evil", "/tmp")],
            [("Data/evil", "missing")],
            [("Data/evil", "a"), ("Data/a", "evil")],
            [("Data/a", "../Payload"), ("Data/evil", "a/../../outside")],
        ]
        for links in targets {
            let bad = try fixture.rewrite(archive) { json in
                var nodes = try nodeArray(json)
                let template = try #require(nodes.first { $0["kind"] as? String == "directory" })
                for (path, target) in links {
                    var node = template
                    node["path"] = path
                    node["kind"] = "symlink"
                    node["target"] = target
                    nodes.append(node)
                }
                json["nodes"] = nodes
            }
            await expectFailure { _ = try await fixture.service().restore(from: bad, to: fixture.restoreRoot) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        try fixture.expectNoStaging()
    }

    @Test
    func rejectsMaliciousManifestMetadataAndSizeClaims() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { $0["schemaVersion"] = 2 },
            { json in var entry = try entryObject(json); entry["id"] = "../outside"; json["entry"] = entry },
            { json in var entry = try entryObject(json); entry["payloadPath"] = "../outside"; json["entry"] = entry },
            { json in var entry = try entryObject(json); entry["platform"] = "../outside"; json["entry"] = entry },
            { json in var entry = try entryObject(json); entry["formatVersion"] = 2; json["entry"] = entry },
            { json in var root = try #require(json["root"] as? [String: Any]); root["mode"] = 0o4755; json["root"] = root },
            { json in var root = try #require(json["root"] as? [String: Any]); root["modifiedNanoseconds"] = 1_000_000_000; json["root"] = root },
            { json in
                var nodes = try nodeArray(json)
                let index = try #require(nodes.firstIndex { $0["kind"] as? String == "file" })
                nodes[index]["size"] = NSNumber(value: UInt64.max)
                json["nodes"] = nodes
            },
            { json in
                var nodes = try nodeArray(json)
                let index = try #require(nodes.firstIndex { $0["kind"] as? String == "file" })
                nodes[index]["sha256"] = "not-a-sha256"
                json["nodes"] = nodes
            },
            { json in
                var root = try #require(json["root"] as? [String: Any])
                root["attributes"] = [["name": "com.apple.ResourceFork", "size": NSNumber(value: UInt64.max), "sha256": String(repeating: "0", count: 64)]]
                json["root"] = root
            },
            // Valid envelope metadata still must agree with the streamed pear-app.json.
            { json in var entry = try entryObject(json); entry["displayName"] = "forged metadata"; json["entry"] = entry },
        ]
        for mutation in mutations {
            let bad = try fixture.rewrite(archive, mutation)
            await expectFailure { _ = try await fixture.service().restore(from: bad, to: fixture.restoreRoot) }
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            try fixture.expectNoStaging()
        }
    }

    @Test
    func refusesPlatformAndInputSymlinksAndNestedOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nested = fixture.entry.dataURL.appendingPathComponent("nested-backup")
        await expectFailure { _ = try await fixture.service().backup(entry: fixture.entry, to: nested) }
        let archive = try await fixture.service().backup(entry: fixture.entry, to: fixture.output)
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.destination.deletingLastPathComponent(), withDestinationURL: outside)
        await expectFailure { _ = try await fixture.service().restore(from: archive, to: fixture.restoreRoot) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let alias = fixture.root.appendingPathComponent("archive-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archive)
        await expectFailure { _ = try await fixture.service().restore(from: alias, to: fixture.restoreRoot) }
        await expectFailure { _ = try await fixture.service().restore(from: archive, to: fixture.root.appendingPathComponent("unavailable")) }
        try fixture.expectNoStaging()
    }

    @Test
    func runningPathChecksDistinguishOtherCopiesAndPrefixSiblings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(LibraryBackupService.processBelongsToEntry(bundle: fixture.entry.payloadURL, executable: nil, entry: fixture.entry))
        #expect(LibraryBackupService.processBelongsToEntry(bundle: nil, executable: fixture.entry.directoryURL.appendingPathComponent(fixture.executable), entry: fixture.entry))
        let anotherCopy = fixture.root.appendingPathComponent("another-copy/Payload/Game.app")
        #expect(!LibraryBackupService.processBelongsToEntry(bundle: anotherCopy, executable: nil, entry: fixture.entry))
        let sibling = URL(fileURLWithPath: fixture.entry.directoryURL.path + "-other/Payload/Game.app")
        #expect(!LibraryBackupService.processBelongsToEntry(bundle: sibling, executable: nil, entry: fixture.entry))
        #expect(!LibraryBackupService.processBelongsToEntry(bundle: nil, executable: nil, entry: fixture.entry))
    }

    @Test
    func defaultGuardFindsNativeProcessesByTheirActualTemporaryExecutablePath() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = fixture.entry.directoryURL.appendingPathComponent(fixture.executable)
        try FileManager.default.removeItem(at: executable)
        // This is a throwaway copy, not a real installed app or user library.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        for platform in [LibraryPlatform.macOS, .iOS] {
            var entry = fixture.entry
            entry.manifest.platform = platform
            await expectFailure { try await LibraryBackupService.defaultRunningGuard(entry) }
        }
        let other = LibraryEntry(manifest: fixture.entry.manifest, directoryURL: fixture.root.appendingPathComponent("another-copy"))
        try await LibraryBackupService.defaultRunningGuard(other)
    }

    @Test
    func parsesWinePrefixOnlyFromBoundedKernelEnvironmentNotArguments() throws {
        func arguments(argv: [String], environment: [String]) -> [UInt8] {
            var argc = Int32(argv.count)
            var bytes = withUnsafeBytes(of: &argc) { Array($0) }
            bytes += Array("/synthetic/wine64".utf8) + [0, 0, 0]
            for value in argv + environment { bytes += Array(value.utf8) + [0] }
            bytes.append(0)
            return bytes
        }
        let prefix = "/synthetic/entry/Prefix"
        let valid = arguments(argv: ["wine64", "Game.exe"], environment: ["A=B", "WINEPREFIX=" + prefix, "C=D"])
        #expect(LibraryBackupService.winePrefix(inProcessArguments: valid)?.path == prefix)
        let argumentOnly = arguments(argv: ["wine64", "WINEPREFIX=" + prefix], environment: ["A=B"])
        #expect(LibraryBackupService.winePrefix(inProcessArguments: argumentOnly) == nil)
        let relative = arguments(argv: ["wine64"], environment: ["WINEPREFIX=relative/Prefix"])
        #expect(LibraryBackupService.winePrefix(inProcessArguments: relative) == nil)
        for bytes in [[], [0, 0, 0], [255, 255, 255, 255], Array(valid.prefix(8)), Array(valid.dropLast(6))] as [[UInt8]] {
            #expect(LibraryBackupService.winePrefix(inProcessArguments: bytes) == nil)
        }
    }

    // MARK: - Synthetic fixtures (never the installed/current library)

    private enum GuardFailure: Error { case running }

    private actor Counter {
        var value = 0
        func next() -> Int { value += 1; return value }
    }

    private struct Fixture: Sendable {
        let root: URL
        let restoreRoot: URL
        let output: URL
        let entry: LibraryEntry
        let executable: String
        let files: [String: Data]
        var destination: URL {
            restoreRoot.appendingPathComponent(entry.platform.rawValue, isDirectory: true)
                .appendingPathComponent(entry.manifest.id, isDirectory: true)
        }

        init(platform: LibraryPlatform = .macOS) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("pear-backup-test-\(UUID().uuidString)", isDirectory: true)
            restoreRoot = root.appendingPathComponent("Restored", isDirectory: true)
            output = root.appendingPathComponent("portable")
            let directory = root.appendingPathComponent("Source/\(platform.rawValue)/com.example.synthetic", isDirectory: true)
            executable = platform == .wine ? "Prefix/drive_c/Game/game.exe" : "Payload/Game.app/Contents/MacOS/Game"
            let manifest = LibraryManifest(
                id: "com.example.synthetic", platform: platform, displayName: "Synthetic Game", version: "1.2.3",
                payloadPath: platform == .wine ? executable : "Payload/Game.app",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), wineEngineID: platform == .wine ? "synthetic-engine" : nil,
                metalHUDEnabled: true, runtimeRevision: "fixture-runtime", preparedDirectoryPath: directory.path
            )
            entry = LibraryEntry(manifest: manifest, directoryURL: directory)
            files = [
                executable: Data("synthetic executable".utf8),
                "Data/Documents/save.dat": Data("private saved game".utf8),
                "Data/Library/Cloud/values.plist": Data("cloud data".utf8),
                "Keychain/items.plist": Data("synthetic keychain secret".utf8),
                "ODR/pack.assetpack/blob": Data("asset pack".utf8),
                "Keymaps/game.json": Data("{\"key\":\"A\"}".utf8),
                "future/.hidden": Data("unknown future data".utf8),
                "Data/empty-file": Data(),
            ]
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
            for (path, data) in files { try write(path, data) }
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("Data/empty-directory"), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: entry.manifestURL)
            #expect(chmod(directory.path, 0o710) == 0)
            #expect(chmod(directory.appendingPathComponent(executable).path, 0o751) == 0)
        }

        func service(
            limits: LibraryBackupService.Limits = .init(),
            requireStopped: @escaping LibraryBackupService.RunningGuard = { _ in }
        ) -> LibraryBackupService {
            LibraryBackupService(limits: limits, requireStopped: requireStopped)
        }

        func write(_ path: String, _ data: Data) throws {
            let url = entry.directoryURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func link(_ path: String, target: String) throws {
            let url = entry.directoryURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }

        /// Test archives are small enough for Data. Production payload I/O is streamed.
        /// Recomputing the inventory hash ensures validation doesn't merely trust checksums.
        func rewrite(_ archive: URL, _ change: (inout [String: Any]) throws -> Void) throws -> URL {
            let original = try Data(contentsOf: archive)
            let length = Int(integer(original, at: 12, count: 8))
            var json = try #require(JSONSerialization.jsonObject(with: original.subdata(in: 52..<(52 + length))) as? [String: Any])
            try change(&json)
            let inventory = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            var result = original.subdata(in: 0..<12)
            result.append(contentsOf: bigEndian(UInt64(inventory.count), bytes: 8))
            result.append(contentsOf: SHA256.hash(data: inventory))
            result.append(inventory)
            result.append(original.subdata(in: (52 + length)..<original.count))
            let url = root.appendingPathComponent("crafted.pearbackup")
            try result.write(to: url)
            return url
        }

        func expectNoStaging() throws {
            let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let item as URL in enumerator {
                #expect(!item.lastPathComponent.hasPrefix(".pear-backup-"))
                #expect(!item.lastPathComponent.hasPrefix(".pear-restore-"))
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private func expectFailure(_ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("Expected operation to fail")
    } catch { }
}

private func nodeArray(_ json: [String: Any]) throws -> [[String: Any]] {
    try #require(json["nodes"] as? [[String: Any]])
}

private func entryObject(_ json: [String: Any]) throws -> [String: Any] {
    try #require(json["entry"] as? [String: Any])
}

private func fileStatus(_ url: URL) throws -> stat {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
    return status
}

private func permissions(_ url: URL) throws -> mode_t { try fileStatus(url).st_mode & 0o7777 }

private func setAttribute(_ name: String, data: Data, at url: URL) throws {
    let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func attribute(_ name: String, at url: URL) throws -> Data {
    let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: count)
    let actual = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
    guard actual == count else { throw POSIXError(.EIO) }
    return data
}

private func integer(_ data: Data, at offset: Int, count: Int) -> UInt64 {
    data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
}

private func bigEndian(_ value: UInt64, bytes: Int) -> [UInt8] {
    (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
