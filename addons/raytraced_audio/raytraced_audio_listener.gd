class_name RaytracedAudioListener extends AudioListener3D
## 3D audio listener for raytraced audio
##
## [b]Audio buses[/b]
## [br]This plugin creates 2 new audio buses for you to use across your project:
## a [i]"Reverb"[/i] bus, and an [i]"Ambient"[/i] bus.
## [br]Note: both buses' names can be changed under [code]Project Settings > Raytraced Audio[/code].
## [br]
## [br]The reverb bus controls echo / reverb.
## [br]For example, there will be a much bigger reverb in large enclosed rooms compared to small ones, or outside in the open
## [br]
## [br]The ambient bus controls the strength and pan of sounds coming from outside.
## [br]For example, in a room with a single opening leading outisde, sounds in this bus will appear to come from that opening, and will fade based on the player's distance to it
## [br]
## [br][b]Performace[/b]
## [br]Raytraced Audio adds 2 performance monitors:
## [br] - [code]raytraced_audio/raycast_updates[/code]: How many raycast updates happened in one update tick
## [br] - [code]raytraced_audio/enabled_players_count[/code]: How many [RaytracedAudioPlayer3D]s are enabled in the scene
## [br]
## [br]Note: There should be only one [RaytracedAudioListener] in a given scene, just like how there should be only one AudioListener3D in a scene.
## [br]See also [RaytracedAudioPlayer3D]

## Speed of sound in m/s
const SPEED_OF_SOUND: float = 343.0
## All [RaytracedAudioListener]s will be in this group
const GROUP_NAME: StringName = &"raytraced_audio_listener"

const AudioRay: Script = preload("res://addons/raytraced_audio/audio_ray.gd")

enum RayScatterModel {
	## Rays will be shot out in a random 3d direction
	RANDOM,
	## Rays will be shot out on the listener's XZ plane (i.e. [code]Vector3(random, 0, random)[/code])
	XZ,
}

## Emitted when this node is enabled
signal enabled
## Emitted when this node is disabled
signal disabled
## Emitted when any configuration for the rays are changed
## [br]This includes: [member rays_count], [member max_raycast_dist], [member max_bounces], and [member ray_scatter_model]
signal ray_configuration_changed

## List of rays instanced by this node
var rays: Array[AudioRay] = []

## Enable or disable raycasting
## [br]Disabled nodes can't be updated (see [method update]) even if [member auto_update] is set to [code]true[/code]
@export var is_enabled: bool = true:
	set(v):
		if is_enabled == v:
			return
		is_enabled = v

		if is_enabled:
			if is_node_ready():
				setup()
			enabled.emit()
		else:
			disabled.emit()
			if is_node_ready():
				clear()

## Whether to update automatically
## [br]If set to [code]true[/code], this [RaytracedAudioListener] will update every [i]process[/i] frame
@export var auto_update: bool = true:
	set(v):
		auto_update = v
		set_process(auto_update)

## Number of rays to use
## [br]More rays and more bounces mean a more accurate model of the environment can be made
## [br] See also [member max_bounces]
## [br]
## [br][i]Technical note[/i]:
## [br] Because the rays need to gather different informations about the environment,
##  the actual number of processed rays can go up to:
## [br] [code]rays_count * (2 + n)[/code] where [code]n[/code] is the number of enabled [RaytracedAudioPlayer3D]s in the scene
## [br] ([code]rays_count * (1 ray that bounces around + 1 echo ray + 1 muffle ray per enabled RaytracedAudioPlayer3D[/code])
@export var rays_count: int = 4:
	set(v):
		if v == rays_count:
			return
		rays_count = maxi(v, 1)
		clear()
		setup()
		ray_configuration_changed.emit()

## The maximum distance which any given ray instanced by this node will cast
@export var max_raycast_dist: float = SPEED_OF_SOUND:
	set(v):
		max_raycast_dist = v
		_update_ray_configuration()
		ray_configuration_changed.emit()
## [br]More rays and more bounces mean a more accurate model of the environment can be made
## [br] See also [member rays_count]
@export var max_bounces: int = 3:
	set(v):
		max_bounces = v
		_update_ray_configuration()
		ray_configuration_changed.emit()

## Controls how rays will be instanced
@export var ray_scatter_model: RayScatterModel = RayScatterModel.RANDOM:
	set(v):
		ray_scatter_model = v
		_update_ray_configuration()
		ray_configuration_changed.emit()

@export_category("Muffle")
## Enables [RaytracedAudioPlayer3D]s muffling behind walls
@export var muffle_enabled: bool = true
## The interpolation strength of the muffle
## [br]See [member muffle_enabled]
@export_range(0.0, 1.0, 0.01) var muffle_interpolation: float = 0.01
@export_category("Echo")
## Enables updates to the reverb audio bus
## [br]See [code]Project Settings > Raytraced Audio > Reverb Bus[/code]
@export var echo_enabled: bool = true
## The "intensity" of the reverb
## [br]More specifically, multiplies the reverb's room size by this amount
## [br]The default is [code]2.0[/code] to account for sound waves coming back to the listener after hitting a wall
@export var echo_room_size_multiplier: float = 2.0
## The interpolation strength of the echo
## [br]See [member echo_enabled]
@export_range(0.0, 1.0, 0.01) var echo_interpolation: float = 0.01
@export_category("Ambient")
## Enables updates to the ambient audio bus
## [br]See [code]Project Settings > Raytraced Audio > Ambient Bus[/code]
@export var ambient_enabled: bool = true
## The interpolation strength of ambient sounds' direction (pan)
## [br]See [member ambient_enabled], [member ambient_pan_strength]
@export_range(0.0, 1.0, 0.01) var ambient_pan_interpolation: float = 0.02
## How strong the pan between right and left ear will be
## Setting this to 0 disables panning completely
## [br]See [member ambient_enabled], [member ambient_pan_interpolation]
@export_range(0.0, 1.0, 0.01) var ambient_pan_strength: float = 1.0
## The interpolation strength of ambient sounds' volume
## [br]See [member ambient_enabled]
@export var ambient_volume_interpolation: float = 0.01
## How smoothly the ambient sounds will fade away when the [AudioListener3D] is no longer "outside"
## Values close to 1 will make sounds linger for longer, while values close to 0 will make them drop suddenly
## [br]See [member ambient_enabled]
@export_range(0.0, 1.0, 0.001) var ambient_volume_attenuation: float = 0.998

## The size of the room based on data gathered from rays, in world units
## [br]Used in reverb calculation
var room_size: float = 0.0
## How "outside" this [RaytracedAudioListener] is based on data gathered from rays, between 0 and 1
var ambience: float = 0.0
## The direction to "outside" based on data gathered from rays
## [br]Should average out to 0 when this [RaytracedAudioListener] is completely outside
var ambient_dir: Vector3 = Vector3.ZERO

## For debugging purposes
## [br]See the [code]raytraced_audio/raycast_updates[/code] performance monitor
var ray_casts_this_tick: int = 0

var _reverb_effect: AudioEffectReverb
var _pan_effect: AudioEffectPanner

# Keep track of whether we've set up debug monitors
var _debug_monitors_setup: bool = false


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	# Reverb effect
	var i: int = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/reverb_bus"))
	if i == -1:
		push_error("Failed to get reverb bus for raytraced audio. Disabling echo...")
		echo_enabled = false
	else:
		_reverb_effect = AudioServer.get_bus_effect(i, 0)

	# Pan effect
	i = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/ambient_bus"))
	if i == -1:
		push_error("Failed to get ambient bus for raytraced audio. Disabling ambience...")
		ambient_enabled = false
	else:
		_pan_effect = AudioServer.get_bus_effect(i, 0)

	if is_enabled:
		setup()

	set_process(auto_update)
	if is_enabled:
		make_current()

	_setup_debug()


func _exit_tree() -> void:
	_cleanup_debug()


func _setup_debug() -> void:
	if _debug_monitors_setup:
		return
		
	_debug_monitors_setup = true
	
	Performance.add_custom_monitor(&"raytraced_audio/raycast_updates", func():
		# Check if this instance is still valid
		if not is_instance_valid(self):
			return 0
		return ray_casts_this_tick
	)

	Performance.add_custom_monitor(&"raytraced_audio/enabled_players_count", func():
		# Check if this instance is still valid and if we're in a scene tree
		if not is_instance_valid(self) or not is_inside_tree():
			return 0
		return get_tree().get_node_count_in_group(RaytracedAudioPlayer3D.ENABLED_GROUP_NAME)
	)


func _cleanup_debug() -> void:
	if not _debug_monitors_setup:
		return
		
	_debug_monitors_setup = false
	
	# Remove the custom monitors
	Performance.remove_custom_monitor(&"raytraced_audio/raycast_updates")
	Performance.remove_custom_monitor(&"raytraced_audio/enabled_players_count")
	


## Initiates this [RaytracedAudioListener]'s rays
func setup() -> void:
	for __ in rays_count:
		var rc: AudioRay = AudioRay.new(max_raycast_dist, max_bounces)
		rc.set_scatter_model(ray_scatter_model)
		add_child(rc, INTERNAL_MODE_BACK)
		rays.push_back(rc)


## Clears all created rays
func clear():
	for ray: AudioRay in rays:
		remove_child(ray)
		ray.queue_free()
	rays.clear()


func _process(delta: float) -> void:
	if !auto_update:
		set_process(false)
		return
	update()


## Updates this [RaytracedAudioListener]
## [br]If you are updating this node manually (i.e. [member auto_update] is [code]false[/code]), this is the method to call
func update():
	ray_casts_this_tick = 0
	if !is_enabled:
		return

	var echo: float = 0.0 # Avg echo from all rays
	var echo_count: int = 0 # Number of echo rays that came back
	var bounces_this_tick: int = 0
	var escaped_count: int = 0
	var escaped_dir: Vector3 = Vector3.ZERO # Avg escape direction
	var escaped_strength: float = 0.0

	# Gather data
	for ray: AudioRay in rays:
		ray.update()
		ray_casts_this_tick += ray.ray_casts_this_tick

		echo += ray.echo_dist
		echo_count += ray.echo_count
		bounces_this_tick += int(ray.has_bounced_this_tick)

		if ray.escaped:
			escaped_count += 1
			escaped_strength += 1.0 / ray.bounces
			escaped_dir += ray.escape_dir

		ray.reset_tick_stats()
	
	echo = 0.0 if echo_count == 0 else (echo / float(echo_count))
	escaped_dir = Vector3.ZERO if escaped_count == 0 else (escaped_dir / float(escaped_count))

	if muffle_enabled:
		_update_muffle()
	if echo_enabled:
		_update_echo(echo, echo_count, bounces_this_tick)
	if ambient_enabled:
		_update_ambient(escaped_strength, escaped_dir)


func _update_muffle() -> void:
	for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.GROUP_NAME):
		player.update(self)


func _update_echo(echo: float, echo_count: int, bounces: int) -> void:
	# Length -> echo delay
	room_size = lerpf(room_size, echo, echo_interpolation)
	var e: float = (room_size * echo_room_size_multiplier) / SPEED_OF_SOUND
	# print("e = ", e)
	_reverb_effect.room_size = lerpf(_reverb_effect.room_size, clampf(e, 0.0, 1.0), echo_interpolation)
	_reverb_effect.predelay_msec = lerpf(_reverb_effect.predelay_msec, e * 1000, echo_interpolation)
	_reverb_effect.predelay_feedback = lerpf(_reverb_effect.predelay_feedback, clampf(e, 0.0, 0.98), echo_interpolation)

	# More rays % -> echo strength
	var return_ratio: float = 0.0 if bounces == 0 else float(echo_count) / float(bounces)
	_reverb_effect.hipass = lerpf(_reverb_effect.hipass, 1.0 - return_ratio, echo_interpolation)


func _update_ambient(escaped_strength: float, escaped_dir: Vector3) -> void:
	var ambience_ratio: float = float(escaped_strength) / float(rays_count)

	# More rays % -> louder
	if escaped_strength > 0:
		ambience = lerpf(ambience, 1.0, ambience_ratio)
	else:
		ambience *= ambient_volume_attenuation
	var ambient_bus_idx: int = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/ambient_bus"))
	var volume: float = AudioServer.get_bus_volume_linear(ambient_bus_idx)
	AudioServer.set_bus_volume_linear(ambient_bus_idx, lerpf(volume, ambience, ambient_volume_interpolation))
	
	# Avg escape direction -> pan
	ambient_dir = ambient_dir.lerp(escaped_dir, ambient_pan_interpolation)
	var target_pan: float = 0.0 if ambient_dir.is_zero_approx() else owner.transform.basis.x.dot(ambient_dir.normalized())
	_pan_effect.pan = target_pan * ambient_pan_strength


# ✨ the name says it all ✨
func _update_ray_configuration() -> void:
	for ray: AudioRay in rays:
		ray.cast_dist = max_raycast_dist
		ray.max_bounces = max_bounces
		ray.set_scatter_model(ray_scatter_model)