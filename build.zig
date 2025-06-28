const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vertex_shader_compiler = b.addSystemCommand(&.{ "glslc", "-o" });
    const vert_shader_out = vertex_shader_compiler.addOutputFileArg("vert.spv");
    vertex_shader_compiler.addFileArg(b.path("src/shader.vert" ));
    b.getInstallStep().dependOn(&b.addInstallBinFile(vert_shader_out, "vert.spv").step);

    const fragment_shader_compiler = b.addSystemCommand(&.{ "glslc", "-o" });
    const frag_shader_out = fragment_shader_compiler.addOutputFileArg("frag.spv");
    fragment_shader_compiler.addFileArg(b.path("src/shader.frag" ));
    b.getInstallStep().dependOn(&b.addInstallBinFile(frag_shader_out, "frag.spv").step);

    const exe = b.addExecutable(.{
        .name = "zigvulkan",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("glm");
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.cwd = b.path("zig-out/bin");
    run_exe.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the application");

    run_step.dependOn(&run_exe.step);
}
