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

const QueueType = enum {
    Graphics,
    Presentation,
};

const QueueIndices = struct {
    type: QueueType,
    idx: u32,
};

const Globals = struct {
    window: *gfx.SDL_Window,
    instance: gfx.VkInstance,
    physical_device: gfx.VkPhysicalDevice,
    queue_indices: []QueueIndices,
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

    _ = gfx.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, null);

    const extension_names = try allocator.alloc([*c]const u8, sdl_extension_count);
    _ = gfx.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, extension_names.ptr);

    std.debug.print("SDL-Vulkan-Extensions:\n", .{});
    for (extension_names) |extension| {
        std.debug.print("{s}\n", .{extension});
    }

    const validationLayers = [_][*:0]const u8{"VK_LAYER_LUNARG_standard_validation"};

    const create_info = gfx.VkInstanceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 1,
        .ppEnabledLayerNames = &validationLayers,
        .enabledExtensionCount = sdl_extension_count,
        .ppEnabledExtensionNames = extension_names.ptr,
    };

    // TODO: add callback for Vulkan debug messages!

    _ = gfx.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, null);
    var instance: gfx.VkInstance = undefined;
    const result = gfx.vkCreateInstance(&create_info, null, &instance);
    if (result != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    var surface: gfx.VkSurfaceKHR = undefined;
    if (gfx.SDL_Vulkan_CreateSurface(window, instance, &surface) != gfx.VK_SUCCESS) {
        std.debug.print("Error: {s}\n", .{gfx.SDL_GetError()});
        return InitError.VulkanError;
    }

    const physical_device = try selectPhysicalDevice(instance);

    const queue_indices = try findQueueFamilies(physical_device, surface);

    const device = try createLogicalDevice(physical_device, queue_indices);

    var queue: gfx.VkQueue = undefined;
    gfx.vkGetDeviceQueue(device, getIndexForFamily(queue_indices, QueueType.Graphics), 0, &queue);

    const present_idx = try getPresentFamilyIndex(physical_device, surface, getIndexForFamily(queue_indices, QueueType.Graphics));

    return Globals{ .window = window, .instance = instance, .physical_device = physical_device, .queue_indices = queue_indices, .device = device, .graphics_queue = queue, .surface = surface, .present_family_index = present_idx };
}

fn createLogicalDevice(physical_device: gfx.VkPhysicalDevice, queue_indices: []QueueIndices) !gfx.VkDevice {
    const unique_queue_families: []u32 = try allocator.alloc(u32, queue_indices.len);
    for (queue_indices, 0..) |idx, i| {
        unique_queue_families[i] = idx.idx;
    }
    var queue_create_infos = std.ArrayList(gfx.VkDeviceQueueCreateInfo).init(allocator);
    var queue_priority: f32 = 1.0;
    for (unique_queue_families) |idx| {
        const queue_create_info = gfx.VkDeviceQueueCreateInfo{
            .sType = gfx.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = idx,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };
        try queue_create_infos.append(queue_create_info);
    }
    var createInfo = gfx.VkDeviceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = queue_create_infos.items.ptr,
        .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
        .pEnabledFeatures = &gfx.VkPhysicalDeviceFeatures{},
        .enabledLayerCount = 0,
    };
    var device: gfx.VkDevice = undefined;
    if (gfx.vkCreateDevice(physical_device, &createInfo, null, &device) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return device;
}

fn findQueueFamilies(physical_device: gfx.VkPhysicalDevice, surface: gfx.VkSurfaceKHR) ![]QueueIndices {
    var queue_indices = [_]QueueIndices{
        QueueIndices{ .idx = 0, .type = QueueType.Graphics },
        QueueIndices{ .idx = 0, .type = QueueType.Presentation },
    };
    var queue_family_count: u32 = 0;
    gfx.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);
    const queue_families: []gfx.VkQueueFamilyProperties = try allocator.alloc(gfx.VkQueueFamilyProperties, queue_family_count);
    gfx.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

    var found_gfx = false;
    var found_present = false;
    var idx: u32 = 0;
    for (queue_families) |family| {
        if (family.queueFlags & gfx.VK_QUEUE_GRAPHICS_BIT != 0) {
            found_gfx = true;
            queue_indices[0].idx = idx;
        }
        var present_support: gfx.VkBool32 = gfx.VK_FALSE;
        const rs = gfx.vkGetPhysicalDeviceSurfaceSupportKHR(physical_device, idx, surface, &present_support);
        if (present_support == gfx.VK_TRUE) {
            found_present = true;
            queue_indices[1].idx = idx;
        }
        if (rs != gfx.VK_SUCCESS) {
            std.debug.print("rs: {d}\n", .{rs});
        }
        idx += 1;
    }
    if (!found_gfx or !found_present) {
        return InitError.VulkanError;
    }
    return &queue_indices;
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

// helpers

fn getIndexForFamily(q: []QueueIndices, f: QueueType) u32 {
    for (q) |qi| {
        if (qi.type == f) {
            return qi.idx;
        }
    }
    return 0;
}
