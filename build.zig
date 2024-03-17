const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vertex_shader_compiler = b.addSystemCommand(&.{"glslc"});
    vertex_shader_compiler.addArgs(&.{"-o vert.spv"});
    vertex_shader_compiler.addFileArg(.{ .path = "src/shader.vert" });
    const vertex_out = vertex_shader_compiler.captureStdOut();
    b.getInstallStep().dependOn(&b.addInstallBinFile(vertex_out, "vert.spv").step);

    const fragment_shader_compiler = b.addSystemCommand(&.{"glslc"});
    fragment_shader_compiler.addArgs(&.{"-o frag.spv"});
    fragment_shader_compiler.addFileArg(.{ .path = "src/shader.frag" });
    const fragment_out = fragment_shader_compiler.captureStdOut();
    b.getInstallStep().dependOn(&b.addInstallBinFile(fragment_out, "frag.spv").step);

    const exe = b.addExecutable(.{
        .name = "zigvulkan",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("SDL2");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("glm");
    b.installArtifact(exe);
}
