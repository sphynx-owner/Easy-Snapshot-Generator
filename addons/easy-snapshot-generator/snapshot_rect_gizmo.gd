@tool
class_name SnapshotRectGizmo
extends Node2D


const SNAPSHOT_RECT_PROPERTY: StringName = &"snapshot_rect"

const PIVOT_POSITION_METHOD: StringName = &"get_pivot_position"


var node: Node


func _process(delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if !node or !EditorInterface.get_selection().get_selected_nodes().has(node):
		return
	
	var rect: Rect2i = node.get(SNAPSHOT_RECT_PROPERTY)
	
	rect.position += Vector2i(node.call(PIVOT_POSITION_METHOD))
	
	draw_rect(rect, Color.RED, false, 2, false)
