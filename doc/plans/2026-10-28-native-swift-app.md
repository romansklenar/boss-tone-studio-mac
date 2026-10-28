# Native Swift App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python shell with a dependency-free Swift app that runs Roland's unchanged MkII web app with the
same behaviour, data and protocol, and fixes ADR-0003's known weak points.

**Architecture:** A SwiftPM package at the repo root. Library `BossToneStudioCore` holds everything testable without a
window or a MIDI client: HTTP parsing, serving and routing with the security rules, the bridge command table, storage,
file permissions, proxy, MIDI message and UMP conversion, Librarian import and the data-folder lock. Executable
`BossToneStudio` adds AppKit, WebKit, file dialogs, the CoreMIDI backend and the command line. `make app` assembles and
ad-hoc signs the bundle with the hardened runtime.

**Tech Stack:** Swift 6 (language mode 6, `swift-tools-version: 6.0`), Foundation, Network, AppKit, WebKit, CoreMIDI,
UniformTypeIdentifiers, ImageIO, Security; Swift Testing; `swift format`; Make; GitHub Actions.

**Spec:** [`doc/design/2026-10-28-native-swift-app.md`](../design/2026-10-28-native-swift-app.md). The protocol and
security rules it builds on are in [`doc/bridge-protocol.md`](../bridge-protocol.md), and the Python code in `bts/` is
the reference behaviour wherever this plan says "as in Python".

## Global Constraints

- macOS 14+ (`platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` 14.0), arm64 only, no package dependencies.
- Build and test with Command Line Tools only. Their Swift 6.4 build system intermittently leaves the Swift Testing
  macro plugin (`host/plugins/testing/libTestingMacros.dylib`) out of the compiler call after a clean build
  (swiftlang/swift-build#1870, fixed upstream in da7d609 but not in this CLT release). Until a CLT update ships it,
  the Makefile adds `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`
  only when `xcode-select -p` is the CLT, with a comment naming the issue. Keep `swift-tools-version: 6.0`, the default
  build system (`--build-system native` cannot find `Testing` at all on CLT), and `-Xswiftc -warnings-as-errors` on
  every build and test.
- `swift`, `make test`, `make app` and anything touching CoreMIDI run outside Claude Code's sandbox
  (`dangerouslyDisableSandbox`); tests never create a CoreMIDI client.
- App name `BOSS TONE STUDIO for KATANA MkII (Apple Silicon)`, bundle identifier `local.boss-tone-studio-mac.katana-mk2`,
  data folder `~/Library/Application Support/<app name>`, overridable by `BTS_DATA_DIR`.
- On-disk formats identical to 0.1.1: `storage.json`, `storage2/<quoted key>`, `roland-librarian-imported`, `app.lock`.
- Log prefixes and shapes identical to 0.1.1: `[bts] …`, `[trace] -> $$cmd ['a', 'b']`, `[trace] <- midi.message […]`,
  `[js] '…'`, so `doc/testing.md`'s trace checklist applies unchanged.
- Repo rules (AGENTS.md): English, Conventional Commits with a capital letter and the `Co-authored-by` trailer, never
  amend, 120-character lines, lean comments that say why, nothing of Roland's committed.
- Python (`bts/`, `tests/`, `.venv`) stays in the tree and runnable (`.venv/bin/python -m bts`) until Task 15.

## Review Focus

1. **Large SysEx split across CoreMIDI callbacks** (bulk replies, a backup restore): the page must get each SysEx
   whole, once. Pinned in Task 4 (`sysExSplitAcrossFeedsIsReassembledOnce`).
2. **A slow request on one connection** (a 20 s proxy fetch, a pending command) must not stall the 50 ms event poll on
   another. Pinned in Task 10 (`aSlowRequestDoesNotBlockOtherConnections`).
3. **Paths with spaces and non-ASCII, and `/var` → `/private/var`** (e.g. `~/Downloads/Foo Fighters_export.tsl`, the
   temp folder): reading and writing must work, permissions must hold. Pinned in Task 6 (`pathsWithSpacesAndUnicode…`,
   `tempFolderIsReachableUnderItsSymlinkedName`).
4. **Existing 0.1.1 data and non-ASCII liveset names** must read back byte for byte. Pinned in Task 2
   (`keysAreQuotedLikePython`, `unicodeValuesRoundTrip`).
5. **Requests arriving in pieces, or two in one segment** (keep-alive): no hang, no mix-up. Pinned in Task 9
   (`partialRequestsWaitForTheRest`, `pipelinedRequestsAreParsedOneByOne`).

---

## File Structure

```
Package.swift, .swift-format, VERSION
Sources/BossToneStudioCore/
  Log.swift            log/trace/escaping helpers
  Storage.swift        atomic writes, storage.json, Storage2 (key quoting)
  DataDirLock.swift    flock on app.lock
  RolandImport.swift   Librarian import from Roland's plist
  MidiMessages.swift   hex, message splitting, endpoint JSON, port-name filter
  UMP.swift            MIDI 1.0 bytes <-> Universal MIDI Packets, SysEx reassembly
  MidiController.swift $native.midi semantics over a MidiBackend protocol
  FileAccess.swift     read/write permission sets
  Proxy.swift          allowlist, URL rebuild, fetch, JSON gate
  Bridge.swift         command table, events, close handshake, BridgeHost protocol
  PageScript.swift     token/nonce, injected script, CSP, index injection
  HTTPMessage.swift    HTTPRequest, parser, HTTPResponse
  Router.swift         every security rule, request → response
  HTTPServer.swift     NWListener on 127.0.0.1, connection loop
  AppPaths.swift       app name, data/html folder lookup
Sources/BossToneStudio/
  main.swift           command line, start-up
  AppDelegate.swift    menus, termination handshake
  WebWindow.swift      NSWindow, WKWebView, UI/navigation delegates, file dialogs (BridgeHost)
  CoreMIDIBackend.swift
Tests/BossToneStudioCoreTests/  one file per Core file, plus RawHTTPClient.swift (test helper)
packaging/make-icon.swift, packaging/Info.plist
```

---

### Task 1: Package scaffold, Makefile and CI for Swift

**Files:**
- Create: `Package.swift`, `.swift-format`, `VERSION`, `Sources/BossToneStudioCore/Log.swift`,
  `Sources/BossToneStudio/main.swift` (prints usage only for now), `Tests/BossToneStudioCoreTests/LogTests.swift`
- Modify: `Makefile`, `.gitignore`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: `public func log(_ message: String)` → stdout `[bts] <message>`;
  `public func trace(_ arrow: String, _ label: String, _ args: [String])` → `[trace] <arrow> <label> <pyList(args)>`
  only when `BTS_TRACE == "1"`, each arg cut to 120 characters;
  `public func pyList(_ items: [String]) -> String` (Python's list repr: `['a', 'b']`, `[]`);
  `public func escaped(_ text: String) -> String` (Python-repr-like: `\\`, `\'`, `\n`, `\r`, `\t`, other controls as
  `\xNN`, wrapped in single quotes). All output flushes per line (`setvbuf(stdout, nil, _IOLBF, 0)` in `main`).

- [ ] **Step 1: Write `Package.swift`**: tools version 6.0, `platforms: [.macOS(.v14)]`, targets `BossToneStudioCore`,
  executable `BossToneStudio` (depends on Core), test target `BossToneStudioCoreTests`; `swiftLanguageModes: [.v6]`.
- [ ] **Step 2: Write `.swift-format`** (`lineLength` 120, 4-space indentation, `respectsExistingLineBreaks` true) and
  `VERSION` containing `0.2.0`. Add `.build/` to `.gitignore`.
- [ ] **Step 3: Write the failing test** `LogTests.swift`:

```swift
@Test func pyListMatchesPythonRepr() {
    #expect(pyList([]) == "[]")
    #expect(pyList(["F07E", "1730"]) == "['F07E', '1730']")
}
@Test func escapedKeepsLogLinesSingle() {
    #expect(escaped("a\nb'c") == "'a\\nb\\'c'")
    #expect(escaped("\u{1b}[2J") == "'\\x1b[2J'")
}
```

- [ ] **Step 4: Rewrite the Makefile's `test`, `lint`, `format`, `check` for Swift** and add `build`:
  - `SWIFT_FLAGS := -Xswiftc -warnings-as-errors`, plus the testing plugin path when `xcode-select -p` is
    `/Library/Developer/CommandLineTools`.
  - `lint`: `swift format lint --strict --recursive --parallel Package.swift Sources Tests packaging/make-icon.swift`
    (skip missing paths until they exist); `format`: `swift format format --in-place` on the same set.
  - Keep `run`, `browser`, `trace`, `roland-import`, `app`, `install`, `deps`, `lock` as Python for now, and
    `release-notes` as it is; drop `ruff` from `lint`. `help` lists every target.
- [ ] **Step 5: Run** `make test` (sandbox off). Expected: FAIL (`pyList` undefined). **Implement** `Log.swift`.
  **Run** `make check`. Expected: lint clean, 2 tests pass.
- [ ] **Step 6: Rewrite CI** (`.github/workflows/ci.yml`), actions pinned to commit SHAs as now:
  - triggers `pull_request: types: [opened, synchronize, reopened, ready_for_review]` and `push: branches: [main]`;
    `concurrency` with `cancel-in-progress` stays.
  - job `lint` on `ubuntu-latest`, `container: swift:<x.y>@sha256:<digest>` where `<x.y>` is the local
    `swift --version` (6.4 now); runs `make lint`. Find the digest with
    `docker buildx imagetools inspect swift:<x.y>` or Docker Hub's API. If no image for the local version exists, use
    the newest one and run `make format` with it once to confirm it changes nothing; note the gap in the commit.
  - job `test` on `macos-26`, `if: github.event_name == 'push' || !github.event.pull_request.draft`, runs `make test`.
  - Remove mise, uv and the cache step.
- [ ] **Step 7: Commit** `Chore(swift): Add the Swift package, its Makefile targets and CI`.

### Task 2: Storage and the data-folder lock

**Files:**
- Create: `Sources/BossToneStudioCore/Storage.swift`, `Sources/BossToneStudioCore/DataDirLock.swift`,
  `Tests/BossToneStudioCoreTests/StorageTests.swift`, `Tests/BossToneStudioCoreTests/DataDirLockTests.swift`

**Interfaces:**
- Produces:
  - `public func writeAtomically(_ text: String, to url: URL) throws` (`Data.write(options: .atomic)`)
  - `public func readText(_ url: URL) -> String?` (nil when not a regular file; UTF-8)
  - `public struct Storage2 { public init(dataDir: URL) throws; public func read(_ key: String) throws -> String?;
    public func write(_ key: String, _ value: String) throws; public static func fileName(for key: String) throws -> String }`
    (folder `storage2`, created on init; empty value deletes, missing file is fine; key quoted as Python's
    `quote(key, safe="")`: ASCII letters, digits, `-._~` kept, every other UTF-8 byte `%XX` uppercase;
    `""`, `"."`, `".."` throw `StorageError.invalidKey`)
  - `public final class DataDirLock { public static func acquire(_ lockFile: URL) -> DataDirLock? }` (creates parent
    folders, `open(O_CREAT|O_WRONLY)` + `flock(LOCK_EX|LOCK_NB)`; the descriptor closes on deinit)

- [ ] **Step 1: Write the failing tests** (temp folders per test):

```swift
@Test func keysAreQuotedLikePython() throws {
    #expect(try Storage2.fileName(for: "ID_LIST") == "ID_LIST")
    #expect(try Storage2.fileName(for: "0") == "0")
    #expect(try Storage2.fileName(for: "a b/ž") == "a%20b%2F%C5%BE")
    #expect(throws: StorageError.self) { try Storage2.fileName(for: "..") }   // also "" and "."
}
@Test func storage2ReadsWritesAndDeletes() throws { /* write "3"→"x", read == "x", write "3"→"" , read == nil */ }
@Test func unicodeValuesRoundTrip() throws { /* value "Lead ž 日本 \"q\"" reads back equal */ }
@Test func atomicWriteReplacesWholeFile() throws { /* long then short text: file equals the short text */ }
@Test func theFolderIsLockedUntilItsHolderCloses() {
    var first = DataDirLock.acquire(lockFile); #expect(first != nil)
    #expect(DataDirLock.acquire(lockFile) == nil)
    first = nil
    #expect(DataDirLock.acquire(lockFile) != nil)
}
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL (undefined symbols).
- [ ] **Step 3: Implement** `Storage.swift` and `DataDirLock.swift` with the interfaces above.
- [ ] **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Port storage and the data-folder lock`.

### Task 3: Librarian import from Roland's app

**Files:**
- Create: `Sources/BossToneStudioCore/RolandImport.swift`, `Tests/BossToneStudioCoreTests/RolandImportTests.swift`

**Interfaces:**
- Consumes: `Storage2`, `writeAtomically`, `log`.
- Produces: `public enum RolandImport { public static let prefs: URL` (`~/Library/Preferences/jp.co.roland.BOSS-TONE-STUDIO-for-KATANA-MkII.plist`)
  `public static let marker = "roland-librarian-imported"; public static let maxLivesets = 50;
  @discardableResult public static func importLibrarian(dataDir: URL, prefs: URL = RolandImport.prefs) throws -> String;
  public static func importOnce(dataDir: URL, prefs: URL = RolandImport.prefs) }`

Behaviour as `bts/roland_import.py`: read the plist with `PropertyListSerialization` (read only); Roland's `ID_LIST` is
a JSON string `{"list":[…]}` of integers; liveset values are strings under `String(id)`; skip empty values and values
already present; move a colliding ID to the lowest free one in 0..<50; skip when none is free; write `ID_LIST` as
compact JSON `{"list":[imported…, existing…]}` only when something was imported; copy `CONFIRM_FLAG` (a string) only if
absent. Summary `Imported N livesets from <path>`, plus `; K skipped, the Librarian holds at most 50`; logged with
`log`. `importOnce` does nothing if the marker exists or the plist is missing; otherwise imports and writes the summary
plus `\n` to the marker, or `Import failed (<error>); retry with \`make roland-import\`` on any error.

- [ ] **Step 1: Write the failing tests**, porting all eight in `tests/test_roland_import.py` with plist fixtures
  written by `PropertyListSerialization` into a temp folder: `freshLibraryMatchesRolandOrderAndValues`,
  `reimportAddsNothing`, `collidingIdMovesToAFreeOneAndKeepsLocalLivesets`, `stopsAtTheLibrarianLimit`,
  `importOnceRunsASingleTime`, `duplicatesInRolandsListAreImportedOnce`, `importOnceSurvivesAnUnreadablePlist`,
  `importOnceWaitsForRolandSettings`, with the Python tests' exact fixture values and expected `ID_LIST`s.
- [ ] **Step 2: Run** `make test`. Expected: FAIL.
- [ ] **Step 3: Implement** `RolandImport.swift`.
- [ ] **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Port the Librarian import`.

### Task 4: MIDI bytes, endpoints and Universal MIDI Packets

**Files:**
- Create: `Sources/BossToneStudioCore/MidiMessages.swift`, `Sources/BossToneStudioCore/UMP.swift`,
  `Tests/BossToneStudioCoreTests/MidiMessagesTests.swift`, `Tests/BossToneStudioCoreTests/UMPTests.swift`

**Interfaces:**
- Produces:
  - `public func splitMessages(_ data: [UInt8]) -> [[UInt8]]` (rules of `bts/midi.py` `split_messages`)
  - `public func bytes(fromHex hex: String) throws -> [UInt8]` (whitespace ignored, odd length or non-hex throws);
    `public func hex(_ bytes: [UInt8]) -> String` (uppercase, no spaces)
  - `public func isListablePortName(_ name: String) -> Bool` (false if it contains any of `<>&"'`)
  - `public func endpointsJSON(_ names: [String]) -> String` (array of objects with `MIDIEntityNameKey`,
    `MIDIDeviceNameKey`, `MIDIEndpointUIDKey` all = name, ADR-0005)
  - `public func entityName(fromEndpointJSON json: String) -> String?`
  - `public func umpWords(for message: [UInt8], group: UInt8 = 0) -> [UInt32]`
  - `public struct UMPReassembler { public init(); public mutating func feed(_ words: [UInt32]) -> [[UInt8]] }`

UMP layout (MIDI 1.0 protocol, group 0):
```
channel voice 0x8n–0xEn   1 word : 0x2 <<28 | g<<24 | status<<16 | d1<<8 | d2
system 0xF1–0xFE (not F7) 1 word : 0x1 <<28 | g<<24 | status<<16 | d1<<8 | d2
SysEx F0 … F7             per 6 payload bytes (F0/F7 excluded) 2 words:
                          w0 = 0x3<<28 | g<<24 | st<<20 | count<<16 | b0<<8 | b1,  w1 = b2<<24 | b3<<16 | b4<<8 | b5
                          st: 0 complete (one packet), 1 start, 2 continue, 3 end; F0 F7 → one empty complete packet
```
`UMPReassembler.feed` walks the words using the message type's size (MT 0x0–0x2, 0x6, 0x7: 1 word; 0x3, 0x4, 0x8–0xA:
2; 0xB, 0xC: 3; 0x5, 0xD–0xF: 4). MT 0x2 yields `[status, d1, d2]` cut to the channel message's length (`C0`/`D0`:
2 bytes); MT 0x1 yields status plus its data bytes (`F1`, `F3`: 1; `F2`: 2; others 0), dropping `F8` and `FE`; MT 0x3
start/complete opens a buffer with `F0`, end/complete appends `F7` and yields it; continue/end without a start is
dropped; other types are ignored. State carries over between `feed` calls.

- [ ] **Step 1: Write the failing tests**, porting `SplitMessagesTest` (3 tests, same byte values) plus:

```swift
@Test func channelVoiceRoundTrips() { /* [0xB0,7,100], [0xC0,5] → words → feed → same bytes */ }
@Test func shortSysExIsOneCompletePacket() {
    #expect(umpWords(for: [0xF0,0x7E,0x00,0x06,0x01,0xF7]) == [0x3004_7E00, 0x0601_0000])
}
@Test func longSysExUsesStartContinueEnd() { /* 15 payload bytes → 3 packets with st 1,2,3, counts 6,6,3 */ }
@Test func sysExSplitAcrossFeedsIsReassembledOnce() {
    // a 1,000-byte SysEx's words fed in three slices yield exactly one message, equal to the original
}
@Test func clockAndActiveSensingAreDropped() { /* feed words for F8, FE, then [0x90,60,1] → only the note */ }
@Test func portNamesWithMarkupAreNotListed() {
    #expect(isListablePortName("KATANA")); #expect(isListablePortName("KATANA DAW CTRL"))
    #expect(!isListablePortName("<img src=x>")); #expect(!isListablePortName("A&B"))
}
@Test func endpointsCarryTheNameAsUID() { /* decode endpointsJSON(["KATANA"]): all three keys == "KATANA" */ }
@Test func hexRoundTripsAndRejectsGarbage() { /* "f07e" → [0xF0,0x7E]; hex([0xF0,0x7E]) == "F07E"; "F0Z" throws */ }
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Add MIDI message handling and UMP conversion`.

### Task 5: MIDI controller over a backend protocol

**Files:**
- Create: `Sources/BossToneStudioCore/MidiController.swift`, `Tests/BossToneStudioCoreTests/MidiControllerTests.swift`

**Interfaces:**
- Consumes: Task 4's functions, `log`.
- Produces:

```swift
public protocol MidiBackend: AnyObject, Sendable {
    func sourceNames() -> [String]
    func destinationNames() -> [String]
    func connectInput(named name: String, onMessage: @escaping @Sendable ([UInt8]) -> Void) throws
    func disconnectInput()
    func connectOutput(named name: String) throws
    func disconnectOutput()
    func send(_ message: [UInt8]) throws          // one whole MIDI 1.0 message
    func onSetupChanged(_ handler: @escaping @Sendable () -> Void)
}
public typealias Emit = @Sendable (_ prop: String, _ kind: String, _ args: [String]) -> Void
public final class MidiController: Sendable {
    public init(backend: MidiBackend?, emit: @escaping Emit)   // nil: no CoreMIDI (lists empty, connects fail)
    public func inputs() -> String; public func outputs() -> String          // endpointsJSON of listable names
    public func connectInput(_ endpointJSON: String?); public func connectOutput(_ endpointJSON: String?)
    public func disconnectInput(); public func disconnectOutput(); public func disconnectAll()
    public func send(_ hex: String) throws                                    // no output connected: does nothing
}
```

Behaviour as `bts/midi.py`: connecting first disconnects; a missing name, a name no longer listed or a throwing
backend logs `opening MIDI port '<name>' failed: …` and emits `("midi", "connectfailed", [json or ""])`; incoming
messages emit `("midi", "message", [hex, String(Int(Date().timeIntervalSince1970 * 1000))])`; a setup change emits
`("midi", "changed", [])` only when `(sourceNames, destinationNames)` differ from the last seen pair. State behind
`OSAllocatedUnfairLock`.

- [ ] **Step 1: Write the failing tests** with a `FakeMidiBackend` (records calls, can throw, can fire messages and
  setup changes):

```swift
@Test func aMissingOrUnopenablePortReportsConnectfailed() { /* port python test: unknown name, throwing open, nil json */ }
@Test func sendSplitsIntoWholeMessages() { /* send("B00764F07E7FF7") → backend got [0xB0,7,0x64] and [0xF0,0x7E,0x7F,0xF7] */ }
@Test func incomingMessagesAreEmittedAsUppercaseHex() { /* fake fires [0xF0,0x41,0xF7] → emit midi.message "F041F7" */ }
@Test func changedIsEmittedOnlyWhenPortsReallyChange() { /* same lists → no event; new source → one "changed" */ }
@Test func withoutCoreMIDIListsAreEmptyAndConnectsFail() { /* backend nil: inputs() == "[]", connect → connectfailed */ }
@Test func markupPortNamesAreHidden() { /* source "<b>x" not in inputs() */ }
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Port the MIDI controller behind a backend protocol`.

### Task 6: File access sets

**Files:**
- Create: `Sources/BossToneStudioCore/FileAccess.swift`, `Tests/BossToneStudioCoreTests/FileAccessTests.swift`

**Interfaces:**
- Produces: `public final class FileAccess: Sendable { public init(dataDir: URL, tempDir: URL);
  public func checkRead(_ path: String) throws -> URL; public func checkWrite(_ path: String) throws -> URL;
  public func allowOpen(_ path: String); public func allowSave(_ path: String) }`

Canonical path: standardise, then `realpath(3)` the path if it exists, else `realpath` of its parent plus the last
component. Readable: inside the data or temp folder (prefix with a trailing `/`), or picked in the open or the save
dialog. Writable: inside the data or temp folder, or picked in the save dialog. Errors: `FileAccessError` with message
`<path> was not chosen in a file dialog` (read) / `<path> was not chosen in a save dialog` (write).

- [ ] **Step 1: Write the failing tests**, porting `test_app_folders_are_permitted`,
  `test_a_file_chosen_in_a_dialog_is_permitted` and `test_other_paths_and_traversal_are_refused`, plus:

```swift
@Test func anOpenedFileIsReadOnly() { /* allowOpen(p): checkRead ok, checkWrite throws */ }
@Test func aSavedPathIsWritableAndReadable() { /* allowSave(p): both ok */ }
@Test func pathsWithSpacesAndUnicodeArePermittedExactly() { /* "Foo Fighters_export ž.tsl" via allowSave */ }
@Test func tempFolderIsReachableUnderItsSymlinkedName() { /* tempDir under /var/folders, path given via /private/var and /var */ }
@Test func symlinkOutOfTheDataFolderIsRefused() { /* dataDir/link -> /etc, checkRead(dataDir/link/hosts) throws */ }
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Separate readable and writable files`.

### Task 7: Tone Central proxy

**Files:**
- Create: `Sources/BossToneStudioCore/Proxy.swift`, `Tests/BossToneStudioCoreTests/ProxyTests.swift`

**Interfaces:**
- Produces:
  - `public enum ProxyResult: Sendable { case response(status: Int, contentType: String, body: Data); case refused(String); case failed(String) }`
  - `public protocol ProxyFetching: Sendable { func fetch(_ url: String) async -> ProxyResult }`
  - `public struct Proxy: ProxyFetching { public init(); public static let allowedHosts: Set<String>;
    public static func checkedURL(_ url: String) throws -> URL;
    public static func gate(host: String, status: Int, contentType: String, body: Data) -> ProxyResult }`

`allowedHosts` = `api.roland.com`, `bosstonecentral.com`, `www.youtube.com` (SoundCloud gone). `checkedURL`: scheme
`http`/`https` (any case), host lower-cased in the allowlist, rebuilt as `https://<host><percent-encoded path>?<query>`
(no userinfo, port or fragment). `fetch`: ephemeral `URLSession`, GET, `User-Agent: Mozilla/5.0 (Macintosh)`, 20 s
timeout; a redirect to a URL `checkedURL` refuses cancels the fetch with `.refused`; network errors → `.failed`;
otherwise `gate` on the final URL's host. `gate`: for `api.roland.com` and `bosstonecentral.com`, a 2xx body must parse
as JSON (`JSONSerialization`, fragments allowed) else `.failed("… is not JSON")`; its content type becomes
`application/json` when the upstream type contains `json`, else `text/plain; charset=utf-8`; a non-2xx keeps its status
with an empty `text/plain` body. YouTube responses pass unchanged.

- [ ] **Step 1: Write the failing tests** (no network):

```swift
@Test func toneCentralHostsAreFetchedOverHttps() { /* http://api.roland.com/x?y=1 → https://api.roland.com/x?y=1 */ }
@Test func everythingElseIsRefused() {
    // ftp://api.roland.com, https://example.com, https://api.roland.com.evil.com, https://evil.com#api.roland.com,
    // https://w.soundcloud.com/player/api.js, file:///etc/hosts → throws
}
@Test func urlsAreRebuiltWithoutUserinfoOrPort() {
    #expect(try Proxy.checkedURL("https://u:p@bosstonecentral.com:8443/a.tsl#f").absoluteString
            == "https://bosstonecentral.com/a.tsl")
}
@Test func rolandBodiesMustBeJSON() { /* gate(api.roland.com, 200, "text/html", "<script>") → .failed */ }
@Test func tslKeepsAPlainTextType() { /* gate(bosstonecentral.com, 200, "binary/octet-stream", "{}") → text/plain */ }
@Test func jsonStaysJSON() { /* gate(..., "application/json; charset=utf-8", "{}") → application/json */ }
@Test func rolandErrorsKeepStatusButNoBody() { /* 404 text/html → .response(404, text/plain, empty) */ }
@Test func youtubePassesUnchanged() { /* gate(www.youtube.com, 200, "text/javascript", js) → same */ }
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Port the Tone Central proxy, held to JSON for Roland's hosts`.

### Task 8: Bridge

**Files:**
- Create: `Sources/BossToneStudioCore/Bridge.swift`, `Tests/BossToneStudioCoreTests/BridgeTests.swift`

**Interfaces:**
- Consumes: `Storage2`, `writeAtomically`, `readText`, `MidiController`, `MidiBackend`, `FileAccess`, `log`, `trace`.
- Produces:

```swift
public protocol BridgeHost: AnyObject, Sendable {   // the app window; nil in --browser mode
    func closeWindow()
    func chooseFileToOpen(extensions: [String], completion: @escaping @Sendable (String?) -> Void)
    func chooseFileToSave(suggestedName: String, completion: @escaping @Sendable (String?) -> Void)
}
public protocol CommandDispatching: Sendable {
    var commands: [String] { get }                                 // sorted, e.g. "app_storage2"
    func dispatch(_ command: String, _ args: [String]) throws -> String?
}
public struct BridgeError: Error, CustomStringConvertible { public let description: String }
public final class Bridge: CommandDispatching {
    public init(dataDir: URL, midiBackend: MidiBackend?, exitFallback: Duration = .seconds(2),
                openURL: @escaping @Sendable (URL) -> Void) throws
    public var host: BridgeHost? { get set }
    public let tempDir: URL                                        // bts-XXXXXX in NSTemporaryDirectory(), realpath'd
    public func emit(_ prop: String, _ kind: String, _ args: [String])
    public func windowShouldClose() -> Bool
    public func appExit()
    public func removeTempDir()
}
```

Command table exactly as `Bridge._commands` in `bts/server.py` (23 commands), with these semantics:
`app_ready`/`app_control`/`app_importfile`/`app_exportfile`/`midi_panel` ignore any arguments and answer nil;
`app_getevent` pops the oldest event (`prop\fkind\fargs…`, queue capped at 10,000, oldest dropped) or nil;
`app_storage([data])` and `app_storage2(key, [data])` read (missing → `""`) or write as in Python;
`fs_separator` → `/`; `fs_path(where)` → `tempDir/` or `dataDir/` with a trailing slash, else `""`;
`fs_exec(url)` opens only `http://`/`https://` via `openURL`, else throws `refusing to open '<url>'`;
`fs_readString(path)`/`fs_writeString(path, text)` through `FileAccess` (`checkRead`/`checkWrite`, parent folders
created, atomic); `fs_openfilename([filterJSON])` and `fs_savefilename(name, ext)` call the host and answer nil at once,
then emit `fs openfilename <path or "">` / `fs savefilename <path or "">` after `allowOpen`/`allowSave`;
`ext` must match `^[A-Za-z0-9]{1,10}$` (else throws `refusing extension '<ext>'`) and is appended unless the path
already ends in `.<ext>` (any case); without a host they log
`fs_<event> needs the app window (not available in --browser mode)` and answer nil;
`midi_*` map to `MidiController` (`midi_inendpoints` → `inputs()`, …, `midi_send(hex)` → `send`);
`app_exit` → `appExit()`. Wrong argument counts throw. An unknown command logs `unimplemented $$<cmd> <pyList(args)>`
and answers nil. Every dispatched command but `app_getevent` is traced `->`, every emit `<-`.
Close handshake as `on_closing`/`_app_exit`: `windowShouldClose` returns true once `host` is nil after an exit; the
first call arms the fallback (`exitFallback`) and emits `app command exit`, later calls return false; `appExit` cancels
the fallback, clears `host`, disconnects MIDI and calls the old host's `closeWindow` exactly once.

- [ ] **Step 1: Write the failing tests**, porting `BridgeFilesTest` (`test_save_dialog_refuses_an_extension_…`,
  `test_exec_opens_web_links_only`, `test_storage2_reads_writes_and_deletes`,
  `test_closing_lets_the_page_answer_and_destroys_the_window_once`, `test_storage2_refuses_keys_that_name_a_folder`,
  `test_no_startevent_command_so_native_js_polls_for_events`) with a `FakeHost`, plus:

```swift
@Test func theCommandTableMatchesWhatTheMkIIAppCalls() { #expect(bridge.commands.count == 23 && !bridge.commands.contains("app_startevent")) }
@Test func fsPathEndsWithASlash() { /* "temporary" → tempDir.path + "/", "library" → dataDir.path + "/", "x" → "" */ }
@Test func openDialogResultIsReadableNotWritable() { /* FakeHost answers p; event "fs\fopenfilename\fp"; read ok, write throws */ }
@Test func saveDialogAppendsTheExtension() { /* answers "/x/name" → event path "/x/name.tsl"; "/x/a.TSL" stays */ }
@Test func cancelledDialogEmitsAnEmptyPath() { /* answers nil → "fs\fsavefilename\f" */ }
@Test func theExitFallbackClosesTheWindow() { /* exitFallback .milliseconds(50): closeWindow called once within 1 s */ }
@Test func eventsAreCappedAtTenThousand() { /* emit 10,001 → first popped is #2 */ }
@Test func wrongArgumentCountsThrow() { /* app_storage2 with 0 or 3 args */ }
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Port the bridge command table and close handshake`.

### Task 9: HTTP messages and the page script

**Files:**
- Create: `Sources/BossToneStudioCore/HTTPMessage.swift`, `Sources/BossToneStudioCore/PageScript.swift`,
  `Tests/BossToneStudioCoreTests/HTTPMessageTests.swift`, `Tests/BossToneStudioCoreTests/PageScriptTests.swift`

**Interfaces:**
- Produces:

```swift
public struct HTTPRequest: Sendable {
    public let method: String, target: String, version: String
    public let headers: [(name: String, value: String)]; public let body: Data
    public var path: String { get }  /* target before "?" (raw) */; public var query: String { get }
    public func header(_ name: String) -> String?   // case-insensitive, first match
    public var keepAlive: Bool { get }              // false for HTTP/1.0 or "Connection: close"
    public var requestLine: String { get }
}
public enum ParseResult: Sendable { case incomplete; case request(HTTPRequest, consumed: Int); case invalid(status: Int) }
public func parseRequest(_ buffer: Data, maxHeaderBytes: Int = 65_536, maxBodyBytes: Int = 67_108_864) -> ParseResult
public struct HTTPResponse: Sendable {
    public init(status: Int, contentType: String? = nil, body: Data = Data(), headers: [(String, String)] = [])
    public static func text(_ text: String, status: Int = 200) -> HTTPResponse
    public static func error(_ status: Int) -> HTTPResponse         // "<status> <reason>" as text/plain
    public func serialized(keepAlive: Bool, includeBody: Bool) -> Data
}
public func makeToken() -> String        // 24 random bytes (SecRandomCopyBytes), base64url without padding
public func makeNonce() -> String        // 16 random bytes, base64
public func constantTimeEquals(_ a: String, _ b: String) -> Bool
public enum PageScript {
    public static let nativeScriptTag = #"<script src="js/lib/native.js"></script>"#
    public static func preNative(token: String, nonce: String, commands: [String]) -> String
    public static func inject(into html: String, token: String, nonce: String, commands: [String]) -> String?  // nil: no tag
    public static func contentSecurityPolicy(nonce: String) -> String
    public static let unsupportedPage: String
}
```

Parser: header block ends at CRLFCRLF; over `maxHeaderBytes` without it → `invalid(400)`; request line
`METHOD SP target SP HTTP/1.x` else `invalid(400)`; `Transfer-Encoding` present → `invalid(400)`; `Content-Length`
must be ASCII digits only and ≤ `maxBodyBytes` (differing duplicates → 400); body not yet complete → `incomplete`.
`serialized` always adds `Content-Length`, `Cache-Control: no-store`, `X-Frame-Options: DENY`, and
`Content-Security-Policy: frame-ancestors 'none'` unless the response sets its own CSP; `Connection: close` when not
keep-alive; HEAD sends headers only.
`preNative` is `PRE_NATIVE` from `bts/server.py` verbatim except the opening tag `<script nonce="<nonce>">`;
`commands` is inserted as a JSON array. `contentSecurityPolicy`:

```
default-src 'self'; script-src 'self' 'nonce-<nonce>' 'unsafe-eval' 'unsafe-hashes' 'sha256-<b64 sha256 of "return false">'
https://www.youtube.com; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; frame-src https://www.youtube.com;
connect-src 'self'; font-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'
```
(one line, `; `-separated). `unsupportedPage` is `UNSUPPORTED_PAGE` from Python verbatim.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func aCompleteRequestIsParsed() { /* POST with body, consumed == total bytes, header("content-type") works */ }
@Test func partialRequestsWaitForTheRest() { /* header cut mid-line → .incomplete; body short by 1 byte → .incomplete */ }
@Test func pipelinedRequestsAreParsedOneByOne() { /* two GETs in one buffer: first consumed == length of first */ }
@Test func badLengthsAndChunkedBodiesAreRefused() { /* "Content-Length: -1", "1e3", " 5", 64 MB + 1, Transfer-Encoding → 400 */ }
@Test func oversizedHeadersAreRefused() { /* 70 KB without CRLFCRLF → invalid(400) */ }
@Test func everyResponseForbidsFramingAndCaching() { /* serialized text contains the three headers and Content-Length */ }
@Test func headResponsesHaveNoBody() { }
@Test func tokensAreLongAndUnique() { /* 32 chars, [A-Za-z0-9_-], two calls differ */ }
@Test func injectionHooksNativeJsWithTokenNonceAndCommands() {
    // output contains "<script nonce=\"N\">", "var base = '/T/';", the commands JSON, and the script precedes the tag
}
@Test func injectionRefusesAPageWithoutNativeJs() { /* nil */ }
@Test func cspAllowsOnlyTheNonceAndRolandsHandler() {
    // contains "'nonce-N'", "'unsafe-eval'", "frame-ancestors 'none'", and the sha256 of "return false"
    // ("'sha256-…'" computed independently in the test with CryptoKit's SHA256), no "'unsafe-inline'" in script-src
}
```

- [ ] **Step 2: Run** `make test`. Expected: FAIL. **Step 3: Implement.** **Step 4: Run** `make check`. Expected: PASS.
- [ ] **Step 5: Commit** `Feat(swift): Add HTTP messages and the injected page script with a CSP`.

### Task 10: Router and loopback server with every security rule

**Files:**
- Create: `Sources/BossToneStudioCore/Router.swift`, `Sources/BossToneStudioCore/HTTPServer.swift`,
  `Tests/BossToneStudioCoreTests/RawHTTPClient.swift`, `Tests/BossToneStudioCoreTests/RouterTests.swift`

**Interfaces:**
- Consumes: Task 8 `CommandDispatching`, Task 7 `ProxyFetching`, Task 9 everything, `log`, `escaped`.
- Produces:

```swift
public final class Router: Sendable {
    public init(port: UInt16, token: String, htmlDir: URL, dispatcher: CommandDispatching, proxy: ProxyFetching)
    public func handle(_ request: HTTPRequest) async -> HTTPResponse
}
public final class HTTPServer: Sendable {
    public init(handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse)
    public func start() throws -> UInt16      // binds 127.0.0.1:0 with NWListener, waits for .ready, returns the port
    public func stop()
}
```

Router, in this order (the page is `http://127.0.0.1:<port>/<token>/index.html`):
1. Method not GET/HEAD/POST → 501.
2. `Host` ≠ `127.0.0.1:<port>` → 403.
3. Path percent-decoded once; first segment must equal the token (`constantTimeEquals`) → else 403. Applies to static
   files too.
4. `Origin` present and ≠ `http://127.0.0.1:<port>`, or `Sec-Fetch-Site` present and not `same-origin`/`none` → 403.
5. Rest of the path:
   - `$$…`: non-POST → 405; not `^\$\$[a-z]+_[A-Za-z0-9]+$` → 404; media type (before `;`, trimmed, lower-cased) ≠
     `application/json` → 415; body not a JSON array of strings → 400 with the error text; dispatch → 200
     `application/json` (`null` for nil), a thrown error → 500 with its description, logged
     `$$<cmd> failed: <error>`.
   - `proxy`: GET → `url` query parameter → `proxy.fetch`; `.refused` → 403, `.failed` → 502 (both logged); POST →
     204; HEAD → 405.
   - `log`: POST → log `[js] ` + `escaped(first 500 characters)`, 200 empty; others → 405.
   - anything else is a static file: POST → 204 (telemetry); GET/HEAD: a path that resolves to `htmlDir/index.html`
     (empty, `/`, `./index.html`, `%69ndex.html`, …) → the injected page with the full CSP (a fresh nonce each time)
     or `unsupportedPage` with 500; else a regular file inside `htmlDir` after `realpath` → 200 with the
     `UTType(filenameExtension:)` MIME type (fallback `application/octet-stream`); folders, missing files and anything
     outside → 404.
6. Responses outside 2xx/3xx other than 500 are logged `"<request line, token redacted after repeated
   percent-decoding, control characters escaped>" <status>`.

Server: one receive loop per connection; requests on a connection are handled one at a time, connections run
concurrently; `invalid(status)` answers that status and closes; keep-alive per `HTTPRequest.keepAlive`.

- [ ] **Step 1: Write `RawHTTPClient`**: sends exact bytes to `127.0.0.1:<port>` over a socket and returns
  `(status: Int, headers: [String: String], body: Data)`; a helper `command(_ name:, body:, headers:)` mirrors the
  Python tests' `command()`.
- [ ] **Step 2: Write the failing tests**, porting every test in `BridgeHttpTest` (`tests/test_bridge_http.py`) against
  a real server with a `RecordingDispatcher` and a stub proxy, adjusted to the new rules (127.0.0.1 only, the page
  under the token), and `test_every_command_name_passes_the_route_check` against a real `Bridge`'s `commands`, plus:

```swift
@Test func theBarePageAndBareFilesAreRefused() { /* GET /index.html, /js/lib/native.js → 403 */ }
@Test func staticFilesAreServedUnderTheToken() { /* GET /T/js/lib/native.js → 200 text/javascript */ }
@Test func localhostAndIPv6NamesAreRefused() { /* Host localhost:P and [::1]:P → 403; Origin http://localhost:P → 403 */ }
@Test func thePageCarriesTheFullCSP() { /* GET /T/index.html → header CSP contains "'nonce-" equal to the script's nonce */ }
@Test func traversalOutOfTheWebAppIsRefused() { /* /T/../secret, /T/%2e%2e/secret, /T/js/../../x → 403 or 404, never 200 */ }
@Test func proxyRefusalsAndFailuresMapTo403And502() { }
@Test func aSlowRequestDoesNotBlockOtherConnections() {
    // stub proxy sleeps 1 s; meanwhile a command on a second connection answers in < 0.5 s
}
@Test func keepAliveServesSeveralRequestsOnOneConnection() { }
```

- [ ] **Step 3: Run** `make test`. Expected: FAIL. **Step 4: Implement** `Router.swift` and `HTTPServer.swift`.
- [ ] **Step 5: Run** `make check`. Expected: PASS (all ported Python HTTP tests and the new ones).
- [ ] **Step 6: Commit** `Feat(swift): Serve the page and bridge on 127.0.0.1 behind the token`.

### Task 11: The app: CoreMIDI, window, command line

**Files:**
- Create: `Sources/BossToneStudioCore/AppPaths.swift`, `Sources/BossToneStudio/AppDelegate.swift`,
  `Sources/BossToneStudio/WebWindow.swift`, `Sources/BossToneStudio/CoreMIDIBackend.swift`,
  `Tests/BossToneStudioCoreTests/AppPathsTests.swift`
- Modify: `Sources/BossToneStudio/main.swift`, `Makefile` (`run`, `browser`, `trace`, `roland-import` → Swift)

**Interfaces:**
- Consumes: everything above.
- Produces: `public enum AppPaths { public static let appName: String; public static func dataDir(env:) -> URL;
  public static func htmlDir(env: [String: String], bundleResources: URL?, checkout: URL) -> URL }` (lookup order
  `BTS_HTML_DIR`, `<bundleResources>/roland-html`, `<checkout>/build/roland/html`, Roland's installed app; first with an
  `index.html`, else the first candidate). `CoreMIDIBackend: MidiBackend`, `WebWindow: BridgeHost`.

- `main.swift`: arguments `--browser`, `--import-roland`, as `bts/__main__.py` `main()` including its exit messages
  (exit status 1 on stderr). Take the data-folder lock, run `importOnce`, create `CoreMIDIBackend` (on failure log
  `CoreMIDI unavailable: …` and pass nil), `Bridge`, `Router`, `HTTPServer`. `--browser` prints
  `Serving <html>` and `Open http://127.0.0.1:<port>/<token>/index.html` and runs the main run loop; otherwise
  `NSApplication` with `AppDelegate`. `fs_exec` opens with `NSWorkspace.shared.open`. Remove the temp folder on exit.
- `CoreMIDIBackend`: `MIDIClientCreateWithBlock` (setup-changed notifications); names built like rtmidi's
  `EndpointName(endpoint, isExternal: false)`: the endpoint's `kMIDIPropertyName`, else its entity's; then, if the
  device's name is non-empty and the result does not already start with it, prefix `<device name> `. Input:
  `MIDIInputPortCreateWithProtocol(._1_0)` → `UMPReassembler` per port → `onMessage`. Output: `MIDIOutputPortCreate`;
  `send` builds a `MIDIEventList` from `umpWords` (buffer sized to the message) and calls `MIDISendEventList`.
- `AppDelegate`: app menu (Hide, Quit ⌘Q), Edit menu (Undo, Redo, Cut, Copy, Paste, Select All with the standard
  selectors); `applicationShouldTerminate` → `bridge.windowShouldClose() ? .terminateNow : .terminateCancel`;
  `applicationShouldTerminateAfterLastWindowClosed` → true.
- `WebWindow`: window 1280×800, `contentMinSize` 1160×700, centred, title `AppPaths.appName`; `windowShouldClose` →
  bridge; `WKWebView` on the default data store, `isInspectable` only with `BTS_TRACE=1`; a subclass whose
  `willOpenMenu(_:with:)` removes all items; `WKUIDelegate` alert/confirm/prompt as `NSAlert` sheets;
  `createWebViewWith` opens `http(s)` in the default browser and returns nil; navigation policy: main frame only on
  `http://127.0.0.1:<port>`, `http(s)` elsewhere → default browser + cancel, other schemes cancel; subframes `https`
  and `about:` only. File dialogs as sheets (`NSOpenPanel` with `allowedContentTypes` from the extensions when known,
  `NSSavePanel` with `nameFieldStringValue`), completions on the main thread. All AppKit work on the main thread.

- [ ] **Step 1: Write the failing test** `AppPathsTests`: `htmlDirPrefersTheEnvironmentThenTheBundleThenTheCheckout`,
  `dataDirHonoursBTSDataDir`. **Run** `make test`: FAIL. **Implement** `AppPaths.swift`. **Run**: PASS.
- [ ] **Step 2: Implement** `CoreMIDIBackend`, `WebWindow`, `AppDelegate`, `main.swift`; point the Makefile's `run`,
  `browser`, `trace` (`BTS_TRACE=1`) and `roland-import` at `swift run -c debug BossToneStudio [flag]`.
- [ ] **Step 3: Verify the page side** with the Node simulation of Roland's `native.js` (scratch, uncommitted): run
  `make browser` with `BTS_DATA_DIR=$PWD/tmp/native-check`, save the injected `<script nonce=…>` block from
  `/<token>/index.html`, and run it against `build/roland/html/js/lib/native.js` (the scratch script's tag-stripping
  regex must accept the `nonce` attribute). Expected: `startevent` undefined, a 50 ms interval, POSTs to
  `/<token>/$$app_storage2` with `application/json`, errors thrown as in 0.1.1.
- [ ] **Step 4: Verify in a browser** at the printed URL (Claude's browser tools or Chrome): the page loads with no
  `[js]` lines, `DEVICE NOT FOUND`, offline mode opens the editor and Librarian, Tone Central shows the catalogue,
  a liveset's details and its YouTube preview, right-click shows no menu, no CSP violations in the console.
  `curl` checks from `doc/testing.md` (adapted to `127.0.0.1` and POST JSON) return 403 without the token.
- [ ] **Step 5: Run** `make check`. Expected: PASS.
- [ ] **Step 6: Commit** `Feat(swift): Add the app window, CoreMIDI backend and command line`.

### Task 12: App bundle, icon, signing

**Files:**
- Create: `packaging/make-icon.swift`, `packaging/Info.plist`
- Modify: `Makefile` (`app`, `install`, `build/AppIcon.icns`), `packaging/fetch-roland-assets.sh` if needed

**Interfaces:**
- Consumes: `VERSION`, `build/roland/bts_katana2_m210.zip` (verified by `fetch-roland-assets.sh`).
- Produces: `dist/BOSS TONE STUDIO for KATANA MkII (Apple Silicon).app`.

- `make-icon.swift <in.icns> <out.icns>` (run with `swift`): every image in the source via `CGImageSource`, recoloured
  as `packaging/make_icon.py` does (background `(36,36,36)` → `(92,99,112)`, tolerance 48, weight
  `max(0, 1 - distance/48)` on un-premultiplied RGB), written with `CGImageDestination` type `com.apple.icns` keeping
  each image's properties.
- `Info.plist` template with `@VERSION@`: `CFBundleName`/`CFBundleDisplayName` = app name, `CFBundleExecutable`
  `BossToneStudio`, `CFBundleIdentifier` `local.boss-tone-studio-mac.katana-mk2`, `CFBundleIconFile` `AppIcon`,
  `CFBundlePackageType` `APPL`, `CFBundleShortVersionString`/`CFBundleVersion` `@VERSION@`, `LSMinimumSystemVersion`
  `14.0`, `NSHighResolutionCapable` true, `NSPrincipalClass` `NSApplication`.
- `make app`: `swift build -c release --arch arm64` with `-warnings-as-errors`; `rm -rf build/roland/html` then
  `packaging/fetch-roland-assets.sh build/roland` (re-extracts from the SHA-256-checked zip every time); assemble
  `Contents/MacOS/BossToneStudio`, `Contents/Info.plist`, `Contents/Resources/{AppIcon.icns,roland-html}`;
  `codesign --force --sign - --options runtime --timestamp=none`. `make install` checks
  `codesign --verify --strict` and that `codesign -d --verbose` shows `runtime`, then copies as now.

- [ ] **Step 1: Implement** the icon script and check it: `iconutil -c iconset` on the output lists the same sizes as
  Roland's icon, and a 512 px PNG of it (viewed with the Read tool) shows the slate-grey background.
- [ ] **Step 2: Implement** the plist and Makefile targets. **Run** `make app` (sandbox off). Expected: the bundle,
  `du -sh` a few MB plus Roland's 13 MB, `codesign -dv` shows `flags=0x10000(runtime)`.
- [ ] **Step 3: Run the bundled executable** with `--browser` and `BTS_DATA_DIR=$PWD/tmp/native-check`. Expected: the
  page loads from `roland-html` inside the bundle.
- [ ] **Step 4: Commit** `Feat(swift): Build the signed app bundle with Roland's web app and icon`.

### Task 13: Documents

**Files:**
- Create: `doc/decisions/ADR-0011-native-swift-app.md`, `doc/decisions/ADR-0012-swift-toolchain-without-dependencies.md`
- Modify: `doc/decisions/ADR-0001…` (status: superseded by ADR-0011), `ADR-0003…` (weak points table: each fixed, with
  how; residual risks: jQuery-evaluated `<script>` in Tone Central HTML under `'unsafe-eval'`, YouTube's proxied API),
  `ADR-0005…` (note: kept with CoreMIDI so the stored device choice survives), `ADR-0008…` (PyInstaller part superseded
  by ADR-0011), `ADR-0009…` (superseded by ADR-0012), `doc/bridge-protocol.md` (127.0.0.1 only, page under the token,
  CSP, file sets, proxy rules, CoreMIDI wording, tests path), `doc/testing.md` (Swift commands, `127.0.0.1`),
  `README.md` (how it works and builds, setup without mise, security, weak points, next steps without the rewrite),
  `AGENTS.md` (summary line, commands, version in `VERSION`, sandbox notes for `swift`/CoreMIDI), `CHANGELOG.md`
  (`[0.2.0] - <date>`: Changed — native Swift app, bundle size; Security — each fixed weak point; Removed — Python,
  mise, uv; link reference)

- [ ] **Step 1: Write** the two ADRs (context, decision, consequences, as the existing ones).
- [ ] **Step 2: Update** the listed files; grep the repo for `python`, `rtmidi`, `pywebview`, `PyInstaller`, `mise`,
  `uv `, `localhost`, `bts/` and fix every hit that describes the app (history in ADRs and CHANGELOG stays).
- [ ] **Step 3: Run** the private repo-hygiene grep (its terms live in Roman's private notes, never in the repo; it must find nothing) and `make check`.
- [ ] **Step 4: Commit** `Docs: Describe the native Swift app and its decisions`.

### Task 14: Amp test (Roman, with Claude reading the trace)

- [ ] **Step 1:** `make app`; copy Roman's data folder to `tmp/amp-test-data`; Roman runs
  `BTS_TRACE=1 BTS_DATA_DIR=$PWD/tmp/amp-test-data "dist/<app>.app/Contents/MacOS/BossToneStudio" 2>&1 | tee tmp/amp-test.log`
  outside Claude's sandbox, with the KATANA-ARTIST MkII, then the KATANA-HEAD MkII.
- [ ] **Step 2:** Roman checks in the window: the Librarian is there; the app reconnects to the stored `KATANA` without
  the device picker (port names match rtmidi's); knobs both ways; `.tsl` export and re-import; All Data Backup and its
  restore; delete a patch and a liveset (still gone after reopening); an `alert` (e.g. an invalid import file); Tone
  Central details and adding a liveset; Cmd-Q and the close button.
- [ ] **Step 3:** Claude reads `tmp/amp-test.log` against `doc/testing.md` › With an amp (Identity Reply, connect,
  editor mode on/off, both directions, clean exit 0, no `[js]`/`failed` lines). Any failure: fix with a test first,
  rebuild, repeat.
- [ ] **Step 4:** Record the verified amps in the README; commit `Docs: Record the amps verified with the native app`.

### Task 15: Remove Python

**Files:**
- Delete: `bts/`, `tests/`, `pyproject.toml`, `requirements.txt`, `requirements-app.txt`, `mise.toml`,
  `packaging/app.spec`, `packaging/make_icon.py`
- Modify: `Makefile` (drop `deps`, `lock`, `PYTHON`, `SRC`; `setup` = toolchain check + `roland-assets`), `.gitignore`
  (drop `.venv/`, `__pycache__/`), any doc still naming them

- [ ] **Step 1:** Check every Python test has a Swift counterpart: list `def test_` names in `tests/` against the Swift
  test names (Tasks 2–10); port any missing one first.
- [ ] **Step 2:** Delete and update the files above; `rm -rf .venv`.
- [ ] **Step 3: Run** `make check` and `make app`. Expected: PASS, bundle builds. Grep for `python`/`bts/`/`.venv`.
- [ ] **Step 4: Commit** `Chore: Remove the Python shell, its tests and tooling`.
- [ ] **Step 5:** Push `feat/native-app` (never `--all`) and open a draft PR; Roman decides on reviews and readiness.
