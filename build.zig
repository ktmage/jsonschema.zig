const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const lib_mod = b.addModule("jsonschema", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // QuickJS libregexp (ECMA-262 regex engine)
    lib_mod.addCSourceFiles(.{
        .files = &.{
            "src/libregexp/libregexp.c",
            "src/libregexp/libunicode.c",
            "src/libregexp/cutils.c",
            "src/libregexp/lre_shim.c",
        },
        .flags = &.{ "-std=c11", "-DCONFIG_VERSION=\"jsonschema.zig\"" },
    });
    lib_mod.addIncludePath(b.path("src/libregexp"));

    // Library artifact (static)
    const lib = b.addStaticLibrary(.{
        .name = "jsonschema",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    // Bowtie harness binary
    const harness = b.addExecutable(.{
        .name = "bowtie-zig-jsonschema",
        .root_source_file = b.path("src/harness.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    harness.root_module.addImport("jsonschema", lib_mod);
    b.installArtifact(harness);

    // Tests
    const lib_test = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_test.root_module.addCSourceFiles(.{
        .files = &.{
            "src/libregexp/libregexp.c",
            "src/libregexp/libunicode.c",
            "src/libregexp/cutils.c",
            "src/libregexp/lre_shim.c",
        },
        .flags = &.{ "-std=c11", "-DCONFIG_VERSION=\"jsonschema.zig\"" },
    });
    lib_test.root_module.addIncludePath(b.path("src/libregexp"));

    // JSON Schema Test Suite (lazy dependency — only fetched for tests)
    if (b.lazyDependency("json_schema_test_suite", .{})) |test_suite_dep| {
        const options = b.addOptions();
        options.addOptionPath("test_suite_path", test_suite_dep.path("tests/draft7"));
        options.addOptionPath("test_suite_path_2020", test_suite_dep.path("tests/draft2020-12"));
        options.addOptionPath("remotes_path", test_suite_dep.path("remotes"));
        lib_test.root_module.addOptions("build_options", options);
    }

    const run_lib_test = b.addRunArtifact(lib_test);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_test.step);
}
