@tool
class_name SceneTextureGenerator


const TEXTURE_OFFSET_META_KEY: StringName = &"texture_rect_offset"


static func get_scene_texture(scene: PackedScene) -> Texture2D:
	var root: Node
	
	if Engine.is_editor_hint():
		root = EditorInterface.get_edited_scene_root()
		
	else:
		root = Engine.get_main_loop().root
	
	if !root:
		push_error("unable to find root for scene texture generation")
		return null
	
	var instance: Node = scene.instantiate()
	
	root.add_child.call_deferred(instance)
	
	var new_snapshot_generator: SnapshotGenerator = SnapshotGenerator.new()
	
	root.add_child.call_deferred(new_snapshot_generator)
	
	new_snapshot_generator.targets = collect_sprites(instance)
	
	new_snapshot_generator.fit_snapshot_rect_to_targets()
	
	new_snapshot_generator.queue_snapshot()
	
	var ret_texture: ImageTexture = ImageTexture.new()
	
	ret_texture.set_meta(TEXTURE_OFFSET_META_KEY, new_snapshot_generator.snapshot_rect.get_center())
	
	RenderingServer.frame_post_draw.connect(_post_draw_callback.bind(ret_texture, new_snapshot_generator, instance), CONNECT_ONE_SHOT)
	
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
