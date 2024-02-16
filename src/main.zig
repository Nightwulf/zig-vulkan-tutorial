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
    physical_device: vk.VkPhysicalDevice,
};

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var allocator = arena.allocator();

pub fn main() !void {
    const globals = try init();

    _ = sdl.SDL_Delay(5000);

    cleanup(globals);
    arena.deinit();
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

    var physical_device: vk.VkPhysicalDevice = undefined;
    var device_count: u32 = 0;
    const phys_devices_rs = vk.vkEnumeratePhysicalDevices(instance, &device_count, null);
    if (phys_devices_rs != vk.VK_SUCCESS or device_count == 0) {
        return InitError.VulkanError;
    }

    const device_list: []vk.VkPhysicalDevice = try allocator.alloc(vk.VkPhysicalDevice, device_count);
    _ = vk.vkEnumeratePhysicalDevices(instance, &device_count, device_list.ptr);

    for (device_list) |device| {
        var deviceProperties: vk.VkPhysicalDeviceProperties = undefined;
        var deviceFeatures: vk.VkPhysicalDeviceFeatures = undefined;

        vk.vkGetPhysicalDeviceProperties(device, &deviceProperties);
        vk.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);
        if (deviceProperties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and deviceFeatures.geometryShader != 0) {
            physical_device = device;
        }
    }

    if (physical_device == undefined) {
        return InitError.VulkanError;
    }

    var queue_family_count: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
    const queue_families: []vk.VkQueueFamilyProperties = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
    vk.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

    // continue here with queue families!

    var family_idx: u32 = 0;
    for (queue_families) |family| {
        if (family.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) {
            family_idx = 
        }
    }

    return Globals{ .window = window, .instance = instance, .physical_device = physical_device };
}

fn cleanup(globals: Globals) void {
    // cleanup vulkan
    vk.vkDestroyInstance(globals.instance, null);

    // cleanup SDL
    sdl.SDL_DestroyWindow(globals.window);
    sdl.SDL_Quit();
}
