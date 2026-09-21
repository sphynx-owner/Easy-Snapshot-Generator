class_name SnapshotGenerator
extends Node

@export var target: Node2D:
	set(value):
		target = value
		
		_update_target()

@export var follow_target := true

# TODO: Replace this with a custom property wrapper to a quick search
# dictionary for efficient add and remove operations at runtime
## NOTE: Do not modify this array from code, instead use the access functions
@export var subjects: Array[Node2D]:
	set(value):
		if subjects == value:
			return
		subjects = value
		
		_update_subject_list()

@export var enabled := true:
	set(value):
		if enabled == value:
			return

		enabled = value
		
		_update_update_mode()

## This enables refreshing of the current snapshot.
## The snapshot atlas is a buffer that contains multiple snapshots 
## to store the history of past snapshots for things like trail particles
## in an accessible texture. If we have something like the stretchy trail, however,
## which grows at the head of it before detaching, we may want it to still dynamically
## update with the latest visual state of the target, meaning we want to be able to refresh
## the very current snapshot, instead of moving to the next snapshot slot in the atlas.
## This also implicitly sets the update mode of the viewports to always, so that there is 
## less overhead than if we were to use the update once mode every frame. 
@export var allow_current_snapshot_refresh := true:
	set(value):
		if allow_current_snapshot_refresh == value:
			return
		
		allow_current_snapshot_refresh = value
		
		_update_update_mode()

@export var atlas_dimensions := Vector2i(1, 1):
	set(value):
		var clamped_value := Vector2i(max(value.x, 1), max(value.y, 1))

		if atlas_dimensions == clamped_value:
			return

		atlas_dimensions = clamped_value

		_update_atlas_frames()

var _current_snapshot_transform_tracker: SnapshotTransformTracker:
	set(value):
		if _current_snapshot_transform_tracker and \
		_current_snapshot_transform_tracker.deleting.is_connected(_on_transform_tracker_deleting):
			_current_snapshot_transform_tracker.deleting.disconnect(_on_transform_tracker_deleting)
		
		_current_snapshot_transform_tracker = value
		
		if _current_snapshot_transform_tracker and \
		!_current_snapshot_transform_tracker.deleting.is_connected(_on_transform_tracker_deleting):
			_current_snapshot_transform_tracker.deleting.connect(_on_transform_tracker_deleting)

var _total_frames := 1

var _current_frame := 0

var _first_sub_viewport: SubViewport

var _first_sub_viewport_camera: Camera2D

var _second_sub_viewport: SubViewport

var _second_sub_viewport_camera: Camera2D

# Compute stuff
static var compute_disabled = false
static var headless: bool = false
static var _global_rd: RenderingDevice
static var _shader_file: RDShaderFile
static var _shader_spirv: RDShaderSPIRV
static var _shader: RID
static var _pipeline: RID
static var _sampler_state: RDSamplerState
static var _nearest_sampler: RID

var _uniform_set: RID
var _first_viewport_uniform: RDUniform
var _second_viewport_uniform: RDUniform
var _snapshot_texture_rid: RID
var _snapshot_format: RDTextureFormat
var _snapshot_texture_uniform: RDUniform

## This is the resulting snapshot texture, use it
## wherever neceassary
var snapshot_texture: SnapshotTexture

## This is the last frame that was rendered to
## in the texture atlas
var latest_frame_rendered := 0

## increases the resolution of the snapshot without changing the
## global rect size
@export var snapshot_resolution_scale := 1.0:
	set(value):
		if snapshot_resolution_scale == value:
			return

		snapshot_resolution_scale = value

		if _first_sub_viewport:
			_update_viewports_and_cameras()

## The global rect within which elements are rendered to the snapshot
@export var snapshot_rect := Rect2i(-256, -256, 512, 512):
	set(value):
		if snapshot_rect == value:
			return

		snapshot_rect = value

		if _first_sub_viewport:
			_update_viewports_and_cameras()

var _snapshot_rect_dirty := false
var _snapshot_atlas_dirty := false
var _uniform_set_dirty := false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if !headless:
			if _uniform_set.is_valid():
				_global_rd.free_rid(_uniform_set)
			if _snapshot_texture_rid.is_valid():
				_global_rd.free_rid(_snapshot_texture_rid)

		SnapshotManager.unsubscribe_snapshot(self)
		
		if _current_snapshot_transform_tracker:
			_current_snapshot_transform_tracker.queue_free()


static func _static_init() -> void:
	if ProjectSettings.get_setting("rendering/renderer/rendering_method") == "gl_compatibility":
		compute_disabled = true
		return
	
	headless = DisplayServer.get_name() == "headless"
	
	if headless:
		return
	
	# Here we generate all the globally shared resources
	# that would stay the same across the entire runtime
	_global_rd = RenderingServer.get_rendering_device()

	var shader_string: String = (
		preload("res://addons/easy-snapshot-generator/compute/filter_shader_file.tres")
		.shader_string
	)

	var shader_source: RDShaderSource = RDShaderSource.new()

	shader_source.source_compute = shader_string

	_shader_spirv = _global_rd.shader_compile_spirv_from_source(shader_source, false)

	if !_shader_spirv.compile_error_compute.is_empty():
		printerr(_shader_spirv.compile_error_compute)
		return

	_shader = _global_rd.shader_create_from_spirv(_shader_spirv)

	_pipeline = _global_rd.compute_pipeline_create(_shader)

	_sampler_state = RDSamplerState.new()
	_sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT

	_nearest_sampler = _global_rd.sampler_create(_sampler_state)


func _init():
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	
	# Here we can generate all the snapshot local resources that will stay
	# concurrent during its lifetime
	_first_viewport_uniform = RDUniform.new()
	_first_viewport_uniform.binding = 0
	_first_viewport_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE

	_second_viewport_uniform = RDUniform.new()
	_second_viewport_uniform.binding = 1
	_second_viewport_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE

	_snapshot_format = RDTextureFormat.new()
	_snapshot_format.depth = 1
	_snapshot_format.array_layers = 1
	_snapshot_format.mipmaps = 1

	_snapshot_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D

	_snapshot_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT

	_snapshot_format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT
	)

	_snapshot_texture_uniform = RDUniform.new()
	_snapshot_texture_uniform.binding = 2
	_snapshot_texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE

	snapshot_texture = SnapshotTexture.new()

	SnapshotManager.subscribe_snapshot(self)


func _ready() -> void:
	# We create two viewports and two cameras.
	# One viewport would render the scene as usual, and the other would render the
	# scene with the subjects invisible. The change would be detected and used as a mask
	# for the final snapshot to be generated with.
	_second_sub_viewport = SubViewport.new()
	_first_sub_viewport = SubViewport.new()

	_first_sub_viewport.transparent_bg = true
	_second_sub_viewport.transparent_bg = true

	add_child(_first_sub_viewport)
	add_child(_second_sub_viewport)

	_first_sub_viewport_camera = Camera2D.new()
	_second_sub_viewport_camera = Camera2D.new()
	
	# IMPORTANT, the cameras exist in their own tree almost, and must have their
	# interpolation mode set explicitly.
	_first_sub_viewport_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_second_sub_viewport_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	
	
	_first_sub_viewport.add_child(_first_sub_viewport_camera)
	_second_sub_viewport.add_child(_second_sub_viewport_camera)

	_first_sub_viewport.world_2d = get_viewport().world_2d
	_second_sub_viewport.world_2d = get_viewport().world_2d

	# The other dirty variables would be set from these functions
	_update_viewports_and_cameras()
	_update_atlas_frames()
	_update_update_mode()
	_update_target()

	_uniform_set_dirty = true


func _process(delta: float) -> void:
	if not target:
		return

	if follow_target:
		_first_sub_viewport_camera.global_position = get_target_position()
		_second_sub_viewport_camera.global_position = get_target_position()


func _update_target() -> void:
	if !is_node_ready():
		return
	
	if _current_snapshot_transform_tracker:
		_current_snapshot_transform_tracker.queue_free()
	
	_current_snapshot_transform_tracker = null
	
	if !target:
		return
	
	_current_snapshot_transform_tracker = SnapshotTransformTracker.new()
	target.add_child(_current_snapshot_transform_tracker, false, Node.INTERNAL_MODE_FRONT)


func get_target_position() -> Vector2:
	return _current_snapshot_transform_tracker.get_tracked_global_position()


func _on_transform_tracker_deleting() -> void:
	target = null


func enable():
	enabled = true


func disable():
	enabled = false


func _set_update_mode_always() -> void:
	_first_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_second_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	
	_first_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_second_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS


func _set_update_mode_never() -> void:
	_first_sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_second_sub_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	
	_first_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	_second_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER


func _set_update_mode_once() -> void:
	_first_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_second_sub_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	
	_first_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE
	_second_sub_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ONCE


# Here we update the dimensions of the viewports and textures
func _update_viewports_and_cameras():
	# This makes sure that we keep the rect size consistent regardless
	# of resolution scale
	var sub_viewport_size: Vector2i = Vector2i(
		float(snapshot_rect.size.x) * snapshot_resolution_scale,
		float(snapshot_rect.size.y) * snapshot_resolution_scale
	)

	# Must be done this way, otherwise getting "Attempting to free invalid RID" errors.
	if !headless and _uniform_set.is_valid():
		_global_rd.free_rid(_uniform_set)
		_uniform_set = RID()

	_first_sub_viewport.size = sub_viewport_size
	_second_sub_viewport.size = sub_viewport_size

	# We encode the id of the snapshot generator into the camera's extent so that
	# its final actual world rect is larger by 100th's of pixels in each axis according
	# to said id. In this case the x axis encodes the first digit of the id, and the
	# y axis the second digit.
	# TODO: make math simpler and cleaner
	var snapshot_id: int = SnapshotManager.snapshot_get_id(self) + 1

	var size_difference_to_encode: Vector2 = Vector2(snapshot_id % 10, snapshot_id / 10) / 100.0

	var viewport_rendering_global_size: Vector2 = (
		Vector2(sub_viewport_size) / snapshot_resolution_scale
	)

	var viewport_rendering_camera_zoom: Vector2 = (
		Vector2(sub_viewport_size) / Vector2(snapshot_rect.size)
	)

	var viewport_rendering_global_size_encoded: Vector2 = (
		viewport_rendering_global_size + size_difference_to_encode
	)

	var encoded_zoom_modifier: Vector2 = (
		viewport_rendering_global_size / viewport_rendering_global_size_encoded
	)

	_first_sub_viewport_camera.zoom = viewport_rendering_camera_zoom * encoded_zoom_modifier
	_second_sub_viewport_camera.zoom = - viewport_rendering_camera_zoom * encoded_zoom_modifier

	_snapshot_rect_dirty = true

	_update_subject_uniforms()


func _update_update_mode() -> void:
	if !_first_sub_viewport:
		return
	
	if enabled and allow_current_snapshot_refresh:
		_set_update_mode_always()
	else:
		_set_update_mode_never()


func add_subject(node: Node2D):
	var new_subjects: Array = subjects.duplicate()
	new_subjects.append(node)
	subjects = new_subjects


func remove_subject(node: Node2D):
	var new_subjects: Array = subjects.duplicate()
	new_subjects.erase(node)
	subjects = new_subjects


func clear_subjects():
	subjects = []


func append_subjects_array(in_subjects: Array[Node2D]):
	var new_subjects: Array = subjects.duplicate()
	new_subjects.append_array(in_subjects)
	subjects = new_subjects


func _update_subject_list():
	SnapshotManager.set_snapshot_subjects(self)
	_update_subject_uniforms()


func _update_subject_uniforms():
	for subject in subjects:
		SnapshotManager.subject_update_uniforms(subject)


func _update_atlas_frames():
	_total_frames = atlas_dimensions.x * atlas_dimensions.y
	if _current_frame >= _total_frames:
		_current_frame = 0

	_snapshot_atlas_dirty = true


func generate_snapshot() -> int:
	if compute_disabled:
		return -1
	
	if !enabled:
		push_warning("cannot generate snapshot, snapshot generator is not enabled")
		return -1
	
	latest_frame_rendered = _current_frame
	
	# If we are not allowing the refreshing of the current snapshot,
	# then we don't need the viewports to be in update mode always, thus
	# when we DO want to generate a new snapshot we have to do it explicitly
	# with the update once mode. We then have to wait for the rendering to finish
	# before we can use it in our compute.
	if !allow_current_snapshot_refresh:
		_set_update_mode_once()
		await RenderingServer.frame_post_draw

	RenderingServer.call_on_render_thread(_render_thread_generate_snapshot)
	return latest_frame_rendered


func refresh_current_snapshot():
	if compute_disabled:
		return
	
	if !allow_current_snapshot_refresh:
		return
	
	RenderingServer.call_on_render_thread(
		_render_thread_render_snapshot.bind(latest_frame_rendered)
	)


# returns the atlas frame that we rendered to
func _render_thread_generate_snapshot():
	_render_thread_render_snapshot(_current_frame)
	_current_frame = (_current_frame + 1) % _total_frames


func _render_thread_render_snapshot(frame: int):
	if headless:
		return
	
	# If the viewport resized, recreate the snapshot texture
	if _snapshot_rect_dirty:
		_update_viewport_uniforms()
		_update_snapshot_texture()
		_snapshot_rect_dirty = false
		_snapshot_atlas_dirty = false
		_uniform_set_dirty = true

	elif _snapshot_atlas_dirty:
		_update_snapshot_texture()
		_snapshot_atlas_dirty = false
		_uniform_set_dirty = true

	if _uniform_set_dirty:
		_update_uniform_set()
		_uniform_set_dirty = false

	var push_constants: PackedByteArray = (
		PackedInt32Array(
			[
				atlas_dimensions.x,
				atlas_dimensions.y,
				frame,
				0,
			]
		)
		.to_byte_array()
	)

	var compute_list: int = _global_rd.compute_list_begin()

	_global_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)

	_global_rd.compute_list_bind_uniform_set(compute_list, _uniform_set, 0)

	_global_rd.compute_list_set_push_constant(compute_list, push_constants, push_constants.size())

	var compute_size: Vector3i = (
		(
			(
				Vector3i(_first_sub_viewport.size.x, _first_sub_viewport.size.y, 1)
				- Vector3i(1, 1, 1)
			)
			/ 16
		)
		+ Vector3i(1, 1, 1)
	)

	_global_rd.compute_list_dispatch(compute_list, compute_size.x, compute_size.y, compute_size.z)

	_global_rd.compute_list_end()


func _update_viewport_uniforms():
	_first_viewport_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	_first_viewport_uniform.clear_ids()
	_first_viewport_uniform.add_id(_nearest_sampler)
	_first_viewport_uniform.add_id(
		RenderingServer.texture_get_rd_texture(_first_sub_viewport.get_texture().get_rid())
	)

	_second_viewport_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	_second_viewport_uniform.clear_ids()
	_second_viewport_uniform.add_id(_nearest_sampler)
	_second_viewport_uniform.add_id(
		RenderingServer.texture_get_rd_texture(_second_sub_viewport.get_texture().get_rid())
	)


func _update_snapshot_texture():
	if headless:
		return
	
	_snapshot_format.width = _first_sub_viewport.size.x * atlas_dimensions.x
	_snapshot_format.height = _first_sub_viewport.size.y * atlas_dimensions.y

	var past_snapshot_texture_rid: RID = _snapshot_texture_rid

	_snapshot_texture_rid = _global_rd.texture_create(_snapshot_format, RDTextureView.new(), [])
	snapshot_texture.texture_rd_rid = _snapshot_texture_rid

	# Must be done this way, otherwise getting "Attempting to free invalid RID" errors.
	if _uniform_set.is_valid():
		_global_rd.free_rid(_uniform_set)
		_uniform_set = RID()

	if past_snapshot_texture_rid.is_valid():
		_global_rd.free_rid(past_snapshot_texture_rid)
		past_snapshot_texture_rid = RID()

	_snapshot_texture_uniform.clear_ids()
	_snapshot_texture_uniform.add_id(snapshot_texture.texture_rd_rid)


func _update_uniform_set():
	if headless:
		return
	
	if _uniform_set.is_valid():
		_global_rd.free_rid(_uniform_set)
		_uniform_set = RID()

	_uniform_set = _global_rd.uniform_set_create(
		[_first_viewport_uniform, _second_viewport_uniform, _snapshot_texture_uniform], _shader, 0
	)
