const std = @import("std");
const core = @import("mach-core");
const gpu = core.gpu;
const math = @import("mach").math;
const math_helpers = @import("math_helpers.zig");
const zigimg = @import("zigimg");
const Atlas = @import("atlas.zig");

pub const FontVertex = extern struct {
    pos: math.Vec2,
    tex_coord: math.Vec2,
    col: math.Vec4,
};

font_pipeline: *gpu.RenderPipeline,
font_texture_bind_group: *gpu.BindGroup,
projection_matrix_bind_group: *gpu.BindGroup,
projection_matrix_buffer: *gpu.Buffer,
vertex_buffer: *gpu.Buffer,
atlas: std.json.Parsed(Atlas),
codepoint_mapping: std.AutoHashMap(u32, Atlas.Bounds),

const Self = @This();

pub fn getTexUVsFromAtlas(self: Self, codepoint: u32) Atlas.Bounds {
    std.debug.print("codepoint: {}\n", .{codepoint});
    if (self.codepoint_mapping.get(codepoint)) |bounds| {
        return bounds;
    }
    unreachable;
}

pub fn getTexSizeFromAtlas(self: Self, codepoint: u32) math.Vec2 {
    if (self.codepoint_mapping.get(codepoint)) |bounds| {
        return math.vec2(
            (bounds.right - bounds.left) * @as(f32, @floatFromInt(self.atlas.value.atlas.width)),
            (bounds.bottom - bounds.top) * @as(f32, @floatFromInt(self.atlas.value.atlas.height)),
        );
    }
    std.debug.print("getTexSizeFromAtlas\n", .{});
    unreachable;
}

pub fn init() !Self {
    std.debug.print("Gfx init: Starting\n", .{});
    const atlas = try Atlas.readAtlas(core.allocator);
    std.debug.print("allocation\n", .{});


    var codepoint_mapping = std.AutoHashMap(u32, Atlas.Bounds).init(core.allocator);
    std.debug.print("codepoint_mapping\n", .{});
    for (atlas.value.glyphs) |glyph| {
        if (glyph.atlasBounds) |bounds| {
            try codepoint_mapping.put(glyph.unicode, .{
                .top = 1 - bounds.top / @as(f32, @floatFromInt(atlas.value.atlas.height)),
                .bottom = 1 - bounds.bottom / @as(f32, @floatFromInt(atlas.value.atlas.height)),
                .left = bounds.left / @as(f32, @floatFromInt(atlas.value.atlas.width)),
                .right = bounds.right / @as(f32, @floatFromInt(atlas.value.atlas.width)),
            });
        }
    }
        std.debug.print("after glyph for loop\n", .{});

    var img_stream = zigimg.Image.Stream{ .const_buffer = .{ .pos = 0, .buffer = @embedFile("atlas.png") } };
    std.debug.print("img_stream\n", .{});
    var image = try zigimg.png.load(&img_stream, core.allocator, .{ .temp_allocator = core.allocator });
    std.debug.print("var image\n", .{});
    defer image.deinit();
    std.debug.print("defer image deinit\n", .{});
    var tex = core.device.createTexture(&gpu.Texture.Descriptor.init(.{
        .label = "sdf",
        .usage = .{ .copy_dst = true, .texture_binding = true },
        .size = .{
            .width = @intCast(image.width),
            .height = @intCast(image.height),
        },
        .format = .rgba8_unorm,
        .view_formats = &.{},
    }));
    defer tex.release();
    std.debug.print("defer text release\n", .{});

    switch (image.pixels) {
        .rgba32 => |pixels| {
            core.queue.writeTexture(
                &gpu.ImageCopyTexture{
                    .texture = tex,
                },
                &gpu.Texture.DataLayout{
                    .rows_per_image = @intCast(image.height),
                    .bytes_per_row = @intCast(4 * image.width),
                },
                &gpu.Extent3D{
                    .height = @intCast(image.height),
                    .width = @intCast(image.width),
                },
                pixels,
            );
        },
        .rgb24 => |pixels| {
            const out = try zigimg.color.PixelStorage.init(core.allocator, .rgba32, pixels.len);
            defer out.deinit(core.allocator);
            var i: usize = 0;
            while (i < pixels.len) : (i += 1) {
                out.rgba32[i] = zigimg.color.Rgba32{ .r = pixels[i].r, .g = pixels[i].g, .b = pixels[i].b, .a = 255 };
            }

            core.queue.writeTexture(
                &gpu.ImageCopyTexture{
                    .texture = tex,
                },
                &gpu.Texture.DataLayout{
                    .rows_per_image = @intCast(image.height),
                    .bytes_per_row = @intCast(4 * image.width),
                },
                &gpu.Extent3D{
                    .height = @intCast(image.height),
                    .width = @intCast(image.width),
                },
                out.rgba32,
            );
        },
        else => {
            std.log.info("SHIT {s}", .{@tagName(image.pixels)});
        },
    }

    var tex_view = tex.createView(&gpu.TextureView.Descriptor{
        .format = .rgba8_unorm,
        .array_layer_count = 1,
        .dimension = .dimension_2d,
        .label = "sdf_view",
    });
    defer tex_view.release();
    std.debug.print("tex_view release\n", .{});

    var sampler = core.device.createSampler(&gpu.Sampler.Descriptor{
        .label = "sampler",
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_filter = .linear,
    });
    defer sampler.release();
    std.debug.print("sampler\n", .{});

    var projection_matrix_buffer = core.device.createBuffer(&gpu.Buffer.Descriptor{
        .label = "projection matrix",
        .size = @sizeOf(math.Mat4x4),
        .usage = .{
            .copy_dst = true,
            .uniform = true,
        },
    });
    defer projection_matrix_buffer.release();

    var projection_matrix_bind_group_layout = core.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .label = "projection matrix bind group layout",
        .entries = &[_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.buffer(0, .{ .vertex = true }, .uniform, false, @sizeOf(math.Mat4x4)),
        },
    }));
    defer projection_matrix_bind_group_layout.release();

    var font_texture_bind_group_layout = core.device.createBindGroupLayout(&gpu.BindGroupLayout.Descriptor.init(.{
        .label = "font bind group layout",
        .entries = &[_]gpu.BindGroupLayout.Entry{
            gpu.BindGroupLayout.Entry.texture(0, .{ .fragment = true }, .float, .dimension_2d, false),
            gpu.BindGroupLayout.Entry.sampler(1, .{ .fragment = true }, .filtering),
        },
    }));
    defer font_texture_bind_group_layout.release();

    const self: Self = .{
        .vertex_buffer = blk: {
            const vertex_buffer = core.device.createBuffer(&gpu.Buffer.Descriptor{
                .label = "vertex buffer",
                .size = @sizeOf(FontVertex) * 6,
                .usage = .{
                    .vertex = true,
                    .copy_dst = true,
                },
            });
            const image_size = 64 * 16;
            core.queue.writeBuffer(vertex_buffer, 0, &[_]FontVertex{
                FontVertex{
                    .pos = math.vec2(0, 0),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(0, 0),
                },
                FontVertex{
                    .pos = math.vec2(image_size, image_size),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(1, 1),
                },
                FontVertex{
                    .pos = math.vec2(0, image_size),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(0, 1),
                },
                FontVertex{
                    .pos = math.vec2(0, 0),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(0, 0),
                },
                FontVertex{
                    .pos = math.vec2(image_size, image_size),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(1, 1),
                },
                FontVertex{
                    .pos = math.vec2(image_size, 0),
                    .col = math.vec4(1, 1, 1, 1),
                    .tex_coord = math.vec2(1, 0),
                },
            });

            break :blk vertex_buffer;
        },
        .projection_matrix_buffer = projection_matrix_buffer,
        .projection_matrix_bind_group = blk: {
            break :blk core.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
                .label = "projection matrix bind group",
                .layout = projection_matrix_bind_group_layout,
                .entries = &[_]gpu.BindGroup.Entry{
                    gpu.BindGroup.Entry.buffer(0, projection_matrix_buffer, 0, @sizeOf(math.Mat4x4)),
                },
            }));
        },
        .font_texture_bind_group = blk: {
            break :blk core.device.createBindGroup(&gpu.BindGroup.Descriptor.init(.{
                .label = "font bind group",
                .layout = font_texture_bind_group_layout,
                .entries = &[_]gpu.BindGroup.Entry{
                    gpu.BindGroup.Entry.textureView(0, tex_view),
                    gpu.BindGroup.Entry.sampler(1, sampler),
                },
            }));
        },
        .font_pipeline = blk: {
            const shader_module = core.device.createShaderModuleWGSL("font.wgsl", @embedFile("font.wgsl"));
            defer shader_module.release();

            var pipeline_layout = core.device.createPipelineLayout(&gpu.PipelineLayout.Descriptor.init(.{
                .label = "font pipeline layout",
                .bind_group_layouts = &[_]*gpu.BindGroupLayout{
                    projection_matrix_bind_group_layout,
                    font_texture_bind_group_layout,
                },
            }));
            defer pipeline_layout.release();

            const color_target = gpu.ColorTargetState{
                .format = core.descriptor.format,
                .blend = &gpu.BlendState{
                    .alpha = .{
                        .src_factor = .one,
                        .dst_factor = .one_minus_src_alpha,
                        .operation = .add,
                    },
                    .color = .{
                        .src_factor = .src_alpha,
                        .dst_factor = .one_minus_src_alpha,
                        .operation = .add,
                    },
                },
                .write_mask = gpu.ColorWriteMaskFlags.all,
            };
            const fragment = gpu.FragmentState.init(.{
                .module = shader_module,
                .entry_point = "frag_main",
                .targets = &.{color_target},
            });
            const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
                .fragment = &fragment,
                .vertex = gpu.VertexState{
                    .module = shader_module,
                    .entry_point = "vertex_main",
                    .buffers = @ptrCast(&[_]gpu.VertexBufferLayout{
                        gpu.VertexBufferLayout.init(.{
                            .array_stride = @sizeOf(math.Vec2),
                            // .array_stride = @sizeOf(FontVertex),
                            .attributes = &.{
                                gpu.VertexAttribute{
                                    .format = .float32x2,
                                    .offset = 0,
                                    // .offset = @offsetOf(FontVertex, "pos"),
                                    .shader_location = 0,
                                },
                            },
                        }),
                        gpu.VertexBufferLayout.init(
                            .{
                                .array_stride = @sizeOf(math.Vec2),
                                // .array_stride = @sizeOf(FontVertex),
                                .attributes = &.{
                                    gpu.VertexAttribute{
                                        .format = .float32x2,
                                        .offset = 0,
                                        // .offset = @offsetOf(FontVertex, "tex_coord"),
                                        .shader_location = 1,
                                    },
                                },
                            },
                        ),
                        gpu.VertexBufferLayout.init(
                            .{
                                .array_stride = @sizeOf(math.Vec4),
                                // .array_stride = @sizeOf(FontVertex),
                                .attributes = &.{
                                    gpu.VertexAttribute{
                                        .format = .float32x4,
                                        .offset = 0,
                                        // .offset = @offsetOf(FontVertex, "col"),
                                        .shader_location = 2,
                                    },
                                },
                            },
                        ),
                    }),
                    .buffer_count = 3,
                },
                .layout = pipeline_layout,
            };
            break :blk core.device.createRenderPipeline(&pipeline_descriptor);
        },
        .atlas = atlas,
        .codepoint_mapping = codepoint_mapping,
    };

    //TODO: is this fine? shouldnt i be using framebuffer size?
    try self.updateProjectionMatrix(core.size());

    return self;
}

pub fn updateProjectionMatrix(self: Self, size: core.Size) !void {
    core.queue.writeBuffer(
        self.projection_matrix_buffer,
        0,
        &[_]math.Mat4x4{
            math_helpers.orthographicOffCenter(
                0,
                @floatFromInt(size.width),
                0,
                @floatFromInt(size.height),
                0,
                1,
            ).transpose(),
        },
    );
}

pub fn deinit(self: *Self) void {
    self.font_pipeline.release();
    self.font_texture_bind_group.release();
    self.vertex_buffer.release();
    self.atlas.deinit();
    self.codepoint_mapping.deinit();
}
