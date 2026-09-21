class_name SnapshotManager
extends Object
## A static class in charge of managing snapshots, their id's,
## and the nodes they are assigned to.

static var _snapshot_count := 0
static var _id_count := 0

# All the ids that were created and became available again
static var _available_ids: Dictionary

# All the active snapshots managed by this manager
# {[snapshot: SnapshotGenerator]: id: int}
static var _snapshots: Dictionary

# All the nodes that are subjects of any snapshot
# {[subject: Node2D]: ["snapshots"]: {[snapshot: SnapshotGenerator]: true}}
static var _subjects: Dictionary


static func sync_id_count():
	for i: int in range(_id_count, _snapshot_count):
		_available_ids[i] = true
	_id_count = _snapshot_count


static func pop_available_id() -> int:
	var available_id: int = _available_ids.keys()[0]
	_available_ids.erase(available_id)
	return available_id


static func subscribe_snapshot(snapshot: SnapshotGenerator):
	_snapshot_count += 1
	sync_id_count()
	_snapshots[snapshot] = pop_available_id()
	set_snapshot_subjects(snapshot)


static func unsubscribe_snapshot(snapshot: SnapshotGenerator):
	clear_snapshot_subjects(snapshot)
	_available_ids[_snapshots[snapshot]] = true
	_snapshots.erase(snapshot)


static func snapshot_get_id(snapshot: SnapshotGenerator) -> int:
	return _snapshots[snapshot]


static func set_snapshot_subjects(snapshot: SnapshotGenerator):
	clear_snapshot_subjects(snapshot)
	
	for subject: Node2D in snapshot.subjects:
		_subjects.get_or_add(subject, {"snapshots" : {}}).snapshots[snapshot] = true

static func clear_snapshot_subjects(snapshot: SnapshotGenerator):
	for subject: Node2D in snapshot.subjects:
		_subjects.get_or_add(subject, {"snapshots" : {}}).snapshots.erase(snapshot)
		
		if _subjects[subject].snapshots.is_empty():
			_subjects.erase(subject)

# This function would take the node that the snapshot wants to sync it's visibility to
# and return a uniform containing the size and the id of the viewport, along any other
# viewport that is tracking this node
static func subject_get_viewport_sizes_uniform(node: Node2D) -> Array[Vector2]:
	var sizes_uniform: Array[Vector2]
	
	for snapshot: SnapshotGenerator in _subjects[node].snapshots:
		sizes_uniform.append(Vector2(snapshot.snapshot_rect.size))
	
	return sizes_uniform


static func subject_get_viewport_ids_uniform(node: Node2D) -> Array[int]:
	var ids_uniform: Array[int]
	
	for snapshot: SnapshotGenerator in _subjects[node].snapshots:
		ids_uniform.append(_snapshots[snapshot] + 1)
	
	return ids_uniform


static func subject_update_uniforms(node: Node2D):
	node.material.set_shader_parameter("target_viewport_sizes", subject_get_viewport_sizes_uniform(node))
	node.material.set_shader_parameter("target_viewport_ids", subject_get_viewport_ids_uniform(node))
