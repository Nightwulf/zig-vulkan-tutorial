const std = @import("std");
const gfx = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_vulkan.h");
    //   @cInclude("glm/glm.h");
});

const InitError = error{
    VulkanError,
    SDLError,
};

const Globals = struct {
    window: *gfx.SDL_Window,
    instance: gfx.VkInstance,
    physical_device: gfx.VkPhysicalDevice,
    graphics_family_idx: u32,
    device: gfx.VkDevice,
    graphics_queue: gfx.VkQueue,
    surface: gfx.VkSurfaceKHR,
    present_family_index: u32,
};

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var allocator = arena.allocator();

pub fn main() !void {
    const globals = try init();

    _ = gfx.SDL_Delay(5000);

    cleanup(globals);
    arena.deinit();
}

fn init() !Globals {
    const init_rc = gfx.SDL_Init(gfx.SDL_INIT_EVERYTHING);
    if (init_rc != 0) {
        return InitError.SDLError;
    }

    const window = gfx.SDL_CreateWindow("SDL example vulkan window", 100, 100, 800, 600, gfx.SDL_WINDOW_SHOWN | gfx.SDL_WINDOW_VULKAN) orelse {
        return InitError.SDLError;
    };

    // for later evaluation of needed extensions
    var extension_count: u32 = 0;
    _ = gfx.vkEnumerateInstanceExtensionProperties(null, &extension_count, null);

    const app_info = gfx.VkApplicationInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Hello Triangle",
        .applicationVersion = gfx.VK_MAKE_API_VERSION(1, 1, 0, 0),
        .pEngineName = "No Engine",
        .engineVersion = gfx.VK_MAKE_API_VERSION(1, 1, 0, 0),
        .apiVersion = gfx.VK_API_VERSION_1_0,
    };

    var sdl_extension_count: u32 = 0;
    var sdl_extensions: [*c]const u8 = null;

    _ = gfx.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, &sdl_extensions);

    const create_info = gfx.VkInstanceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = sdl_extension_count,
        .ppEnabledExtensionNames = &sdl_extensions,
    };

    var instance: gfx.VkInstance = undefined;
    const result = gfx.vkCreateInstance(&create_info, null, &instance);
    if (result != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    const physical_device = try selectPhysicalDevice(instance);

    const graphical_index = try findQueueFamilies(physical_device);

    const device = try createLogicalDevice(physical_device, graphical_index);

    var queue: gfx.VkQueue = undefined;
    gfx.vkGetDeviceQueue(device, graphical_index, 0, &queue);

    var surface: gfx.VkSurfaceKHR = undefined;
    if (gfx.SDL_Vulkan_CreateSurface(window, instance, &surface) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    const present_idx = try getPresentFamilyIndex(physical_device, surface, graphical_index);

    return Globals{ .window = window, .instance = instance, .physical_device = physical_device, .graphics_family_idx = graphical_index, .device = device, .graphics_queue = queue, .surface = surface, .present_family_index = present_idx };
}

fn createLogicalDevice(physical_device: gfx.VkPhysicalDevice, graphical_index: u32) !gfx.VkDevice {
    var queue_priority: f32 = 1.0;
    var queue_create_info = gfx.VkDeviceQueueCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = graphical_index,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    var createInfo = gfx.VkDeviceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = &queue_create_info,
        .queueCreateInfoCount = 1,
        .pEnabledFeatures = &gfx.VkPhysicalDeviceFeatures{},
        .enabledLayerCount = 0,
    };
    var device: gfx.VkDevice = undefined;
    if (gfx.vkCreateDevice(physical_device, &createInfo, null, &device) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return device;
}

fn findQueueFamilies(physical_device: gfx.VkPhysicalDevice) !u32 {
    var queue_family_count: u32 = 0;
    gfx.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
    const queue_families: []gfx.VkQueueFamilyProperties = try allocator.alloc(gfx.VkQueueFamilyProperties, queue_family_count);
    gfx.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

    // continue here with queue families!

    var family_idx: u32 = 0;
    for (queue_families) |family| {
        if (family.queueFlags & gfx.VK_QUEUE_GRAPHICS_BIT != 0) {
            return family_idx;
        }
        family_idx += 1;
    }
    return InitError.VulkanError;
}

fn getPresentFamilyIndex(device: gfx.VkPhysicalDevice, surface: gfx.VkSurfaceKHR, graphical_idx: u32) !u32 {
    var present_support: gfx.VkBool32 = 0;
    _ = gfx.vkGetPhysicalDeviceSurfaceSupportKHR(device, graphical_idx, surface, &present_support);
    if (present_support == gfx.VK_FALSE) {
        return InitError.VulkanError;
    }
    return graphical_idx;
}

fn selectPhysicalDevice(instance: gfx.VkInstance) !gfx.VkPhysicalDevice {
    var physical_device: gfx.VkPhysicalDevice = undefined;
    var device_count: u32 = 0;
    const phys_devices_rs = gfx.vkEnumeratePhysicalDevices(instance, &device_count, null);
    if (phys_devices_rs != gfx.VK_SUCCESS or device_count == 0) {
        return InitError.VulkanError;
    }

    const device_list: []gfx.VkPhysicalDevice = try allocator.alloc(gfx.VkPhysicalDevice, device_count);
    _ = gfx.vkEnumeratePhysicalDevices(instance, &device_count, device_list.ptr);

    for (device_list) |device| {
        var deviceProperties: gfx.VkPhysicalDeviceProperties = undefined;
        var deviceFeatures: gfx.VkPhysicalDeviceFeatures = undefined;

        gfx.vkGetPhysicalDeviceProperties(device, &deviceProperties);
        gfx.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);
        if (deviceProperties.deviceType == gfx.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and deviceFeatures.geometryShader != 0) {
            physical_device = device;
        }
    }

    if (physical_device == undefined) {
        return InitError.VulkanError;
    }
    return physical_device;
}

fn cleanup(globals: Globals) void {
    // cleanup vulkan
    gfx.vkDestroySurfaceKHR(globals.instance, globals.surface, null);
    gfx.vkDestroyInstance(globals.instance, null);
    gfx.vkDestroyDevice(globals.device, null);

    // cleanup SDL
    gfx.SDL_DestroyWindow(globals.window);
    gfx.SDL_Quit();
}
