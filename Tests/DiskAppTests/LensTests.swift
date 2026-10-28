import Foundation
import Testing
import DiskEngine
@testable import DiskApp

@Test func bundledRulesLoadAndCoverTheSpecSet() {
    let ids = Set(LensRules.bundled.rules.map(\.id))
    #expect(ids.isSuperset(of: ["xcode-derived-data", "xcode-archives", "simulator-devices", "simulator-runtimes", "node-modules",
                                "npm-cache", "yarn-cache", "pnpm-store", "pip-cache", "homebrew-cache", "cargo-registry",
                                "gradle-caches", "user-caches", "old-installers", "final-cut-render", "final-cut-proxies",
                                "premiere-cache", "davinci-cache", "docker", "ios-backups", "trash"]))
    #expect(LensRules.bundled.rules.allSatisfy { ($0.safety == .appManaged) == ($0.instruction != nil) })
}

@Test func patternsMatchComponents() {
    let render = LensPattern("**/*.fcpbundle/**/Render Files")
    #expect(render.matches("Users/u/Movies/Trip.fcpbundle/Day 1/Render Files"))
    #expect(render.matches("Trip.fcpbundle/Render Files"))
    #expect(!render.matches("Users/u/Movies/Render Files"))
    #expect(LensPattern("Users/*/Library/Caches/*").matches("users/U/library/caches/com.foo"))
    #expect(!LensPattern("Users/*/Library/Caches/*").matches("Users/u/Library/Caches"))
    #expect(LensPattern("Users/*/Library/Caches/Yarn").literalCount == 4)
}

@Test func reportFindsHitsAndStopsAtTheOuterOne() async throws {
    let idx = try await Fixtures.index([
        "Users/u/Library/Developer/Xcode/DerivedData/App-abc/Build/x.bin": 3_000_000,
        "Users/u/Library/Developer/Xcode/DerivedData/App-abc/node_modules/y.bin": 2_000_000,
        "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw": 4_000_000,
        "Users/u/code/web/node_modules/left-pad/z.bin": 1_500_000,
        "Users/u/code/web/node_modules/left-pad/node_modules/w.bin": 1_200_000,
        "Users/u/code/tiny/node_modules/t.txt": 10,
    ])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(r.hits.map(\.path) == ["Users/u/Library/Developer/Xcode/DerivedData",
                                   "Users/u/Library/Containers/com.docker.docker", "Users/u/code/web/node_modules"])
    #expect(r.hits.map(\.safety) == [.regenerates, .appManaged, .regenerates])
    #expect(r.total(.regenerates) == r.hits[0].size + r.hits[2].size && r.total(.appManaged) == r.hits[1].size)
}

@Test func overlappingRulesCountEachByteOnce() async throws {
    let idx = try await Fixtures.index(["Users/u/Library/Caches/Yarn/v6/a.bin": 2_000_000,
                                        "Users/u/Library/Caches/Yarn/node_modules/c.bin": 1_100_000,
                                        "Users/u/Library/Caches/com.app/b.bin": 1_500_000])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(Dictionary(uniqueKeysWithValues: r.hits.map { ($0.path, $0.ruleID) })
        == ["Users/u/Library/Caches/Yarn": "yarn-cache", "Users/u/Library/Caches/com.app": "user-caches"])
    let caches = try #require(idx.folder(atRelativePath: "Users/u/Library/Caches"))
    #expect(r.total(.regenerates) == idx.folders[Int(caches)].totalAllocated)
}

@Test func oldInstallersNeedThirtyDays() async throws {
    let idx = try await Fixtures.index(["Users/u/Downloads/Old.dmg": 2_000_000, "Users/u/Downloads/New.pkg": 2_000_000,
                                        "Users/u/Downloads/notes.pdf": 2_000_000])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let r = LensMatcher.report(index: idx, rules: .bundled, now: now) {
        $0.hasSuffix("Old.dmg") ? now.addingTimeInterval(-31 * 86_400) : now.addingTimeInterval(-29 * 86_400)
    }
    #expect(r.hits.map(\.path) == ["Users/u/Downloads/Old.dmg"])
    #expect(r.hits[0].isFolder == false && r.hits[0].safety == .review && r.hits[0].ruleID == "old-installers")
}

@Test func reportKeepsTheLargestHits() async throws {
    let idx = try await Fixtures.index(["a/node_modules/x.bin": 3_000_000, "b/node_modules/x.bin": 2_000_000, "c/node_modules/x.bin": 1_500_000])
    let r = LensMatcher.report(index: idx, rules: .bundled, limit: 2)
    #expect(r.hits.map(\.path) == ["a/node_modules", "b/node_modules"] && r.total(.regenerates) == r.hits[0].size + r.hits[1].size)
}

// C3: node_modules that belong to an app or a global install are not project dependencies.
@Test func nodeModulesInsideAnAppBundleIsNotAHit() async throws {
    let idx = try await Fixtures.index([
        "Applications/Code.app/Contents/Resources/app/node_modules/x.bin": 2_000_000,
        "usr/local/lib/node_modules/npm/y.bin": 2_000_000,
        "opt/homebrew/Cellar/node/22/lib/node_modules/z.bin": 2_000_000,
        "Users/u/.nvm/versions/node/v22/lib/node_modules/w.bin": 2_000_000,
        "Users/u/Movies/Resolve.app/CacheClip/c.bin": 2_000_000,
        "Users/u/code/web/node_modules/x.bin": 2_000_000,
    ])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(r.hits.map(\.path) == ["Users/u/code/web/node_modules"])
    #expect(LensRules.bundled.rule(covering: "Applications/Code.app/Contents/Resources/app/node_modules") == nil)
    #expect(LensRules.bundled.rule(covering: "Users/u/code/web/node_modules/left-pad")?.id == "node-modules")
}

// C1: a parent of a contents rule is explained on hover but is not itself a covered item.
@Test func parentsAreCoveredOnlyWhenAsked() {
    let rules = LensRules.bundled
    #expect(rules.rule(covering: "Users/u/Library/Caches") == nil)
    #expect(rules.rule(covering: "Users/u/Library/Caches", includeParents: true)?.id == "user-caches")
    #expect(rules.rule(covering: "Users/u/Library/Caches/Yarn")?.id == "yarn-cache")
    #expect(rules.rule(covering: "Users/u/Library/Caches/Yarn/v6/a.bin")?.id == "yarn-cache")
}

@Test func rulesFileVersionAndLongPatternsAreChecked() throws {
    #expect(throws: (any Error).self) { try LensRules(json: Data(#"{"version": 2, "rules": []}"#.utf8)) }
    let long = Array(repeating: "a", count: 64).joined(separator: "/")
    let json = #"{"version": 1, "rules": [{"id": "x", "name": "x", "pattern": "\#(long)", "safety": "review", "explanation": "e"}]}"#
    #expect(throws: (any Error).self) { try LensRules(json: Data(json.utf8)) }
    let ok = try LensRules(json: Data(#"{"version": 1, "rules": [{"id": "x", "name": "X", "pattern": "a/b", "safety": "app-managed", "explanation": "E.", "instruction": "Do it."}]}"#.utf8))
    #expect(ok.rule(id: "x")?.hoverText == "E. Do it.")
}

// Fix round 1: node_modules that belong to editors and tools are not project dependencies.
@Test func toolNodeModulesAreNotHits() async throws {
    let idx = try await Fixtures.index([
        "Users/u/.vscode/extensions/x/node_modules/a.bin": 2_000_000,
        "Users/u/.claude/plugins/p/node_modules/b.bin": 2_000_000,
        "Users/u/Library/Application Support/Code/node_modules/c.bin": 2_000_000,
        "Users/u/code/app/node_modules/d.bin": 2_000_000,
    ])
    let r = LensMatcher.report(index: idx, rules: .bundled)
    #expect(r.hits.map(\.path) == ["Users/u/code/app/node_modules"])
    #expect(LensRules.bundled.rule(covering: "Users/u/.vscode/extensions/x/node_modules") == nil)
    #expect(LensRules.bundled.rule(id: "davinci-cache")?.safety == .review)
}

// Final review I1: node_modules under system and Homebrew locations belong to tools, not projects. Paths are relative to the drive
// root, so an external drive's own top-level `Library` is skipped too.
@Test func systemAndHomebrewNodeModulesAreNotHits() async throws {
    let rules = LensRules.bundled
    for path in ["opt/homebrew/Caskroom/x/node_modules", "usr/local/lib/node_modules", "usr/local/share/t/node_modules",
                 "Library/Application Support/t/node_modules", "Applications/Tool/node_modules", "System/Library/x/node_modules",
                 "private/var/x/node_modules", "Volumes/Other/proj/node_modules", "Users/Shared/Library/t/node_modules",
                 "usr/local/Caskroom/x/1.0/node_modules", "Users/a/stuff/Caskroom/x/node_modules"] {
        #expect(rules.rule(covering: path) == nil, "\(path)")
    }
    #expect(rules.rule(covering: "Users/a/proj/node_modules")?.id == "node-modules")
    #expect(rules.rule(covering: "proj/node_modules")?.id == "node-modules")
    let idx = try await Fixtures.index([
        "opt/homebrew/Caskroom/x/node_modules/a.bin": 2_000_000,
        "usr/local/lib/node_modules/b.bin": 2_000_000,
        "Library/Application Support/t/node_modules/c.bin": 2_000_000,
        "Users/a/proj/node_modules/d.bin": 2_000_000,
    ])
    #expect(LensMatcher.report(index: idx, rules: rules).hits.map(\.path) == ["Users/a/proj/node_modules"])
}

