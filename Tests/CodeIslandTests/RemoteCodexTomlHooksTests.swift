import XCTest
@testable import CodeIsland

/// Executes the generated remote helper against a sandbox. The same fixtures
/// exercise the local installer, including exact source preservation (#354).
final class RemoteCodexTomlHooksTests: XCTestCase {
    private var script = ""

    override func setUp() {
        super.setUp()
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")
        script = RemoteInstaller.configureRemoteHooksScript(host: host)
    }

    private func runEnsure(
        _ config: String,
        interpreter: String = "/usr/bin/python3",
        validator: String = "native",
        checkSemantics: Bool = false,
        symlink: Bool = false,
        permissions: Int? = nil,
        staleTemporarySymlink: Bool = false
    ) throws -> (contents: String, succeeded: Bool) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-toml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let configURL = sandbox.appendingPathComponent("config.toml")
        let targetURL = symlink ? sandbox.appendingPathComponent("dotfile.toml") : configURL
        try Data(config.utf8).write(to: targetURL)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: targetURL.path)
        }
        let unrelated = sandbox.appendingPathComponent("unrelated.txt")
        if staleTemporarySymlink {
            try "do not overwrite".write(to: unrelated, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: configURL.appendingPathExtension("tmp"), withDestinationURL: unrelated)
        }
        if symlink {
            try FileManager.default.createSymbolicLink(at: configURL, withDestinationURL: targetURL)
        }
        // Do not import the whole script: its top-level code installs other CLIs.
        let start = try XCTUnwrap(script.range(of: "# Codex TOML editing (#354)."))
        let end = try XCTUnwrap(script.range(of: "def install_codex():"))
        let chunk = String(script[start.lowerBound..<end.lowerBound])
        let moduleURL = sandbox.appendingPathComponent("codex_toml_helpers.py")
        try ("import os\nimport pathlib\n" + chunk).write(to: moduleURL, atomically: true, encoding: .utf8)

        let runner = """
        import importlib.util, json, pathlib, sys, types
        mode = sys.argv[3]
        if mode == "unavailable":
            sys.modules["tomllib"] = None
        elif mode in ("reject_candidate", "wrong_flag"):
            validator = types.ModuleType("tomllib")
            calls = [0]
            def loads(text):
                calls[0] += 1
                if calls[0] == 1:
                    return {}
                if mode == "reject_candidate":
                    raise ValueError("candidate rejected")
                return {"features": {"hooks": False}}
            validator.loads = loads
            sys.modules["tomllib"] = validator
        spec = importlib.util.spec_from_file_location("codex_toml_helpers", sys.argv[1])
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        path = pathlib.Path(sys.argv[2])
        with path.open(encoding="utf-8", newline="") as stream:
            original = stream.read()
        ok = module.ensure_toml_codex_hooks(path)
        if sys.argv[4] == "true":
            import tomllib
            try:
                before = tomllib.loads(original)
            except tomllib.TOMLDecodeError:
                # A healed pre-fix duplicate [features] block: only the result must parse.
                before = None
            after = tomllib.loads(path.read_text())
            assert after.get("features", {}).get("hooks") is True, after
            def without_managed_flags(data):
                features = data.get("features")
                if isinstance(features, dict):
                    features.pop("hooks", None)
                    features.pop("codex_hooks", None)
                    if not features:
                        del data["features"]
                return data
            if before is not None:
                assert without_managed_flags(before) == without_managed_flags(after), "unrelated values changed"
        print(json.dumps({"ok": ok}))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = ["-c", runner, moduleURL.path, configURL.path, validator, checkSemantics ? "true" : "false"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandbox.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        process.environment = environment
        let errors = Pipe()
        let output = Pipe()
        process.standardError = errors
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
        let status = try JSONSerialization.jsonObject(with: output.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        let succeeded = try XCTUnwrap(status?["ok"] as? Bool)
        if symlink {
            let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
            XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        }
        if let permissions {
            let attributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, permissions)
        }
        if staleTemporarySymlink {
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "do not overwrite")
        }
        return (try String(contentsOf: configURL, encoding: .utf8), succeeded)
    }

    /// Optional real parser verification without imposing Python 3.11 on users
    /// or the macOS test runner. The unavailable-validator path is always tested.
    private func validatingInterpreter() throws -> String {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            + directories.map { $0 + "/python3" }
        for path in Set(candidates).sorted() where FileManager.default.isExecutableFile(atPath: path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["-c", "import tomllib"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return path }
        }
        throw XCTSkip("Python with tomllib (3.11+) is not installed")
    }

    func testSourceEditingWithoutTomllibIsSafeAndIdempotent() throws {
        for fixture in CodexTomlHooksFixture.cases {
            let result = try runEnsure(fixture.original, validator: "unavailable")
            XCTAssertEqual(result.succeeded, fixture.expected != nil, fixture.name)
            XCTAssertEqual(result.contents, fixture.expected ?? fixture.original, fixture.name)
            if fixture.expected != nil {
                let repeated = try runEnsure(result.contents, validator: "unavailable")
                XCTAssertTrue(repeated.succeeded, fixture.name)
                XCTAssertEqual(repeated.contents, result.contents, "idempotence: \(fixture.name)")
            }
        }
    }

    func testRealTomllibValidatesRootFlagAndPreservesOtherValues() throws {
        let interpreter = try validatingInterpreter()
        for fixture in CodexTomlHooksFixture.cases {
            let result = try runEnsure(fixture.original, interpreter: interpreter, checkSemantics: fixture.expected != nil)
            XCTAssertEqual(result.succeeded, fixture.expected != nil, fixture.name)
            XCTAssertEqual(result.contents, fixture.expected ?? fixture.original, fixture.name)
        }
    }

    func testRejectedCandidateIsNotWritten() throws {
        let original = "features.hooks = false\n"
        let result = try runEnsure(original, validator: "reject_candidate")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.contents, original)
    }

    func testParsedCandidateMustActuallyEnableRootHooks() throws {
        let original = "features.hooks = false\n"
        let result = try runEnsure(original, validator: "wrong_flag")
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.contents, original)
    }

    func testInvalidInputIsNotWrittenWithRealTomllib() throws {
        let original = "features.hooks = false\nmodel = @invalid\n"
        let result = try runEnsure(original, interpreter: validatingInterpreter())
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.contents, original)
    }

    func testAtomicWritePreservesPermissionsAndIgnoresStaleTemporarySymlink() throws {
        let result = try runEnsure("[features]\nhooks = false\n", permissions: 0o600, staleTemporarySymlink: true)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.contents, "[features]\nhooks = true\n")
    }

    func testRemoteCodexConfigSymlinkIsPreserved() throws {
        let result = try runEnsure("[features]\nhooks = false\n", symlink: true, permissions: 0o640)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.contents, "[features]\nhooks = true\n")
    }
}
