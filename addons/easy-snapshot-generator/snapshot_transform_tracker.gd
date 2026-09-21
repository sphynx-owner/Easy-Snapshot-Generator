class_name SnapshotTransformTracker
extends Node2D
# This node is added implicitly by the snapshot generator to reliably track the 
# transform of the target node.
# This node will account for things like physics interpolation, and interpolation
# resets. 

signal deleting

var _past_global_position: Vector2


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESET_PHYSICS_INTERPOLATION:
		_on_reset_physics_interpolation_notification()
	if what == NOTIFICATION_PREDELETE:
		deleting.emit()


func _ready() -> void:
	process_physics_priority = -1
	_past_global_position = global_position


func _physics_process(delta: float) -> void:
	_past_global_position = global_position


func get_tracked_global_position() -> Vector2:
	if is_physics_interpolated_and_enabled():
		return lerp(_past_global_position, global_position, Engine.get_physics_interpolation_fraction())
	
	return global_position


func _on_reset_physics_interpolation_notification() -> void:
	_past_global_position = global_position
