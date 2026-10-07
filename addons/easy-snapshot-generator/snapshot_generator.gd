@tool
class_name SnapshotGenerator
extends Node

const PAST_STATE_META_KEY: StringName = &"snapshot_generator_target_past_state"

const SNAPSHOT_VISIBILITY_LAYER_BIT: int = 2

const ATLAS_WRITE_SHADER_PATH: String = "res://addons/easy-snapshot-generator/compute/atlas_write.glsl"

@export var targets: Array[Node2D]

@export var pivot_node: Node2D:
	get():
		if pivot_node:
			return pivot_node
		
		if targets.is_empty():
			return null
		
		return targets[0]

@export var atlas_dimensions: Vector2i = Vector2i(1, 1):
	set(value):
		var clamped_value: Vector2i = Vector2i(max(value.x, 1), max(value.y, 1))
		
		if atlas_dimensions == clamped_value:
			return
		
		atlas_dimensions = clamped_value
		
		_atlas_dimensions_updated()

## increases the resolution of the snapshot without changing the
## global rect size
@export var snapshot_resolution_scale: float = 1.0:
	set(value):
		if snapshot_resolution_scale == value:
			return
		
		snapshot_resolution_scale = value
		
		_snapshot_rect_updated()

## The global rect within which elements are rendered to the snapshot
@export var snapshot_rect: Rect2i = Rect2i(-256, -256, 512, 512):
	set(value):
		if snapshot_rect == value:
			return
		
		snapshot_rect = value
		
		_snapshot_rect_updated()

static var _rd_instance: RenderingDeviceInstance

static var _atlas_write_shader_stage: CompiledShaderStage

var frame_count: int:
	get():
		return atlas_dimensions.x * atlas_dimensions.y

var snapshot_size: Vector2i:
	get():
		return Vector2i(
			float(snapshot_rect.size.x) * snapshot_resolution_scale,
			float(snapshot_rect.size.y) * snapshot_resolution_scale
		)

var atlas_texture_size: Vector2i:
	get():
		return snapshot_size * atlas_dimensions

var atlas_texture_2d: Texture2DRD

var _atlas_texture: RenderingDeviceTexture

var _atlas_texture_uniform: RDUniform

var _current_frame: int = 0

var _snapshot_viewport: SubViewport

var _snapshot_camera: Camera2D

var _snapshot_queued: bool = false

var _advance_frame_queued: bool = false

static var scenario: RID

static var compositor: RID

static var socket_compositor_effect: SocketCompositorEffect

static var environment: RID

static var currently_active_generators: Array[SnapshotGenerator]

static var current_generator_index: int


static func _static_init() -> void:
	socket_compositor_effect = SocketCompositorEffect.new()
	
	socket_compositor_effect.effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	
	compositor = RenderingServer.compositor_create()
	
	RenderingServer.compositor_set_compositor_effects(compositor, [socket_compositor_effect.get_rid()])
	
	scenario = RenderingServer.scenario_create()
	
	RenderingServer.scenario_set_compositor(scenario, compositor)
	
	environment = RenderingServer.environment_create()
	
	RenderingServer.environment_set_background(environment, RenderingServer.ENV_BG_CANVAS)
	
	RenderingServer.scenario_set_environment(scenario, environment)


static func _pre_draw_callback() -> void:
	currently_active_generators.clear()
	
	current_generator_index = 0
	
	var all_snapshot_generators: Array[SnapshotGenerator] = _collect_all_snapshot_generators()
	
	for snapshot_generator in all_snapshot_generators:
		if snapshot_generator._snapshot_viewport.render_target_update_mode == SubViewport.UPDATE_ONCE:
			currently_active_generators.append(snapshot_generator)
	
	_queue_next_snapshot_callbacks()


static func _render_callback(
	render_size: Vector2i,
	rd_instance: RenderingDeviceInstance,
	scene_buffers: RenderSceneBuffersRD,
	scene_data: RenderSceneDataRD,
	snapshot_generator: SnapshotGenerator
) -> void:
	assert(
		scene_buffers.get_render_target() == RenderingServer.viewport_get_render_target(snapshot_generator._snapshot_viewport.get_Viewport_rid()),
		"something went wrong, the current render target of the compositor callback does not match the predicted snapshot"
	)
	
	snapshot_generator._render(render_size, rd_instance, scene_buffers, scene_data)
	
	snapshot_generator._post_render_teardown()
	
	_queue_next_snapshot_callbacks()


static func _queue_next_snapshot_callbacks() -> void:
	if current_generator_index < currently_active_generators.size():
		var next_snapshot_generator: SnapshotGenerator = currently_active_generators[current_generator_index]
		
		next_snapshot_generator._pre_render_setup()
		
		socket_compositor_effect.render_callback.connect(_render_callback.bind(next_snapshot_generator), CONNECT_ONE_SHOT)
		
		current_generator_index += 1


static func _collect_all_snapshot_generators(root: Node = Engine.get_main_loop().root) -> Array[SnapshotGenerator]:
	var ret: Array[SnapshotGenerator]
	
	for child in root.get_children():
		ret.append_array(_collect_all_snapshot_generators(child))
	
	if root is SnapshotGenerator:
		ret = [root]
	
	return ret


func _notification(what: int) -> void:
	# HACK @sphynx-owner: when the snapshot generator is destroyed, any canvas item that was using
	# atlas_texture_2d would start spamming errors about batch rendering missing uniforms. To fix
	# this we ensure no dangling rids are left.
	if what == NOTIFICATION_PREDELETE:
		atlas_texture_2d.texture_rd_rid = RID()


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	
	if Engine.is_editor_hint():
		var new_gizmo: SnapshotRectGizmo = SnapshotRectGizmo.new()
		
		new_gizmo.node = self
		
		add_child(new_gizmo)
	
	if !_rd_instance:
		_rd_instance = RenderingDeviceInstance.get_instance()
		
		_atlas_write_shader_stage = CompiledShaderStage.new(_rd_instance, load(ATLAS_WRITE_SHADER_PATH))
	
	_snapshot_viewport = SubViewport.new()
	
	_snapshot_viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	
	_snapshot_viewport.transparent_bg = true
	
	_snapshot_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	
	_snapshot_viewport.canvas_cull_mask = 1 << (2 - 1)
	
	_snapshot_viewport.world_2d = get_viewport().world_2d
	
	get_viewport().canvas_cull_mask = ~(1 << (2 - 1))
	
	add_child(_snapshot_viewport)
	
	RenderingServer.viewport_set_scenario(_snapshot_viewport.get_viewport_rid(), scenario)
	
	_snapshot_camera = Camera2D.new()
	
	# NOTE @sphynx-owner: the cameras exist in their own tree almost, and must have their
	# interpolation mode set explicitly.
	_snapshot_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	
	_snapshot_viewport.add_child(_snapshot_camera)
	
	_snapshot_camera.make_current()
	
	atlas_texture_2d = Texture2DRD.new()
	
	_update_viewport()
	_update_atlas_texture()
	_update_atlas_frames()


func _process(delta: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	
	if _snapshot_queued:
		_snapshot_queued = false
		
		_snapshot_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		
		if !RenderingServer.frame_pre_draw.is_connected(_pre_draw_callback):
			RenderingServer.frame_pre_draw.connect(_pre_draw_callback)


func queue_snapshot(advance_frame: bool = true) -> void:
	_snapshot_queued = true
	
	if advance_frame:
		_advance_frame_queued = true


func get_pivot_position() -> Vector2:
	if !pivot_node:
		return Vector2.ZERO
	
	return pivot_node.global_position


func get_naive_current_frame(offset: int = 0) -> int:
	return (_current_frame + offset + frame_count) % frame_count


func get_current_frame(offset: int = 0) -> int:
	return (_current_frame + offset + int(_advance_frame_queued) + frame_count) % frame_count


func get_latest_frame() -> int:
	return get_current_frame(-1)


func _atlas_dimensions_updated() -> void:
	_update_atlas_texture()
	_update_atlas_frames()


func _snapshot_rect_updated() -> void:
	_update_viewport()
	_update_atlas_texture()
	_update_atlas_frames()


# Here we update the dimensions of the viewports and textures
func _update_viewport() -> void:
	if !is_node_ready():
		return
	
	_snapshot_viewport.size = snapshot_size
	
	_snapshot_camera.zoom = Vector2(snapshot_resolution_scale, snapshot_resolution_scale)


func _update_atlas_texture() -> void:
	if !is_node_ready():
		return
	
	_atlas_texture = EasyRenderingUtils.create_texture(
		_rd_instance,
		atlas_texture_size,
		[],
		EasyRenderingUtils.DEFAULT_TEXTURE_DATA_FORMAT,
		EasyRenderingUtils.DEFAULT_TEXTURE_USAGE_BITS | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	
	_atlas_texture_uniform = EasyRenderingUtils.get_image_uniform(_atlas_texture.texture, 1)
	
	# HACK @sphynx-owner: fixes invalid rid freeing errors
	atlas_texture_2d.texture_rd_rid = RID()
	
	atlas_texture_2d.texture_rd_rid = _atlas_texture.texture


func _update_atlas_frames():
	if !is_node_ready():
		return
	
	if _current_frame >= frame_count:
		_current_frame = 0


func _pre_render_setup() -> void:
	for target in targets:
		if !target:
			continue
		
		target.set_meta(PAST_STATE_META_KEY, {
			"visibility_layer": target.visibility_layer,
			"top_level": target.top_level,
			"global_transform": target.global_transform,
			"physics_interpolation_mode": target.physics_interpolation_mode
		})
		
		target.set_visibility_layer_bit(SNAPSHOT_VISIBILITY_LAYER_BIT, true)
		
		var temp_global_transform: Transform2D = target.global_transform
		
		target.top_level = true
		
		target.global_transform = temp_global_transform
		
		# HACK @sphynx-owner: For some reason in the editor the camera position does not update no matter what
		# I try. I don't know what the solution is for it but this is the workaround. If the camera won't come
		# to the target, the targets would come to the camera.
		if Engine.is_editor_hint():
			target.global_position -= get_pivot_position()
			target.global_position += Vector2(snapshot_rect.size) / 2.0 - Vector2(snapshot_rect.get_center())
			target.global_position *= snapshot_resolution_scale
			target.scale *= snapshot_resolution_scale
		
		target.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	
	_snapshot_camera.global_position = get_pivot_position() + Vector2(snapshot_rect.get_center())


func _render(
	render_size: Vector2i,
	rd_instance: RenderingDeviceInstance,
	scene_buffers: RenderSceneBuffersRD,
	scene_data: RenderSceneDataRD
) -> void:
	_render_thread_generate_snapshot(render_size, scene_buffers, _current_frame)
	
	if _advance_frame_queued:
		_advance_frame_queued = false
		_current_frame = (_current_frame + 1 + frame_count) % frame_count


func _post_render_teardown() -> void:
	for target in targets:
		if !target:
			continue
		
		var past_state: Dictionary = target.get_meta(PAST_STATE_META_KEY)
		
		target.remove_meta(PAST_STATE_META_KEY)
		
		for state in past_state.keys():
			target.set(state, past_state[state])


# returns the atlas frame that we rendered to
func _render_thread_generate_snapshot(render_size: Vector2i, scene_buffers: RenderSceneBuffersRD, current_frame: int):
	EasyRenderingUtils.dispatch_stage(
		_rd_instance,
		_atlas_write_shader_stage,
		[
			[
				EasyRenderingUtils.get_sampler_uniform(
					_rd_instance,
					scene_buffers.get_color_layer(0, false),
					0,
					false
				),
				_atlas_texture_uniform
			]
		],
		EasyRenderingUtils.get_push_constants([], [
			atlas_dimensions.x,
			atlas_dimensions.y,
			current_frame,
			0,
		]),
		EasyRenderingUtils.get_groups_count(Vector3i(snapshot_size.x, snapshot_size.y, 1), Vector3i(16, 16, 1))
	)
