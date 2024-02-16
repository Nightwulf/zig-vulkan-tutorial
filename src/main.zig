const std = @import("std");
const vk = @cImport({
    @cInclude("vulkan/vulkan.h");
});
const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_vulkan.h");
});
const glm = @cImport({
    @cInclude("glm.h");
});

const InitError = error{
    VulkanError,
    SDLError,
};

const Globals = struct {
    window: *sdl.SDL_Window,
    instance: vk.VkInstance,
};

pub fn main() !void {
    const globals = try init();

    _ = sdl.SDL_Delay(5000);

    cleanup(globals);
}

fn init() !Globals {
    const init_rc = sdl.SDL_Init(sdl.SDL_INIT_EVERYTHING);
    if (init_rc != 0) {
        return InitError.SDLError;
    }

    const window = sdl.SDL_CreateWindow("SDL example vulkan window", 100, 100, 800, 600, sdl.SDL_WINDOW_SHOWN | sdl.SDL_WINDOW_VULKAN) orelse {
        return InitError.SDLError;
    };

    // for later evaluation of needed extensions
    var extension_count: u32 = 0;
    _ = vk.vkEnumerateInstanceExtensionProperties(null, &extension_count, null);

    const app_info = vk.VkApplicationInfo{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = vk.VK_MAKE_API_VERSION(1, 1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = vk.VK_MAKE_API_VERSION(1, 1, 0, 0),
        .apiVersion = vk.VK_API_VERSION_1_0,
    };

    var sdl_extension_count: u32 = 0;
    var sdl_extensions: [*c]const u8 = null;

    _ = sdl.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, &sdl_extensions);

    const create_info = vk.VkInstanceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = sdl_extension_count,
        .ppEnabledExtensionNames = &sdl_extensions,
    };

    var instance: vk.VkInstance = undefined;
    const result = vk.vkCreateInstance(&create_info, null, &instance);
    if (result != vk.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return Globals{ .window = window, .instance = instance };
}

fn cleanup(globals: Globals) void {
    // cleanup vulkan
    vk.vkDestroyInstance(globals.instance, null);

    // cleanup SDL
    sdl.SDL_DestroyWindow(globals.window);
    sdl.SDL_Quit();
}
