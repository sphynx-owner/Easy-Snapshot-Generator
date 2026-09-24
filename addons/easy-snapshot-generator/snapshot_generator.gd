@tool
class_name SnapshotGenerator
extends Node

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

var _viewport_uniform: RDUniform

var _snapshot_camera: Camera2D

var _proxies: Array[Node2D]

var _snapshot_queued: bool = false

var _advance_frame_queued: bool = false


func _notification(what: int) -> void:
	# HACK @sphynx-owner: when the snapshot generator is destroyed, any canvas item that was using
	# atlas_texture_2d would start spamming errors about batch rendering missing uniforms. To fix
	# this we ensure no dangling rids are left.
	if what == NOTIFICATION_PREDELETE:
		atlas_texture_2d.texture_rd_rid = RID()


func _ready() -> void:
	if !_rd_instance:
		_rd_instance = RenderingDeviceInstance.get_instance()
		
		_atlas_write_shader_stage = CompiledShaderStage.new(_rd_instance, load(ATLAS_WRITE_SHADER_PATH))
	
	_snapshot_viewport = SubViewport.new()
	
	_snapshot_viewport.transparent_bg = true
	
	_snapshot_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	
	_viewport_uniform = EasyRenderingUtils.get_sampler_uniform(
		_rd_instance,
		RenderingServer.texture_get_rd_texture(_snapshot_viewport.get_texture().get_rid()),
		0,
		false
	)
	
	add_child(_snapshot_viewport)
	
	_snapshot_camera = Camera2D.new()
	
	# NOTE @sphynx-owner: the cameras exist in their own tree almost, and must have their
	# interpolation mode set explicitly.
	_snapshot_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	
	_snapshot_viewport.add_child(_snapshot_camera)
	
	atlas_texture_2d = Texture2DRD.new()
	
	_update_viewport()
	_update_atlas_texture()
	_update_atlas_frames()


func _process(delta: float) -> void:
	for proxy in _proxies:
		_snapshot_viewport.remove_child(proxy)
		
		proxy.queue_free()
	
	_proxies = []
	
	if _snapshot_queued:
		_snapshot_queued = false
		
		for target in targets:
			var new_proxy: Node = target.duplicate(0)
			
			for child in new_proxy.get_children():
				new_proxy.remove_child(child)
				
				child.queue_free()
			
			_proxies.push_back(new_proxy)
			
			_snapshot_viewport.add_child(new_proxy)
			
			new_proxy.global_transform = target.global_transform
			new_proxy.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		
		_snapshot_camera.global_position = get_pivot_position()
		
		if _advance_frame_queued:
			_advance_frame_queued = false
		
		var generate_snapshot_callback: Callable = _render_thread_generate_snapshot.bind(_current_frame)
		
		
		_snapshot_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		
		await RenderingServer.frame_post_draw
		
		RenderingServer.call_on_render_thread(generate_snapshot_callback)


func queue_snapshot(advance_frame: bool = true) -> void:
	_snapshot_queued = true
	
	if advance_frame and !_advance_frame_queued:
		_advance_frame_queued = true
		_current_frame = (_current_frame + 1) % frame_count


func get_pivot_position() -> Vector2:
	return pivot_node.global_position


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


# returns the atlas frame that we rendered to
func _render_thread_generate_snapshot(current_frame: int):
	EasyRenderingUtils.dispatch_stage(
		_rd_instance,
		_atlas_write_shader_stage,
		[
			[
				EasyRenderingUtils.get_sampler_uniform(
					_rd_instance,
					RenderingServer.texture_get_rd_texture(_snapshot_viewport.get_texture().get_rid()),
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
