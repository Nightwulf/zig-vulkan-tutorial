const std = @import("std");
const gfx = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_vulkan.h");
});

// const m = @cImport({
//     @cInclude("glm/vec4.hpp");
//     @cInclude("glm/mat4x4.hpp");
// });

const max_frames_in_flight = 2;

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

const PipelineDetails = struct {
    pipeline_layout: gfx.VkPipelineLayout,
    pipeline: gfx.VkPipeline,
};

const SyncObjects = struct {
    image_available_semaphore: [max_frames_in_flight]gfx.VkSemaphore,
    render_finished_semaphore: [max_frames_in_flight]gfx.VkSemaphore,
    in_flight_fence: [max_frames_in_flight]gfx.VkFence,
};

const Globals = struct {
    window: *gfx.SDL_Window,
    instance: gfx.VkInstance,
    physical_device: gfx.VkPhysicalDevice,
    queue_indices: []QueueIndices,
    device: gfx.VkDevice,
    graphics_queue: gfx.VkQueue,
    present_queue: gfx.VkQueue,
    surface: gfx.VkSurfaceKHR,
    present_family_index: u32,
    debugMessenger: gfx.VkDebugUtilsMessengerEXT,
    swapChain: gfx.VkSwapchainKHR,
    swapChainImages: []gfx.VkImage,
    swapChainImageFormat: gfx.VkFormat,
    swapChainExtent: gfx.VkExtent2D,
    swapChainImageViews: []gfx.VkImageView,
    pipeline_layout: gfx.VkPipelineLayout,
    render_pass: gfx.VkRenderPass,
    graphics_pipeline: gfx.VkPipeline,
    frame_buffers: []gfx.VkFramebuffer,
    command_pool: gfx.VkCommandPool,
    command_buffers: [max_frames_in_flight]gfx.VkCommandBuffer,
    image_available_semaphores: [max_frames_in_flight]gfx.VkSemaphore,
    render_finished_semaphores: [max_frames_in_flight]gfx.VkSemaphore,
    in_flight_fences: [max_frames_in_flight]gfx.VkFence,
};

const enableDebugCallback: bool = true;

var frame_buffer_resized = false;

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var allocator = arena.allocator();

pub fn main() !void {
    var current_frame: usize = 0;
    var globals = try init();
    gfx.SDL_RaiseWindow(globals.window);

    var event: gfx.SDL_Event = undefined;
    var running: bool = true;
    while (running) {
        while (gfx.SDL_PollEvent(&event) == 1) {
            switch (event.type) {
                gfx.SDL_QUIT => {
                    running = false;
                },
                gfx.SDL_WINDOWEVENT_RESIZED => {
                    frame_buffer_resized = true;
                },
                else => running = true,
            }
        }
        try drawFrame(&globals, current_frame);
        current_frame = (current_frame + 1) % max_frames_in_flight;
        gfx.SDL_Delay(10);
    }
    _ = gfx.vkDeviceWaitIdle(globals.device);
    cleanup(globals);
    arena.deinit();
}

fn drawFrame(globals: *Globals, frame: usize) !void {
    _ = gfx.vkWaitForFences(globals.device, 1, &globals.in_flight_fences[frame], gfx.VK_TRUE, std.math.maxInt(u64));

    var image_index: u32 = undefined;
    var result = gfx.vkAcquireNextImageKHR(globals.device, globals.swapChain, std.math.maxInt(u64), globals.image_available_semaphores[frame], null, &image_index);

    if (result == gfx.VK_ERROR_OUT_OF_DATE_KHR) {
        try recreateSwapChain(globals);
        return;
    }
    if (result != gfx.VK_SUCCESS and result != gfx.VK_SUBOPTIMAL_KHR) {
        return InitError.VulkanError;
    }

    _ = gfx.vkResetFences(globals.device, 1, &globals.in_flight_fences[frame]);

    _ = gfx.vkResetCommandBuffer(globals.command_buffers[frame], 0);

    try recordCommandBuffer(globals.*, image_index, frame);

    const wait_semaphores = [1]gfx.VkSemaphore{globals.image_available_semaphores[frame]};
    const signal_semaphores = [1]gfx.VkSemaphore{globals.render_finished_semaphores[frame]};
    const wait_stages = [1]u32{gfx.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const submit_info = gfx.VkSubmitInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &globals.command_buffers[frame],
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores,
    };

    if (gfx.vkQueueSubmit(globals.graphics_queue, 1, &submit_info, globals.in_flight_fences[frame]) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    const swap_chains = [1]gfx.VkSwapchainKHR{globals.swapChain};
    const present_info = gfx.VkPresentInfoKHR{
        .sType = gfx.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &swap_chains,
        .pImageIndices = &image_index,
        .pResults = null,
    };
    result = gfx.vkQueuePresentKHR(globals.present_queue, &present_info);
    if (result == gfx.VK_ERROR_OUT_OF_DATE_KHR or result == gfx.VK_SUBOPTIMAL_KHR) {
        try recreateSwapChain(globals);
    } else if (result != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
}

fn init() !Globals {
    const init_rc = gfx.SDL_Init(gfx.SDL_INIT_EVERYTHING);
    if (init_rc != 0) {
        return InitError.SDLError;
    }

    const window = gfx.SDL_CreateWindow("SDL example vulkan window", 100, 100, 800, 600, gfx.SDL_WINDOW_SHOWN | gfx.SDL_WINDOW_VULKAN | gfx.SDL_WINDOW_RESIZABLE) orelse {
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

    var present_queue: gfx.VkQueue = undefined;
    gfx.vkGetDeviceQueue(device, present_idx, 0, &present_queue);

    const swapChainDetails = try querySwapChainSupport(physical_device, surface);

    if (swapChainDetails.formats.len == 0 or swapChainDetails.presentModes.len == 0) {
        return InitError.VulkanError;
    }

    const swap_chain = try createSwapChain(window, device, physical_device, surface);

    const swap_chain_images = try getSwapChainImages(device, swap_chain.swapChain);

    const swap_chain_image_views = try createImageViews(device, swap_chain, swap_chain_images);

    const render_pass = try createRenderPass(device, swap_chain.swapChainImageFormat);

    const pipeline_details = try createGraphicsPipeline(device, render_pass);

    const frame_buffers = try createFramebuffers(device, render_pass, swap_chain, swap_chain_image_views);

    const command_pool = try createCommandPool(device, queue_indices[0].idx);

    const command_buffers = try createCommandBuffers(device, command_pool);

    const sync_objects = try createSyncObjects(device);

    return Globals{
        .window = window,
        .instance = instance,
        .physical_device = physical_device,
        .queue_indices = queue_indices,
        .device = device,
        .graphics_queue = queue,
        .surface = surface,
        .present_family_index = present_idx,
        .present_queue = present_queue,
        .debugMessenger = debugMessenger,
        .swapChain = swap_chain.swapChain,
        .swapChainExtent = swap_chain.swapChainExtent,
        .swapChainImageFormat = swap_chain.swapChainImageFormat,
        .swapChainImages = swap_chain_images,
        .swapChainImageViews = swap_chain_image_views,
        .pipeline_layout = pipeline_details.pipeline_layout,
        .render_pass = render_pass,
        .graphics_pipeline = pipeline_details.pipeline,
        .frame_buffers = frame_buffers,
        .command_pool = command_pool,
        .command_buffers = command_buffers,
        .image_available_semaphores = sync_objects.image_available_semaphore,
        .render_finished_semaphores = sync_objects.render_finished_semaphore,
        .in_flight_fences = sync_objects.in_flight_fence,
    };
}

fn createSyncObjects(device: gfx.VkDevice) !SyncObjects {
    const semaphore_info = gfx.VkSemaphoreCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };

    const fence_info = gfx.VkFenceCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = gfx.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    var image_available_semaphores: [max_frames_in_flight]gfx.VkSemaphore = undefined;
    var render_finished_semaphores: [max_frames_in_flight]gfx.VkSemaphore = undefined;
    var in_flight_fences: [2]gfx.VkFence = undefined;

    var i: usize = 0;
    while (i < max_frames_in_flight) {
        if (gfx.vkCreateSemaphore(device, &semaphore_info, null, &image_available_semaphores[i]) != gfx.VK_SUCCESS or
            gfx.vkCreateSemaphore(device, &semaphore_info, null, &render_finished_semaphores[i]) != gfx.VK_SUCCESS or
            gfx.vkCreateFence(device, &fence_info, null, &in_flight_fences[i]) != gfx.VK_SUCCESS)
        {
            return InitError.VulkanError;
        }
        i += 1;
    }
    return SyncObjects{ .image_available_semaphore = image_available_semaphores, .render_finished_semaphore = render_finished_semaphores, .in_flight_fence = in_flight_fences };
}

fn recreateSwapChain(globals: *Globals) !void {
    _ = gfx.vkDeviceWaitIdle(globals.device);

    cleanupSwapChain(globals.*);

    const swap_chain_details = try createSwapChain(globals.window, globals.device, globals.physical_device, globals.surface);
    globals.swapChainExtent = swap_chain_details.swapChainExtent;
    globals.swapChain = swap_chain_details.swapChain;
    globals.swapChainImageFormat = swap_chain_details.swapChainImageFormat;
    globals.swapChainImages = try getSwapChainImages(globals.device, swap_chain_details.swapChain);
    globals.swapChainImageViews = try createImageViews(globals.device, swap_chain_details, globals.swapChainImages);
    globals.frame_buffers = try createFramebuffers(globals.device, globals.render_pass, swap_chain_details, globals.swapChainImageViews);
}

fn recordCommandBuffer(globals: Globals, image_index: u32, frame: usize) !void {
    const begin_info = gfx.VkCommandBufferBeginInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };
    if (gfx.vkBeginCommandBuffer(globals.command_buffers[frame], &begin_info) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    const clear_color = gfx.VkClearValue{
        .color = gfx.VkClearColorValue{ .float32 = [4]f32{ 0.0, 0.0, 0.0, 1.0 } },
    };

    const render_pass_info = gfx.VkRenderPassBeginInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = globals.render_pass,
        .framebuffer = globals.frame_buffers[image_index],
        .renderArea = gfx.VkRect2D{ .extent = globals.swapChainExtent, .offset = gfx.VkOffset2D{ .x = 0, .y = 0 } },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };
    gfx.vkCmdBeginRenderPass(globals.command_buffers[frame], &render_pass_info, gfx.VK_SUBPASS_CONTENTS_INLINE);

    gfx.vkCmdBindPipeline(globals.command_buffers[frame], gfx.VK_PIPELINE_BIND_POINT_GRAPHICS, globals.graphics_pipeline);

    const viewport = gfx.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(globals.swapChainExtent.width),
        .height = @floatFromInt(globals.swapChainExtent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    gfx.vkCmdSetViewport(globals.command_buffers[frame], 0, 1, &viewport);

    const scissor = gfx.VkRect2D{
        .offset = gfx.VkOffset2D{ .x = 0, .y = 0 },
        .extent = globals.swapChainExtent,
    };
    gfx.vkCmdSetScissor(globals.command_buffers[frame], 0, 1, &scissor);

    gfx.vkCmdDraw(globals.command_buffers[frame], 3, 1, 0, 0);

    gfx.vkCmdEndRenderPass(globals.command_buffers[frame]);

    if (gfx.vkEndCommandBuffer(globals.command_buffers[frame]) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
}

fn createCommandBuffers(device: gfx.VkDevice, command_pool: gfx.VkCommandPool) ![max_frames_in_flight]gfx.VkCommandBuffer {
    const alloc_info = gfx.VkCommandBufferAllocateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = gfx.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = max_frames_in_flight,
    };

    var command_buffers: [2]gfx.VkCommandBuffer = undefined;
    if (gfx.vkAllocateCommandBuffers(device, &alloc_info, &command_buffers) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return command_buffers;
}

fn createCommandPool(device: gfx.VkDevice, gfx_index: u32) !gfx.VkCommandPool {
    const pool_info = gfx.VkCommandPoolCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = gfx.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = gfx_index,
    };
    var command_pool: gfx.VkCommandPool = undefined;
    if (gfx.vkCreateCommandPool(device, &pool_info, null, &command_pool) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return command_pool;
}

fn createFramebuffers(device: gfx.VkDevice, render_pass: gfx.VkRenderPass, swap_chain_details: SwapChainDetails, swap_chain_image_views: []gfx.VkImageView) ![]gfx.VkFramebuffer {
    var swap_chain_framebuffers = try allocator.alloc(gfx.VkFramebuffer, swap_chain_image_views.len);
    var i: usize = 0;
    while (i < swap_chain_image_views.len) {
        const framebuffer_info = gfx.VkFramebufferCreateInfo{
            .sType = gfx.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &swap_chain_image_views[i],
            .width = swap_chain_details.swapChainExtent.width,
            .height = swap_chain_details.swapChainExtent.height,
            .layers = 1,
        };

        if (gfx.vkCreateFramebuffer(device, &framebuffer_info, null, &swap_chain_framebuffers[i]) != gfx.VK_SUCCESS) {
            return InitError.VulkanError;
        }
        i += 1;
    }

    return swap_chain_framebuffers;
}

fn createRenderPass(device: gfx.VkDevice, image_format: gfx.VkFormat) !gfx.VkRenderPass {
    const color_attachment = gfx.VkAttachmentDescription{
        .format = image_format,
        .samples = gfx.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = gfx.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = gfx.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = gfx.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = gfx.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = gfx.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = gfx.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref = gfx.VkAttachmentReference{
        .attachment = 0,
        .layout = gfx.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass = gfx.VkSubpassDescription{
        .pipelineBindPoint = gfx.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    };

    var dependency: gfx.VkSubpassDependency = gfx.VkSubpassDependency{
        .srcSubpass = gfx.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = gfx.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = gfx.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = gfx.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };

    var render_pass: gfx.VkRenderPass = undefined;

    const render_pass_info = gfx.VkRenderPassCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    if (gfx.vkCreateRenderPass(device, &render_pass_info, null, &render_pass) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return render_pass;
}

fn createGraphicsPipeline(device: gfx.VkDevice, render_pass: gfx.VkRenderPass) !PipelineDetails {
    const vert_shader_code = try readFile("vert.spv");
    const frag_shader_code = try readFile("frag.spv");

    const vert_shader_module = try createShaderModule(vert_shader_code, device);
    defer gfx.vkDestroyShaderModule(device, vert_shader_module, null);

    const frag_shader_module = try createShaderModule(frag_shader_code, device);
    defer gfx.vkDestroyShaderModule(device, frag_shader_module, null);

    const vert_shader_stage_info = gfx.VkPipelineShaderStageCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = gfx.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader_module,
        .pName = "main",
    };

    const frag_shader_stage_info = gfx.VkPipelineShaderStageCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = gfx.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader_module,
        .pName = "main",
    };

    const shader_stages = [_]gfx.VkPipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const dynamic_states = [_]gfx.VkDynamicState{ gfx.VK_DYNAMIC_STATE_VIEWPORT, gfx.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic_state = gfx.VkPipelineDynamicStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const vertex_input_info = gfx.VkPipelineVertexInputStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };

    const input_assembly = gfx.VkPipelineInputAssemblyStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = gfx.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = gfx.VK_FALSE,
    };

    const viewport_state = gfx.VkPipelineViewportStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    const rasterizer = gfx.VkPipelineRasterizationStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = gfx.VK_FALSE,
        .rasterizerDiscardEnable = gfx.VK_FALSE,
        .polygonMode = gfx.VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0,
        .cullMode = gfx.VK_CULL_MODE_BACK_BIT,
        .frontFace = gfx.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable = gfx.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
    };

    const multisampling = gfx.VkPipelineMultisampleStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = gfx.VK_FALSE,
        .rasterizationSamples = gfx.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = gfx.VK_FALSE,
        .alphaToOneEnable = gfx.VK_FALSE,
    };

    const color_blend_attachment = gfx.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = gfx.VK_COLOR_COMPONENT_R_BIT | gfx.VK_COLOR_COMPONENT_G_BIT | gfx.VK_COLOR_COMPONENT_B_BIT | gfx.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = gfx.VK_FALSE,
        .srcColorBlendFactor = gfx.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = gfx.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = gfx.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = gfx.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = gfx.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = gfx.VK_BLEND_OP_ADD,
    };

    const color_blending = gfx.VkPipelineColorBlendStateCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = gfx.VK_FALSE,
        .logicOp = gfx.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
    };

    const pipeline_layout_info = gfx.VkPipelineLayoutCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 0,
        .pPushConstantRanges = null,
    };

    var pipeline_layout: gfx.VkPipelineLayout = undefined;
    if (gfx.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    const pipeline_info = gfx.VkGraphicsPipelineCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &shader_stages,
        .pVertexInputState = &vertex_input_info,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var graphics_pipeline: gfx.VkPipeline = undefined;
    if (gfx.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &graphics_pipeline) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }

    return PipelineDetails{ .pipeline = graphics_pipeline, .pipeline_layout = pipeline_layout };
}

fn createShaderModule(shader_code: []align(4) u8, device: gfx.VkDevice) !gfx.VkShaderModule {
    const create_info = gfx.VkShaderModuleCreateInfo{
        .sType = gfx.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = shader_code.len,
        .pCode = @ptrCast(shader_code.ptr),
    };
    var shader_module: gfx.VkShaderModule = undefined;
    if (gfx.vkCreateShaderModule(device, &create_info, null, &shader_module) != gfx.VK_SUCCESS) {
        return InitError.VulkanError;
    }
    return shader_module;
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

fn cleanupSwapChain(globals: Globals) void {
    for (globals.frame_buffers) |framebuffer| {
        gfx.vkDestroyFramebuffer(globals.device, framebuffer, null);
    }
    for (globals.swapChainImageViews) |image_view| {
        gfx.vkDestroyImageView(globals.device, image_view, null);
    }

    gfx.vkDestroySwapchainKHR(globals.device, globals.swapChain, null);
}

fn cleanup(globals: Globals) void {
    // cleanup vulkan
    cleanupSwapChain(globals);

    gfx.vkDestroyPipeline(globals.device, globals.graphics_pipeline, null);
    gfx.vkDestroyPipelineLayout(globals.device, globals.pipeline_layout, null);

    gfx.vkDestroyRenderPass(globals.device, globals.render_pass, null);

    var i: usize = 0;
    while (i < max_frames_in_flight) {
        gfx.vkDestroySemaphore(globals.device, globals.image_available_semaphores[i], null);
        gfx.vkDestroySemaphore(globals.device, globals.render_finished_semaphores[i], null);
        gfx.vkDestroyFence(globals.device, globals.in_flight_fences[i], null);
        i += 1;
    }

    gfx.vkDestroyCommandPool(globals.device, globals.command_pool, null);

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

fn readFile(filename: []const u8) ![]align(4) u8 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const current = try std.posix.getcwd(&path);
    const absolute_path: []u8 = try std.mem.join(allocator, "/", &[_][]const u8{ current, filename });
    std.debug.print("{s}\n", .{absolute_path});
    const file = try std.fs.openFileAbsolute(absolute_path, std.fs.File.OpenFlags{ .mode = .read_only });
    const stat = try file.stat();
    const outbuf: []align(4) u8 = try allocator.allocWithOptions(u8, stat.size, std.mem.Alignment.@"4", null);
    _ = try file.readAll(outbuf);
    file.close();
    return outbuf;
}
