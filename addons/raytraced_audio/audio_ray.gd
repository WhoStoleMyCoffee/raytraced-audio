extends RayCast3D

# dont you worry about this class, habibi
# shhhhhh its okay
# ( -  ͜ʖ -)☞(ʘ_ʘ; )

var cast_dist: float = 0.0
var max_bounces: int = 1
var ray_scatter: Callable

var echo_dist: float = 0.0
var echo_count: int = 0
var bounces: int = 0
var has_bounced_this_tick: bool = false
var ray_casts_this_tick: int = 0
var escaped: bool = false
var escape_dir: Vector3 = Vector3.ZERO

var _space_state: PhysicsDirectSpaceState3D


func _init(raycast_dist: float, max_bounce_count: int) -> void:
	top_level = true
	enabled = false
	cast_dist = raycast_dist
	max_bounces = max_bounce_count


func _enter_tree() -> void:
	owner = get_parent()
	# since the root can be custom, this assert may fail
	# assert(owner is RaytracedAudioListener)


func _ready() -> void:
	_space_state = get_world_3d().direct_space_state
	reset()


# TODO: optimize
func update():
	# Reset if needed
	if escaped or bounces > max_bounces:
		reset()

	force_raycast_update()
	ray_casts_this_tick += 1
	bounces += 1

	# Escaped outside
	if !is_colliding():
		escaped = true
		global_position += target_position
		# Muffle ray: Check for line of sight with audio players
		for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.ENABLED_GROUP_NAME):
			var has_line_of_sight: bool = _cast_ray(player.global_position).is_empty()
			player._lowpass_rays_count += int(has_line_of_sight)
		return

	# Bounce
	var hit_pos: Vector3 = get_collision_point()
	var normal: Vector3 = get_collision_normal()
	global_position = hit_pos + normal * 0.1
	target_position = target_position.bounce(normal)
	has_bounced_this_tick = true

	# Muffle ray: Check for line of sight with audio players
	for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.ENABLED_GROUP_NAME):
		var has_line_of_sight: bool = _cast_ray(player.global_position).is_empty()
		player._lowpass_rays_count += int(has_line_of_sight)
		# Same as:
		# if has_line_of_sight:
		# 	player.lowpass_rays_count += 1

	# Echo ray: Check for line of light with listener
	# Optimization: no need to raycast for first echo bounce
	if bounces == 1:
		echo_dist = hit_pos.distance_to(owner.global_position)
		echo_count += 1
		escape_dir = target_position.normalized()
	elif _cast_ray(owner.global_position).is_empty():
		# The way is clear -> echo
		echo_dist = hit_pos.distance_to(owner.global_position)
		echo_count += 1
		escape_dir = owner.global_position.direction_to(hit_pos)


# Return to the listener with a random direction
func reset():
	var dir: Vector3 = ray_scatter.call()
	
	global_position = owner.global_position
	target_position = dir * cast_dist

	bounces = 0
	escaped = false
	escape_dir = dir
	reset_tick_stats()


# Called after this ray is done ticking, in RaytracedAudioListener
func reset_tick_stats() -> void:
	has_bounced_this_tick = false
	ray_casts_this_tick = 0
	echo_dist = 0.0
	echo_count = 0


func set_scatter_model(model: RaytracedAudioListener.RayScatterModel) -> void:
	match model:
		RaytracedAudioListener.RayScatterModel.RANDOM:
			ray_scatter = _random_dir
		RaytracedAudioListener.RayScatterModel.XZ:
			ray_scatter = _random_dir_xz_plane
		_:
			push_error("Unknown ray scatter model: '", model, "'")
			ray_scatter = _random_dir



func _cast_ray(to: Vector3) -> Dictionary:
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		global_position,
		to,
		0b01
	)
	ray_casts_this_tick += 1
	return _space_state.intersect_ray(params)


func _random_dir_xz_plane() -> Vector3:
	var  yaw = randf_range(0.0, TAU)
	return Vector3(-sin(yaw), 0.0, -cos(yaw))

func _random_dir() -> Vector3:
	var theta: float = randf_range(0.0, TAU)
	var y: float = randf_range(-1.0, 1.0)
	var k: float = sqrt(1.0 - y*y)
	return Vector3(k * cos(theta), k * sin(theta), y)
