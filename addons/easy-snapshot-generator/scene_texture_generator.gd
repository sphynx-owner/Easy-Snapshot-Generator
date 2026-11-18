@tool
class_name SceneTextureGenerator


const TEXTURE_OFFSET_META_KEY: StringName = &"texture_rect_offset"


static func get_scene_texture(scene: PackedScene, force_centered: bool = false) -> Texture2D:
	var root: Node
	
	if Engine.is_editor_hint():
		root = Engine.get_singleton("EditorInterface").get_edited_scene_root()
		
	else:
		root = Engine.get_main_loop().root
	
	if !root:
		push_error("unable to find root for scene texture generation")
		return null
	
	var instance: Node = scene.instantiate()
	
	root.add_child.call_deferred(instance)
	
	var new_snapshot_generator: SnapshotGenerator = SnapshotGenerator.new()
	
	new_snapshot_generator.fit_force_centered = force_centered
	
	root.add_child.call_deferred(new_snapshot_generator)
	
	new_snapshot_generator.targets = collect_sprites(instance)
	
	new_snapshot_generator.fit_snapshot_rect_to_targets()
	
	new_snapshot_generator.queue_snapshot()
	
	# HACK @sphynx-owner: initializing the return texture to the atlas texture of the snapshot generator, even though
	# it has yet to actually render the contents. This gives the user immediate access to information like the size
	# of the texture, even if the final content will be genrated afterwards.
	var ret_texture: ImageTexture = ImageTexture.create_from_image(
		Image.create_empty(
			new_snapshot_generator.snapshot_rect.size.x,
			new_snapshot_generator.snapshot_rect.size.y,
			false,
			Image.FORMAT_RGBA8
		)
	)
	
	ret_texture.set_meta(TEXTURE_OFFSET_META_KEY, new_snapshot_generator.snapshot_rect.get_center())
	
	# HACK @sphynx-owner: using custom callable to support multiple invocations, otherwise overlapping connections.
	RenderingServer.frame_post_draw.connect(
		(func(tex: Texture2D, snapshot_generator: SnapshotGenerator, node: Node): 
			_post_draw_callback(tex, snapshot_generator, node)).bind(ret_texture, new_snapshot_generator, instance),
		CONNECT_ONE_SHOT
	)
	
	return ret_texture


static func _post_draw_callback(texture: ImageTexture, snapshot_generator: SnapshotGenerator, instance: Node) -> void:
	texture.set_image(snapshot_generator.atlas_texture_2d.get_image())
	
	snapshot_generator.get_parent().remove_child(snapshot_generator)
	
	snapshot_generator.queue_free()
	
	instance.get_parent().remove_child(instance)
	
	instance.queue_free()


static func collect_sprites(node: Node) -> Array[Node2D]:
	var ret: Array[Node2D]
	
	if node is Sprite2D:
		ret.append(node)
	
	for child in node.get_children():
		ret.append_array(collect_sprites(child))
	
	return ret
