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

const SwapChainSupportDetails = struct {
    capabilities: gfx.VkSurfaceCapabilitiesKHR,
    formats: []gfx.VkSurfaceFormatKHR,
    presentModes: []gfx.VkPresentModeKHR,
};

const SwapChainDetails = struct {
    swapChain: gfx.VkSwapchainKHR,
    swapChainImageFormat: gfx.VkFormat,
    swapChainExtent: gfx.VkExtent2D,
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
    debugMessenger: gfx.VkDebugUtilsMessengerEXT,
    swapChain: gfx.VkSwapchainKHR,
    swapChainImages: []gfx.VkImage,
    swapChainImageFormat: gfx.VkFormat,
    swapChainExtent: gfx.VkExtent2D,
    swapChainImageViews: []gfx.VkImageView,
};

const enableDebugCallback: bool = true;

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

    var final_extension_names = std.ArrayList([*c]const u8).init(allocator);
    try final_extension_names.appendSlice(extension_names);

    if (enableDebugCallback) {
        try final_extension_names.append(gfx.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    }

    const validationLayers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

    var create_info = gfx.VkInstanceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @intCast(final_extension_names.items.len),
        .ppEnabledExtensionNames = final_extension_names.items.ptr,
    };

    if (enableDebugCallback) {
        create_info.enabledLayerCount = 1;
        create_info.ppEnabledLayerNames = &validationLayers;
        const debug_messenger_create_info = populateDebugCreateInfo();
        create_info.pNext = &debug_messenger_create_info;
    }

    _ = gfx.SDL_Vulkan_GetInstanceExtensions(window, &sdl_extension_count, null);
    var instance: gfx.VkInstance = undefined;
    const result = gfx.vkCreateInstance(&create_info, null, &instance);
    if (result != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    var debugMessenger: gfx.VkDebugUtilsMessengerEXT = undefined;
    if (enableDebugCallback) {
        const debug_messenger_create_info = populateDebugCreateInfo();
        if (createDebugUtilsMessengerExt(instance, &debug_messenger_create_info, &debugMessenger) != gfx.VK_SUCCESS) {
            return InitError.VulkanError;
        }
    }

    var surface: gfx.VkSurfaceKHR = undefined;
    if (gfx.SDL_Vulkan_CreateSurface(window, instance, &surface) != gfx.SDL_TRUE) {
        const sdl_err = gfx.SDL_GetError();
        std.debug.print("Error: {s}\n", .{sdl_err});
        return InitError.VulkanError;
    }

    const physical_device = try selectPhysicalDevice(instance);

    const queue_indices = try findQueueFamilies(physical_device, surface);

    const device = try createLogicalDevice(physical_device, queue_indices);

    var queue: gfx.VkQueue = undefined;
    gfx.vkGetDeviceQueue(device, getIndexForFamily(queue_indices, QueueType.Graphics), 0, &queue);

    const present_idx = try getPresentFamilyIndex(physical_device, surface, getIndexForFamily(queue_indices, QueueType.Graphics));

    const swapChainDetails = try querySwapChainSupport(physical_device, surface);

    if (swapChainDetails.formats.len == 0 or swapChainDetails.presentModes.len == 0) {
        return InitError.VulkanError;
    }

    const swap_chain = try createSwapChain(window, device, physical_device, surface);

    const swap_chain_images = try getSwapChainImages(device, swap_chain.swapChain);

    const swap_chain_image_views = try createImageViews(device, swap_chain, swap_chain_images);

    return Globals{
        .window = window,
        .instance = instance,
        .physical_device = physical_device,
        .queue_indices = queue_indices,
        .device = device,
        .graphics_queue = queue,
        .surface = surface,
        .present_family_index = present_idx,
        .debugMessenger = debugMessenger,
        .swapChain = swap_chain.swapChain,
        .swapChainExtent = swap_chain.swapChainExtent,
        .swapChainImageFormat = swap_chain.swapChainImageFormat,
        .swapChainImages = swap_chain_images,
        .swapChainImageViews = swap_chain_image_views,
    };
}

fn createImageViews(device: gfx.VkDevice, swap_chain_details: SwapChainDetails, swap_chain_images: []gfx.VkImage) ![]gfx.VkImageView {
    var swap_chain_image_views: []gfx.VkImageView = try allocator.alloc(gfx.VkImageView, swap_chain_images.len);

    for (swap_chain_images, 0..) |image, i| {
        const create_info = gfx.VkImageViewCreateInfo{
            .sType = gfx.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = gfx.VK_IMAGE_VIEW_TYPE_2D,
            .format = swap_chain_details.swapChainImageFormat,
            .components = gfx.VkComponentMapping{
                .r = gfx.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = gfx.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = gfx.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = gfx.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = gfx.VkImageSubresourceRange{
                .aspectMask = gfx.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        if (gfx.vkCreateImageView(device, &create_info, null, &swap_chain_image_views[i]) != gfx.VK_SUCCESS) {
            return InitError.VulkanError;
        }
    }

    return swap_chain_image_views;
}

fn getSwapChainImages(device: gfx.VkDevice, swap_chain: gfx.VkSwapchainKHR) ![]gfx.VkImage {
    var image_count: u32 = undefined;

    _ = gfx.vkGetSwapchainImagesKHR(device, swap_chain, &image_count, null);
    const images: []gfx.VkImage = try allocator.alloc(gfx.VkImage, image_count);
    _ = gfx.vkGetSwapchainImagesKHR(device, swap_chain, &image_count, images.ptr);
    return images;
}

fn createSwapChain(window: *gfx.SDL_Window, device: gfx.VkDevice, physical_device: gfx.VkPhysicalDevice, surface: gfx.VkSurfaceKHR) !SwapChainDetails {
    const swap_chain_support_details = try querySwapChainSupport(physical_device, surface);
    const surface_format = chooseSwapSurfaceFormat(swap_chain_support_details.formats);
    const present_mode = chooseSwapPresentMode(swap_chain_support_details.presentModes);
    const extent = chooseSwapExtent(window, swap_chain_support_details.capabilities);
    var image_count = swap_chain_support_details.capabilities.minImageCount + 1;
    if (swap_chain_support_details.capabilities.maxImageCount > 0 and image_count > swap_chain_support_details.capabilities.maxImageCount) {
        image_count = swap_chain_support_details.capabilities.maxImageCount;
    }
    var create_info = gfx.VkSwapchainCreateInfoKHR{
        .sType = gfx.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = gfx.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swap_chain_support_details.capabilities.currentTransform,
        .compositeAlpha = gfx.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = gfx.VK_TRUE,
        .oldSwapchain = null,
    };

    const indices = try findQueueFamilies(physical_device, surface);
    if (indices[0].idx != indices[1].idx) {
        const family_indices: [2]u32 = .{ indices[0].idx, indices[1].idx };
        create_info.imageSharingMode = gfx.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = &family_indices;
    } else {
        create_info.imageSharingMode = gfx.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0;
        create_info.pQueueFamilyIndices = null;
    }
    var swap_chain: gfx.VkSwapchainKHR = undefined;
    if (gfx.vkCreateSwapchainKHR(device, &create_info, null, &swap_chain) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return SwapChainDetails{ .swapChain = swap_chain, .swapChainExtent = extent, .swapChainImageFormat = surface_format.format };
}

fn querySwapChainSupport(device: gfx.VkPhysicalDevice, surface: gfx.VkSurfaceKHR) !SwapChainSupportDetails {
    var details: SwapChainSupportDetails = SwapChainSupportDetails{ .capabilities = undefined, .formats = undefined, .presentModes = undefined };
    _ = gfx.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities);

    var format_count: u32 = undefined;
    _ = gfx.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);
    if (format_count != 0) {
        details.formats = try allocator.alloc(gfx.VkSurfaceFormatKHR, format_count);
        _ = gfx.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.ptr);
    }

    var present_mode_count: u32 = undefined;
    _ = gfx.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);
    if (present_mode_count != 0) {
        details.presentModes = try allocator.alloc(gfx.VkPresentModeKHR, present_mode_count);
        _ = gfx.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.presentModes.ptr);
    }

    return details;
}

fn chooseSwapSurfaceFormat(availableFormats: []gfx.VkSurfaceFormatKHR) gfx.VkSurfaceFormatKHR {
    for (availableFormats) |format| {
        if (format.format == gfx.VK_FORMAT_B8G8R8A8_SRGB and format.colorSpace == gfx.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return format;
        }
    }
    return availableFormats[0];
}

fn chooseSwapPresentMode(availablePresentModes: []gfx.VkPresentModeKHR) gfx.VkPresentModeKHR {
    for (availablePresentModes) |mode| {
        if (mode == gfx.VK_PRESENT_MODE_MAILBOX_KHR) {
            return mode;
        }
    }
    return gfx.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(window: *gfx.SDL_Window, capabilities: gfx.VkSurfaceCapabilitiesKHR) gfx.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    }
    var width: c_int = undefined;
    var height: c_int = undefined;
    gfx.SDL_GetWindowSize(window, &width, &height);
    return gfx.VkExtent2D{ .width = @intCast(width), .height = @intCast(height) };
}

fn populateDebugCreateInfo() gfx.VkDebugUtilsMessengerCreateInfoEXT {
    return gfx.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = gfx.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = gfx.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | gfx.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | gfx.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = gfx.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | gfx.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | gfx.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
        .pUserData = null,
    };
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
    const wanted_extensions = [_][*:0]const u8{gfx.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    var createInfo = gfx.VkDeviceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = queue_create_infos.items.ptr,
        .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
        .pEnabledFeatures = &gfx.VkPhysicalDeviceFeatures{},
        .enabledLayerCount = 0,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = &wanted_extensions,
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
    var found_device = false;
    for (device_list) |device| {
        if (isDeviceSuitable(device)) {
            physical_device = device;
            found_device = true;
        }
    }

    if (!found_device) {
        return InitError.VulkanError;
    }
    return physical_device;
}

fn isDeviceSuitable(device: gfx.VkPhysicalDevice) bool {
    var deviceProperties: gfx.VkPhysicalDeviceProperties = undefined;
    var deviceFeatures: gfx.VkPhysicalDeviceFeatures = undefined;

    gfx.vkGetPhysicalDeviceProperties(device, &deviceProperties);
    gfx.vkGetPhysicalDeviceFeatures(device, &deviceFeatures);
    if (deviceProperties.deviceType == gfx.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU and deviceFeatures.geometryShader != 0 and checkDeviceExtensionSupport(device) catch false) {
        return true;
    }
    return false;
}

fn checkDeviceExtensionSupport(device: gfx.VkPhysicalDevice) !bool {
    const needed_extensions: [1][]const u8 = .{gfx.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    var extension_count: u32 = undefined;
    _ = gfx.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);
    const available_extensions: []gfx.VkExtensionProperties = try allocator.alloc(gfx.VkExtensionProperties, extension_count);
    _ = gfx.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, available_extensions.ptr);
    var found_extensions: usize = 0;
    outer: for (needed_extensions) |extension| {
        for (available_extensions) |avail_extension| {
            const avail = std.mem.sliceTo(&avail_extension.extensionName, 0);
            if (std.ascii.eqlIgnoreCase(avail, extension)) {
                found_extensions += 1;
                continue :outer;
            }
        }
    }
    return found_extensions == needed_extensions.len;
}

fn debugCallback(messageSeverity: gfx.VkDebugUtilsMessageSeverityFlagBitsEXT, messageType: gfx.VkDebugUtilsMessageTypeFlagsEXT, pCallbackData: [*c]const gfx.VkDebugUtilsMessengerCallbackDataEXT, pUserData: ?*anyopaque) callconv(.C) gfx.VkBool32 {
    std.debug.print("validation layer: {s}\n", .{pCallbackData.*.pMessage});
    _ = messageSeverity;
    _ = messageType;
    _ = pUserData;
    return gfx.VK_FALSE;
}

fn createDebugUtilsMessengerExt(instance: gfx.VkInstance, pCreateInfo: *const gfx.VkDebugUtilsMessengerCreateInfoEXT, pDebugMessenger: *gfx.VkDebugUtilsMessengerEXT) gfx.VkResult {
    const f = gfx.vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
    const cDbgFn: gfx.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(f);
    if (cDbgFn) |dbgFn| {
        return dbgFn(instance, pCreateInfo, null, pDebugMessenger);
    }
    return gfx.VK_ERROR_EXTENSION_NOT_PRESENT;
}

fn DestroyDebugUtilMessengerExt(instance: gfx.VkInstance, callback: gfx.VkDebugUtilsMessengerEXT) void {
    const destroy_func = gfx.vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT");
    const func: gfx.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(destroy_func);
    if (func) |d_func| {
        d_func(instance, callback, null);
    }
}

fn cleanup(globals: Globals) void {
    // cleanup vulkan
    for (globals.swapChainImageViews) |view| {
        gfx.vkDestroyImageView(globals.device, view, null);
    }
    gfx.vkDestroySwapchainKHR(globals.device, globals.swapChain, null);
    gfx.vkDestroyDevice(globals.device, null);
    if (enableDebugCallback) {
        DestroyDebugUtilMessengerExt(globals.instance, globals.debugMessenger);
    }
    gfx.vkDestroySurfaceKHR(globals.instance, globals.surface, null);
    gfx.vkDestroyInstance(globals.instance, null);

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
