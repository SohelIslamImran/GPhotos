import Foundation
import Testing

@testable import GPhotosKit

@Suite("Folder media scanning")
struct FolderMediaScannerTests {
  private func makeDirectory() throws -> URL {
    let directory = TestTemporaryDirectory.root
      .appendingPathComponent("FolderMediaScannerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func write(_ name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("media".utf8).write(to: url)
    return url
  }

  private func names(_ scan: MediaScan) -> Set<String> {
    Set(scan.files.map(\.url.lastPathComponent))
  }

  private func paths(_ scan: MediaScan) -> Set<String> {
    Set(scan.files.map(\.url.path))
  }

  @Test func collectsSupportedFilesOnly() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try write("photo.jpg", in: directory)
    _ = try write("clip.MOV", in: directory)
    _ = try write("nested/deeper.heic", in: directory)
    _ = try write("notes.txt", in: directory)
    _ = try write("archive.zip", in: directory)

    let scan = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: false)

    #expect(names(scan) == ["photo.jpg", "clip.MOV", "deeper.heic"])
    #expect(!scan.deferredRecentWrites)
    let photo = try #require(scan.files.first { $0.url.lastPathComponent == "photo.jpg" })
    #expect(photo.size == 5)
  }

  @Test func skipsHiddenFilesAndFolders() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try write("visible.jpg", in: directory)
    _ = try write(".hidden.jpg", in: directory)
    _ = try write(".private/inside.jpg", in: directory)
    _ = try write(".gphotos-delete-token-5-0-tombstone.jpg", in: directory)

    let scan = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: false)

    #expect(names(scan) == ["visible.jpg"])
  }

  @Test("Skipped names leave out a folder with everything in it, at any depth, and paths one folder")
  func skipsExcludedFoldersAndFiles() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try write("Trip/clip.mov", in: directory)
    _ = try write("CapCut/Projects/draft/cover.jpg", in: directory)
    _ = try write("Edits/capcut/frame.png", in: directory)
    _ = try write("Edits/keep.heic", in: directory)
    _ = try write("Edits/render.tmp.jpg", in: directory)
    _ = try write("Exports/final.mp4", in: directory)
    let exclusions = FolderExclusions(["CapCut", "*.tmp.jpg", directory.appending(path: "Exports").path + "/", "  "])

    let scan = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: false, excluding: exclusions)
    #expect(names(scan) == ["clip.mov", "keep.heic"])

    // A pass over only the changed directories skips them too.
    var changes = FolderChanges()
    changes.insertTree(directory.appending(path: "CapCut/Projects").path)
    changes.insertDirectory(directory.appending(path: "Edits").path)
    let partial = FolderMediaScanner.collectMedia(
      in: directory, changes: changes, skipsUnsettledFiles: false, excluding: exclusions)
    #expect(names(partial) == ["keep.heic"])

    #expect(exclusions.excludes(directory.appending(path: "Edits/CAPCUT/a.jpg"), below: directory))
    #expect(!exclusions.excludes(directory.appending(path: "Edits/keep.heic"), below: directory))
    // The watched folder's own name never counts.
    #expect(!FolderExclusions([directory.lastPathComponent]).excludes(directory.appending(path: "a.jpg"), below: directory))
    #expect(FolderExclusions(["~/Movies/CapCut"]).excludes(path: NSHomeDirectory() + "/Movies/CapCut/x.jpg"))
    #expect(FolderExclusions(["", " ", "a/b"]).isEmpty)
  }

  @Test func skipsSymbolicLinks() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try write("original.jpg", in: directory)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("link.jpg"), withDestinationURL: original)

    let scan = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: false)

    #expect(names(scan) == ["original.jpg"])
  }

  /// Everything here was just written, so every file counts as still being written.
  /// A Live Photo's still and video are deferred together, never one without the other.
  @Test func defersUnsettledFilesWithTheirLivePhotoStem() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try write("IMG_0001.HEIC", in: directory)
    _ = try write("IMG_0001.MOV", in: directory)
    _ = try write("other.jpg", in: directory)

    let deferred = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: true)
    #expect(deferred.deferredRecentWrites)
    #expect(deferred.files.isEmpty)

    let imported = FolderMediaScanner.collectMedia(in: directory, skipsUnsettledFiles: false)
    #expect(names(imported) == ["IMG_0001.HEIC", "IMG_0001.MOV", "other.jpg"])
  }

  @Test func protectedFolderMatchesCaseInsensitively() {
    let file = URL(fileURLWithPath: "/Users/me/Pictures/Keep/photo.jpg")
    #expect(FolderMediaScanner.isInsideProtectedFolder(file, ignored: "/users/me/pictures/keep"))
    #expect(FolderMediaScanner.isInsideProtectedFolder(file, ignored: "/Users/me/Pictures/Keep/"))
    #expect(FolderMediaScanner.isInsideProtectedFolder(file, ignored: "/Users/me"))
    #expect(
      FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/Users/me/Pictures/Keep"), ignored: "/USERS/ME/PICTURES/KEEP"))
  }

  @Test func protectedFolderStopsAtPathComponentBoundary() {
    #expect(!FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/a/bc"), ignored: "/a/b"))
    #expect(!FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/a/bc/photo.jpg"), ignored: "/a/b"))
    #expect(FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/a/b/photo.jpg"), ignored: "/a/b"))
    #expect(!FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/a/photo.jpg"), ignored: "/a/b"))
  }

  @Test func protectedFolderMatchesAcrossUnicodeNormalization() {
    let precomposed = "/Users/me/Caf\u{E9}"
    let decomposed = "/Users/me/Cafe\u{301}"
    // Swift compares strings canonically, so check the scalars to prove the forms differ.
    #expect(Array(precomposed.unicodeScalars) != Array(decomposed.unicodeScalars))
    #expect(FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: decomposed + "/photo.jpg"), ignored: precomposed))
    #expect(FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: precomposed + "/photo.jpg"), ignored: decomposed))
    #expect(FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/users/ME/CAFE\u{301}"), ignored: precomposed))
    #expect(!FolderMediaScanner.isInsideProtectedFolder(URL(fileURLWithPath: "/Users/me/Cafe/photo.jpg"), ignored: precomposed))
  }

  /// A still uploaded alone must not stand in for its Live Photo: the pair gets a record
  /// of its own. A pair record of the same version is reused and skipped once sent.
  @Test func livePhotoPairReusesOnlyAPairRecord() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let photo = FolderMediaScanner.metadata(for: try write("IMG_0002.HEIC", in: directory))
    let video = FolderMediaScanner.metadata(for: try write("IMG_0002.MOV", in: directory))
    let account = "me@example.com"
    let photoPath = photo.url.standardizedFileURL.path

    func plan(_ records: [TransferRecord]) -> FolderMediaScanner.QueuePlan {
      FolderMediaScanner.planQueue(
        files: [photo, video], records: records, accountEmail: account, pairLivePhotos: true, createAlbumsFromFolders: false)
    }
    func sent(_ id: String, pairedSourcePath: String?) -> TransferRecord {
      TransferRecord(
        id: id, filename: "IMG_0002.HEIC", mediaType: pairedSourcePath == nil ? "Photo" : "Live Photo", status: .sent,
        sentAccountEmails: [account], sourcePath: photoPath, pairedSourcePath: pairedSourcePath,
        sourceFileSize: photo.size, sourceModifiedAt: photo.modified,
        pairedSourceFileSize: pairedSourcePath == nil ? nil : video.size,
        pairedSourceModifiedAt: pairedSourcePath == nil ? nil : video.modified)
    }

    let single = sent("\(account)|single", pairedSourcePath: nil)
    let afterSingle = plan([single])
    #expect(afterSingle.items.count == 1)
    #expect(afterSingle.items.first?.livePhotoExport != nil)
    let newPair = try #require(afterSingle.newRecords.first)
    #expect(afterSingle.newRecords.count == 1)
    #expect(newPair.id != single.id)
    #expect(newPair.pairedSourcePath == video.url.path)

    let pairRecord = sent("\(account)|pair", pairedSourcePath: video.url.path)
    let afterPair = plan([single, pairRecord])
    #expect(afterPair.items.isEmpty)
    #expect(afterPair.newRecords.isEmpty)

    let changedMotion = LocalMediaFile(
      url: video.url, size: video.size, created: video.created, modified: video.modified.addingTimeInterval(10))
    let afterMotionEdit = FolderMediaScanner.planQueue(
      files: [photo, changedMotion], records: [pairRecord], accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)
    #expect(afterMotionEdit.items.count == 1)
    #expect(afterMotionEdit.items.first?.id != pairRecord.id)
  }

  /// A changed directory is read one level deep, a directory moved in with everything
  /// below it, and each file comes back exactly as a full scan reports it.
  @Test func changedDirectoriesMatchTheFullScan() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try write("top.jpg", in: root)
    _ = try write("a/one.jpg", in: root)
    _ = try write("a/inner/two.jpg", in: root)
    _ = try write("b/three.jpg", in: root)
    _ = try write("b/deep/four.jpg", in: root)
    _ = try write("c/five.jpg", in: root)

    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)
    var changes = FolderChanges()
    changes.insertDirectory(root.appendingPathComponent("a").path)
    changes.insertTree(root.appendingPathComponent("b").path)
    changes.insertDirectory(root.appendingPathComponent("b/deep").path)
    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)

    #expect(names(partial) == ["one.jpg", "three.jpg", "four.jpg"])
    #expect(partial.files.count == 3)
    #expect(paths(partial).isSubset(of: paths(full)))
    let fullByPath = Dictionary(uniqueKeysWithValues: full.files.map { ($0.url.path, $0) })
    for file in partial.files {
      #expect(fullByPath[file.url.path] == file)
    }
  }

  /// FSEvents reports `/private/var/...` for a folder chosen as `/var/...`; the files
  /// keep the folder's own spelling, which is what the manifest holds.
  @Test func changedDirectoriesAcceptTheCanonicalSpelling() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try write("a/one.jpg", in: root)
    // `resolvingSymlinksInPath` drops `/private`, so the event spelling is built directly.
    let canonical = WatchedFolderPaths.privatePrefixed(root.appendingPathComponent("a").path)
    var changes = FolderChanges()
    changes.insertDirectory(canonical)

    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)
    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)

    #expect(names(partial) == ["one.jpg"])
    #expect(paths(partial) == paths(full))
  }

  /// Directories a full scan never enters stay unread, and so do paths elsewhere.
  @Test func changedDirectoriesSkipWhatAFullScanSkips() throws {
    let root = try makeDirectory()
    let other = try makeDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: other)
    }
    _ = try write(".hidden/one.jpg", in: root)
    _ = try write("Library.photoslibrary/two.jpg", in: root)
    _ = try write("elsewhere.jpg", in: other)
    let real = try write("real/three.jpg", in: other)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: real.deletingLastPathComponent())

    var changes = FolderChanges()
    for name in [".hidden", "Library.photoslibrary", "link", "missing"] {
      changes.insertDirectory(root.appendingPathComponent(name).path)
      changes.insertTree(root.appendingPathComponent(name).path)
    }
    changes.insertDirectory(other.path)
    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)

    #expect(names(partial).isDisjoint(with: ["one.jpg", "three.jpg", "elsewhere.jpg"]))
    // Whether a folder counts as a package depends on the platform's type registry.
    #expect(names(partial) == names(full))
  }

  /// The folder itself moved in whole, a full request, or too many directories to track
  /// all read everything.
  @Test func wideChangesReadTheWholeFolder() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try write("top.jpg", in: root)
    _ = try write("a/one.jpg", in: root)
    let everything: Set<String> = ["top.jpg", "one.jpg"]

    var rootTree = FolderChanges()
    rootTree.insertTree(root.path)
    #expect(names(FolderMediaScanner.collectMedia(in: root, changes: rootTree, skipsUnsettledFiles: false)) == everything)
    #expect(names(FolderMediaScanner.collectMedia(in: root, changes: .full, skipsUnsettledFiles: false)) == everything)

    var many = FolderChanges()
    for index in 0...FolderChanges.maxDirectories {
      many.insertDirectory(root.appendingPathComponent("d\(index)").path)
    }
    #expect(many.isFull)
    #expect(names(FolderMediaScanner.collectMedia(in: root, changes: many, skipsUnsettledFiles: false)) == everything)
  }

  @Test func folderChangesMerge() {
    var changes = FolderChanges()
    #expect(changes.isEmpty)
    changes.insertDirectory("/a")
    var other = FolderChanges()
    other.insertTree("/b")
    changes.formUnion(other)
    #expect(changes.directories == ["/a"])
    #expect(changes.trees == ["/b"])
    changes.formUnion(.full)
    #expect(changes.isFull)
    #expect(changes.directories.isEmpty)
    changes.insertDirectory("/c")
    #expect(changes.directories.isEmpty)
    #expect(!changes.isEmpty)
  }

  /// A file still being written leaves its directory to be read again.
  @Test func unsettledFilesNameTheirDirectory() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try write("a/IMG_0003.HEIC", in: root)

    let scan = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true)

    #expect(scan.files.isEmpty)
    #expect(scan.unsettledDirectories == [file.deletingLastPathComponent().standardizedFileURL.path])
  }

  /// An incremental pass scoped to changed directories and pending/failed records
  /// queues the exact same upload items as a full rescan over the whole folder.
  @Test func incrementalAndFullPassQueueEquivalence() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // Pre-existing structure
    let topSent = FolderMediaScanner.metadata(for: try write("top_sent.jpg", in: root))
    let sub1Sent = FolderMediaScanner.metadata(for: try write("sub1/sub1_sent.jpg", in: root))
    let sub2Pending = FolderMediaScanner.metadata(for: try write("sub2/sub2_pending.jpg", in: root))
    let sub2Failed = FolderMediaScanner.metadata(for: try write("sub2/sub2_failed.jpg", in: root))
    let livePhoto = FolderMediaScanner.metadata(for: try write("live/IMG_0010.HEIC", in: root))
    let liveMovie = FolderMediaScanner.metadata(for: try write("live/IMG_0010.MOV", in: root))

    let account = "sync_user@example.com"

    let topSentRecord = TransferRecord(
      id: "\(account)|topSent", filename: "top_sent.jpg", mediaType: "Photo", status: .sent,
      sentAccountEmails: [account], sourcePath: topSent.url.standardizedFileURL.path,
      sourceFileSize: topSent.size, sourceModifiedAt: topSent.modified)
    let sub1SentRecord = TransferRecord(
      id: "\(account)|sub1Sent", filename: "sub1_sent.jpg", mediaType: "Photo", status: .sent,
      sentAccountEmails: [account], sourcePath: sub1Sent.url.standardizedFileURL.path,
      sourceFileSize: sub1Sent.size, sourceModifiedAt: sub1Sent.modified)
    let sub2PendingRecord = TransferRecord(
      id: "\(account)|sub2Pending", filename: "sub2_pending.jpg", mediaType: "Photo", status: .pending,
      sentAccountEmails: [], sourcePath: sub2Pending.url.standardizedFileURL.path,
      sourceFileSize: sub2Pending.size, sourceModifiedAt: sub2Pending.modified)
    let sub2FailedRecord = TransferRecord(
      id: "\(account)|sub2Failed", filename: "sub2_failed.jpg", mediaType: "Photo", status: .failed,
      sentAccountEmails: [], sourcePath: sub2Failed.url.standardizedFileURL.path,
      sourceFileSize: sub2Failed.size, sourceModifiedAt: sub2Failed.modified)
    let liveSentRecord = TransferRecord(
      id: "\(account)|liveSent", filename: "IMG_0010.HEIC", mediaType: "Live Photo", status: .sent,
      sentAccountEmails: [account], sourcePath: livePhoto.url.standardizedFileURL.path,
      pairedSourcePath: liveMovie.url.standardizedFileURL.path,
      sourceFileSize: livePhoto.size, sourceModifiedAt: livePhoto.modified,
      pairedSourceFileSize: liveMovie.size, pairedSourceModifiedAt: liveMovie.modified)

    let records = [topSentRecord, sub1SentRecord, sub2PendingRecord, sub2FailedRecord, liveSentRecord]

    // Mutate the folder:
    // 1. New file in sub1 (sub1 changed)
    _ = try write("sub1/sub1_new.jpg", in: root)
    // 2. New subfolder sub3 with another file (sub3 changed)
    _ = try write("sub3/sub3_new.jpg", in: root)
    // 3. New Live Photo pair in live2 (live2 changed)
    _ = try write("live2/IMG_0020.HEIC", in: root)
    _ = try write("live2/IMG_0020.MOV", in: root)

    // Build changes according to the incremental scope invariant:
    // - Changed directories: sub1, sub3, live2
    // - Pending and failed record directories: sub2
    var changes = FolderChanges()
    changes.insertDirectory(root.appendingPathComponent("sub1").path)
    changes.insertDirectory(root.appendingPathComponent("sub3").path)
    changes.insertTree(root.appendingPathComponent("live2").path)
    changes.insertDirectory(root.appendingPathComponent("sub2").path)

    let incrementalScan = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let fullScan = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)

    let incrementalPlan = FolderMediaScanner.planQueue(
      files: incrementalScan.files, records: records, accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)
    let fullPlan = FolderMediaScanner.planQueue(
      files: fullScan.files, records: records, accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)

    // Verify invariant: incremental queues exactly what a full rescan queues
    #expect(!incrementalPlan.items.isEmpty)
    #expect(incrementalPlan.items.map(\.id).sorted() == fullPlan.items.map(\.id).sorted())
    #expect(incrementalPlan.newRecords.map(\.id).sorted() == fullPlan.newRecords.map(\.id).sorted())
    #expect(
      Set(incrementalPlan.items.map(\.filename)) == [
        "sub2_pending.jpg", "sub2_failed.jpg", "sub1_new.jpg", "sub3_new.jpg", "IMG_0020.HEIC",
      ])
  }

  /// Live Photo stems in a changed directory: still changed, movie changed, both changed,
  /// and recently written files deferral.
  @Test func livePhotoStemVariationsInChangedDirectory() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let photoURL = try write("live/IMG_0050.HEIC", in: root)
    let movieURL = try write("live/IMG_0050.MOV", in: root)

    let photo = FolderMediaScanner.metadata(for: photoURL)
    let movie = FolderMediaScanner.metadata(for: movieURL)
    let account = "user@example.com"
    let photoPath = photo.url.standardizedFileURL.path

    let existingSentRecord = TransferRecord(
      id: "\(account)|live50", filename: "IMG_0050.HEIC", mediaType: "Live Photo", status: .sent,
      sentAccountEmails: [account], sourcePath: photoPath, pairedSourcePath: movie.url.standardizedFileURL.path,
      sourceFileSize: photo.size, sourceModifiedAt: photo.modified,
      pairedSourceFileSize: movie.size, pairedSourceModifiedAt: movie.modified)

    var changes = FolderChanges()
    changes.insertDirectory(root.appendingPathComponent("live").path)

    // 1. Both matching sent record -> nothing queued
    let scan1 = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let plan1 = FolderMediaScanner.planQueue(
      files: scan1.files, records: [existingSentRecord], accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)
    #expect(plan1.items.isEmpty)

    // 2. Still changed (new mtime) -> new pair version queued
    let modifiedDate = photo.modified.addingTimeInterval(10)
    try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: photoURL.path)
    let scan2 = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let plan2 = FolderMediaScanner.planQueue(
      files: scan2.files, records: [existingSentRecord], accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)
    #expect(plan2.items.count == 1)
    #expect(plan2.items.first?.livePhotoExport != nil)
    #expect(plan2.newRecords.count == 1)

    // 3. Movie changed (new mtime) -> new pair version queued
    let movieModifiedDate = movie.modified.addingTimeInterval(10)
    try FileManager.default.setAttributes([.modificationDate: movieModifiedDate], ofItemAtPath: movieURL.path)
    let scan3 = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let plan3 = FolderMediaScanner.planQueue(
      files: scan3.files, records: [existingSentRecord], accountEmail: account,
      pairLivePhotos: true, createAlbumsFromFolders: false)
    #expect(plan3.items.count == 1)
    #expect(plan3.items.first?.livePhotoExport != nil)

    // 4. Recently written files are deferred together with their stem, and directory marked unsettled
    let scanDeferred = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: true)
    #expect(scanDeferred.files.isEmpty)
    #expect(scanDeferred.deferredRecentWrites)
    #expect(scanDeferred.unsettledDirectories.contains(root.appendingPathComponent("live").standardizedFileURL.path))
  }

  /// Files located directly in the root watched folder (without any subdirectories)
  /// are read when `changes.insertDirectory(root.path)` is supplied, without recursing
  /// into subdirectories.
  @Test func filesDirectlyInRootDirectory() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try write("root1.jpg", in: root)
    _ = try write("root2.png", in: root)
    _ = try write("nested/child.jpg", in: root)

    var changes = FolderChanges()
    changes.insertDirectory(root.path)

    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    #expect(names(partial) == ["root1.jpg", "root2.png"])
    #expect(!names(partial).contains("child.jpg"))
  }

  /// Trees nested inside other trees collapse into the outer tree; directories
  /// inside trees are skipped; duplicates are deduplicated.
  @Test func nestedTreesAndDirectoriesDeduplication() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try write("a/one.jpg", in: root)
    _ = try write("a/b/two.jpg", in: root)
    _ = try write("a/b/c/three.jpg", in: root)
    _ = try write("d/four.jpg", in: root)

    var changes = FolderChanges()
    changes.insertTree(root.appendingPathComponent("a").path)
    changes.insertTree(root.appendingPathComponent("a/b").path)
    changes.insertDirectory(root.appendingPathComponent("a/b/c").path)
    changes.insertDirectory(root.appendingPathComponent("a").path)
    changes.insertDirectory(root.appendingPathComponent("d").path)

    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    #expect(names(partial) == ["one.jpg", "two.jpg", "three.jpg", "four.jpg"])
    #expect(partial.files.count == 4)
  }

  /// Changes matching across trailing slashes, APFS case variations, and Unicode
  /// precomposed vs decomposed spellings return the exact canonical file paths.
  @Test func pathSpellingMismatchesAndUnicode() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try write("sub/one.jpg", in: root)
    let nfcName = "Caf\u{E9}"
    _ = try write("\(nfcName)/two.jpg", in: root)

    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)

    // 1. Trailing slash on path
    var trailingChanges = FolderChanges()
    trailingChanges.insertDirectory(root.appendingPathComponent("sub").path + "/")
    let trailingScan = FolderMediaScanner.collectMedia(in: root, changes: trailingChanges, skipsUnsettledFiles: false)
    #expect(names(trailingScan) == ["one.jpg"])
    #expect(paths(trailingScan) == paths(full).filter { $0.contains("one.jpg") })

    // 2. Case difference on directory. Only the Mac reads changed directories (FSEvents
    // has no iOS counterpart), and its default volume ignores case.
    #if os(macOS)
      let isCaseSensitive =
        try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        == true
      if !isCaseSensitive {
        var caseChanges = FolderChanges()
        caseChanges.insertDirectory(root.appendingPathComponent("SUB").path)
        let caseScan = FolderMediaScanner.collectMedia(in: root, changes: caseChanges, skipsUnsettledFiles: false)
        #expect(names(caseScan) == ["one.jpg"])
        #expect(paths(caseScan) == paths(full).filter { $0.contains("one.jpg") })
      }
    #endif

    // 3. Decomposed Unicode (NFD) change for precomposed (NFC) folder
    let nfdName = "Cafe\u{301}"
    var nfdChanges = FolderChanges()
    nfdChanges.insertDirectory(root.appendingPathComponent(nfdName).path)
    let nfdScan = FolderMediaScanner.collectMedia(in: root, changes: nfdChanges, skipsUnsettledFiles: false)
    #expect(names(nfdScan) == ["two.jpg"])
    #expect(paths(nfdScan) == paths(full).filter { $0.contains("two.jpg") })
  }

  /// Nonexistent paths, regular files passed as directories, symlinks, hidden folders,
  /// packages, and paths outside root are skipped cleanly without crashing.
  @Test func skipsNonScannableDirectoriesGracefully() throws {
    let root = try makeDirectory()
    let outside = try makeDirectory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }

    let filePath = try write("regular_file.jpg", in: root)
    _ = try write(".hidden/hidden.jpg", in: root)
    _ = try write("Pkg.bundle/bundled.jpg", in: root)
    _ = try write("valid/good.jpg", in: root)
    _ = try write("outside.jpg", in: outside)

    let symlinkTarget = root.appendingPathComponent("valid")
    let symlinkDir = root.appendingPathComponent("symlink_dir")
    try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: symlinkTarget)

    var changes = FolderChanges()
    changes.insertDirectory(root.appendingPathComponent("nonexistent_dir").path)
    changes.insertDirectory(filePath.path)
    changes.insertDirectory(root.appendingPathComponent(".hidden").path)
    changes.insertDirectory(root.appendingPathComponent("Pkg.bundle").path)
    changes.insertDirectory(symlinkDir.path)
    changes.insertDirectory(outside.path)
    changes.insertDirectory(root.appendingPathComponent("valid").path)

    let scan = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)
    #expect(names(scan).contains("good.jpg"))
    #expect(names(scan).isDisjoint(with: ["regular_file.jpg", "hidden.jpg", "outside.jpg"]))
    // Whether a folder counts as a package depends on the platform's type registry.
    #expect(names(scan).contains("bundled.jpg") == names(full).contains("bundled.jpg"))
    #expect(scan.files.count == Set(scan.files.map(\.url.path)).count)
  }

  /// Boundary test for `FolderChanges.maxDirectories`: 256 is tracked incrementally,
  /// 257 collapses to a full scan, and merging follows the same boundary.
  @Test func folderChangesMergeAndCollapseLimits() {
    var changes = FolderChanges()
    #expect(!changes.isFull)

    for i in 1...FolderChanges.maxDirectories {
      changes.insertDirectory("/dir/\(i)")
      #expect(!changes.isFull)
      #expect(changes.directories.count == i)
    }

    changes.insertDirectory("/dir/overflow")
    #expect(changes.isFull)
    #expect(changes.directories.isEmpty)
    #expect(changes.trees.isEmpty)

    // Operations after becoming full are no-ops
    changes.insertDirectory("/dir/another")
    changes.insertTree("/tree/another")
    #expect(changes.isFull)
    #expect(changes.directories.isEmpty)

    // Form union boundary
    var a = FolderChanges()
    var b = FolderChanges()
    for i in 1...130 { a.insertDirectory("/a/\(i)") }
    for i in 1...127 { b.insertDirectory("/b/\(i)") }
    #expect(!a.isFull && !b.isFull)
    a.formUnion(b)
    #expect(a.isFull)
  }

  /// `TransferManifestStore.removalCount` increments on any record removal, but never
  /// when nothing was removed, so incremental scanning knows when to fall back to full.
  @Test func transferManifestStoreRemovalCountTracking() async throws {
    let tempDir = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    let store = TransferManifestStore(fileURL: manifestURL)

    #expect(await store.removalCount == 0)

    // Remove non-existent record: does NOT bump removalCount
    _ = await store.remove(id: "nonexistent")
    #expect(await store.removalCount == 0)

    let record1 = TransferRecord(id: "user1@test.com|rec1", filename: "1.jpg", mediaType: "Photo", status: .pending)
    let record2 = TransferRecord(id: "user1@test.com|rec2", filename: "2.jpg", mediaType: "Photo", status: .sent)
    let record3 = TransferRecord(id: "user2@test.com|rec3", filename: "3.jpg", mediaType: "Photo", status: .pending)
    _ = await store.upsertBatch([record1, record2, record3])

    // Remove single existing record: bumps removalCount by 1
    _ = await store.remove(id: record1.id)
    #expect(await store.removalCount == 1)

    // Remove non-existent again: no bump
    _ = await store.remove(id: record1.id)
    #expect(await store.removalCount == 1)

    // Remove records for account with 0 records: no bump
    _ = await store.removeRecords(forAccountEmail: "unknown@test.com")
    #expect(await store.removalCount == 1)

    // Remove records for account with records: bumps by 1
    _ = await store.removeRecords(forAccountEmail: "user1@test.com")
    #expect(await store.removalCount == 2)

    // clearAll when records exist: bumps by 1
    _ = await store.clearAll()
    #expect(await store.removalCount == 3)

    // clearAll when already empty: no bump
    _ = await store.clearAll()
    #expect(await store.removalCount == 3)
  }

  /// Multiple directories containing unsettled files all report their directories in
  /// `scan.unsettledDirectories`, while a full pass without skipping collects all files.
  @Test func unsettledDirectoriesMultiFolderBookkeeping() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let file1 = try write("unsettled1/img1.jpg", in: root)
    let file2 = try write("unsettled2/img2.jpg", in: root)
    let file3 = try write("unsettled3/sub/img3.jpg", in: root)

    let scan = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: true)
    #expect(scan.deferredRecentWrites)
    #expect(scan.files.isEmpty)
    #expect(
      scan.unsettledDirectories == [
        file1.deletingLastPathComponent().standardizedFileURL.path,
        file2.deletingLastPathComponent().standardizedFileURL.path,
        file3.deletingLastPathComponent().standardizedFileURL.path,
      ])

    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)
    #expect(names(full) == ["img1.jpg", "img2.jpg", "img3.jpg"])
    #expect(full.unsettledDirectories.isEmpty)
    #expect(!full.deferredRecentWrites)
  }

  /// Randomized / deeply nested folder trees scanned incrementally produce an exact
  /// subset matching the full scan for the targeted directories.
  @Test func randomizedDeeplyNestedFolderEquivalence() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try write("d1/d2/d3/deep1.jpg", in: root)
    _ = try write("d1/d2/d3/deep2.mov", in: root)
    _ = try write("d1/d2/other.heic", in: root)
    _ = try write("d1/branch2/file.jpg", in: root)
    _ = try write("d4/root_file.jpg", in: root)

    let full = FolderMediaScanner.collectMedia(in: root, skipsUnsettledFiles: false)

    var changes = FolderChanges()
    changes.insertTree(root.appendingPathComponent("d1/d2/d3").path)
    changes.insertDirectory(root.appendingPathComponent("d4").path)

    let partial = FolderMediaScanner.collectMedia(in: root, changes: changes, skipsUnsettledFiles: false)
    #expect(names(partial) == ["deep1.jpg", "deep2.mov", "root_file.jpg"])
    #expect(paths(partial).isSubset(of: paths(full)))

    let fullByPath = Dictionary(uniqueKeysWithValues: full.files.map { ($0.url.path, $0) })
    for file in partial.files {
      #expect(fullByPath[file.url.path] == file)
    }
  }

  /// A secondary account's copy carries the primary record's source fields. Matching it
  /// would queue the copy's record under the primary's upload; the primary's own sent
  /// record must decide.
  @Test func planQueueMatchesOnlyThisAccountsRecords() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = FolderMediaScanner.metadata(for: try write("photo.jpg", in: directory))
    let path = file.url.standardizedFileURL.path
    func record(_ email: String, status: TransferStatus) -> TransferRecord {
      TransferRecord(
        id: TransferRecord.accountScopedID("\(path)|v", accountEmail: email), filename: "photo.jpg",
        mediaType: "Photo", status: status, sentAccountEmails: status == .sent ? [email] : [],
        sourcePath: path, sourceFileSize: file.size,
        sourceModifiedAt: file.modified)
    }
    let primarySent = record("primary@example.com", status: .sent)
    let secondaryPending = record("second@example.com", status: .pending)

    for order in [[primarySent, secondaryPending], [secondaryPending, primarySent]] {
      let primary = FolderMediaScanner.planQueue(
        files: [file], records: order, accountEmail: "primary@example.com", pairLivePhotos: false,
        createAlbumsFromFolders: false)
      #expect(primary.items.isEmpty)
      #expect(primary.newRecords.isEmpty)
    }
    let secondary = FolderMediaScanner.planQueue(
      files: [file], records: [primarySent, secondaryPending], accountEmail: "second@example.com",
      pairLivePhotos: false, createAlbumsFromFolders: false)
    #expect(secondary.items.map(\.id) == [secondaryPending.id])
  }
}
