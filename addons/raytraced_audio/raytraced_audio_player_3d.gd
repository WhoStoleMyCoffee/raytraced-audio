class_name RaytracedAudioPlayer3D extends AudioStreamPlayer3D
## Audio stream player that allows for audio muffling
## 
## You can already use the reverb and ambient audio buses (see the documentation for [RaytracedAudioListener] for more details)
## to make use of raytraced audio effects, but using [RaytracedAudioPlayer3D]s allows you to use more capabilities.
## Namely, muffling sounds behind walls.
## [br]
## [br][b][color=yellow]Warning[/color][/b]: [RaytracedAudioPlayer3D]s will default to using the reverb audio bus
## [br]If you wish to use another bus instead, please set it after this node has been added to the scene tree (i.e. after [code]_enter_tree()[/code])
## [br]
## [br][i]Technical note[/i]:
## [br]Currently, there is no way to muffle only one audio player (or apply any effect for that matter).
## [br]So we create a new bus for every audio player that is audible from the [RaytracedAudioListener]
## [br]Godot doesn't provide methods to calculate the volume of an audio at certain distances, so we calculate
## that ourselves (see [method calculate_audible_distance_threshold()])

## All [RaytracedAudioPlayer3D]s (regardless of state) will be in this group
const GROUP_NAME: StringName = &"raytraced_audio_player_3d"
## All [b]enabled[/b] [RaytracedAudioPlayer3D]s will be in this group
const ENABLED_GROUP_NAME: StringName = &"enabled_raytraced_audio_player_3d"
## The lowpass frequency when completely muffled
const LOWPASS_MIN_HZ: float = 250.0
## The lowpass frequency when completely not-muffled (?)
const LOWPASS_MAX_HZ: float = 20000.0

## Used in internal calculations
const LOG2: float = log(2.0)
## Used in internal calculations
const LOG_MIN_HZ: float = log(LOWPASS_MIN_HZ) / LOG2
## Used in internal calculations
const LOG_MAX_HZ: float = log(LOWPASS_MAX_HZ) / LOG2

## Emitted when this node is enabled
## [br]See also [constant ENABLED_GROUP_NAME]
signal enabled
## Emitted when this node is disabled
signal disabled
## Emitted when the maximum audible distance for this node is changed
## [br]See also [member AudioStreamPlayer3D.max_distance] and [member audibility_threshold_db]
signal audible_distance_updated(distance: float)

## The threshold (in decibels) at which sounds will be considered inaudible
## [br]This is used to enable / disable this node when it's not audible to save resources
## [br]The distance at which this node is no longer considered audible is automatically stored inside [member AudioStreamPlayer3D.max_distance]
## (if not already set), also to save resources
## [br]Though, setting [member AudioStreamPlayer3D.max_distance] doesn't update this field automatically
## [br]See also [method get_volume_db_from_pos] and [method calculate_audible_distance_threshold]
@export var audibility_threshold_db: float = -30.0:
	set(v):
		audibility_threshold_db = v
		# Max distance not configured
		if is_node_ready() and max_distance == 0.0:
			max_distance = calculate_audible_distance_threshold()
			audible_distance_updated.emit(max_distance)

var _lowpass_rays_count: int = 0
var _is_enabled: bool = false


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)
	bus = ProjectSettings.get_setting("raytraced_audio/reverb_bus") # Fallback

func _ready() -> void:
	# Max distance not configured
	if max_distance == 0.0:
		max_distance = calculate_audible_distance_threshold()
		audible_distance_updated.emit(max_distance)


## Enables this node
## [br]Note: you should almost never have to worry about enabling / disabling [RaytracedAudioPlayer3D]s manually
## [br]See [method update]
func enable():
	if _is_enabled:
		return
	_is_enabled = true
	var i: int = _create_bus()
	bus = AudioServer.get_bus_name(i)
	add_to_group(ENABLED_GROUP_NAME)

	enabled.emit()

## Enables this node
## [br]Note: you should almost never have to worry about enabling / disabling [RaytracedAudioPlayer3D]s manually
## [br]See [method update]
func disable():
	if !_is_enabled:
		return

	# Don't remove the fallback bus lol
	if bus != ProjectSettings.get_setting("raytraced_audio/reverb_bus"):
		_disable()
		return
	
	# Remove this node's specific bus
	var idx: int = AudioServer.get_bus_index(bus)
	if idx == -1:
		push_warning("audio bus ", bus, " not found")
		_disable()
		return
	_disable()
	AudioServer.remove_bus(idx)

func _disable():
	_is_enabled = false
	bus = ProjectSettings.get_setting("raytraced_audio/reverb_bus") # Fallback
	remove_from_group(ENABLED_GROUP_NAME)
	_lowpass_rays_count = 0

	disabled.emit()


# Returns the index of the created bus
func _create_bus() -> int:
	var i: int = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(i, generate_bus_name())
	AudioServer.set_bus_send(i, ProjectSettings.get_setting("raytraced_audio/reverb_bus"))
	AudioServer.add_bus_effect(i, AudioEffectLowPassFilter.new())
	return i

## Returns a name for the audio bus created for this node
func generate_bus_name() -> String:
	return str("RTAudioPlayer3D_", name, randi())

## ✨ the name says it all ✨
func is_enabled() -> bool:
	return _is_enabled

## Updates this [RaytracedAudioPlayer3D]
## [br]This method will adjust the muffle of the played stream, as well as enable or disable it
## based on whether it's audible from the given [RaytracedAudioListener]
## [br]If you are updating this node manually, this is the method to call
func update(listener: RaytracedAudioListener) -> void:
	if _is_enabled:
		_update(listener.rays_count, listener.muffle_interpolation)

	_lowpass_rays_count = 0
	
	# Enable based on position
	var dist_sq: float = global_position.distance_squared_to(listener.global_position)
	if dist_sq > max_distance*max_distance or !playing:
		disable()
	else:
		enable()


func _update(rays_count: int, interpolation: float):
	if bus == ProjectSettings.get_setting("raytraced_audio/reverb_bus"):
		_disable()
		return

	var idx: int = AudioServer.get_bus_index(bus)
	if idx == -1:
		push_error("audio bus ", bus, " not found")
		_disable()
	else:
		var ratio: float = float(_lowpass_rays_count) / float(rays_count)
		var lowpass: AudioEffectLowPassFilter = AudioServer.get_bus_effect(idx, 0)

		# Frequencies aren't linear, they scale logarithmically (log2 space) +1 octave = 2x the frequency
		# So we scale frequencies down before lerping, then scale them back up
		var log_t: float = lerpf(LOG_MIN_HZ, LOG_MAX_HZ, ratio)
		var log_hz: float = log(lowpass.cutoff_hz) / LOG2 # Scale current frequency down:  log2(x) = ln(x) / ln(2)
		log_hz = lerpf(log_hz, log_t, interpolation) # Lerp in scaled down space
		lowpass.cutoff_hz = pow(2, log_hz) # Scale back up


# Translated from the godot repo
## Calculates the volume (in decibels) of the audio stream from the given position
## [br]Please note that the final volume will vary depending on the stream that is being played
func get_volume_db_from_pos(from_pos: Vector3) -> float:
	const CMP_EPSILON: float = 0.0001

	var dist: float = from_pos.distance_to(global_position)
	var vol: float = 0.0
	match attenuation_model:
		ATTENUATION_INVERSE_DISTANCE:
			vol = linear_to_db(1.0 / ((dist / unit_size) + CMP_EPSILON))
		ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var d: float = (dist / unit_size)
			vol = linear_to_db(1.0 / (d*d + CMP_EPSILON))
		ATTENUATION_LOGARITHMIC:
			vol = -20.0 * log(dist / unit_size + CMP_EPSILON)
		ATTENUATION_DISABLED:
			pass
		_:
			push_error("Unknown attenuation type: '", attenuation_model, "'")
	vol = minf(vol + volume_db, max_db)
	return vol


## Calculates the distance at which this [RaytracedAudioPlayer3D] is no longer considered audible
## [br]See also [member audibility_threshold_db]
func calculate_audible_distance_threshold() -> float:
	if max_distance > 0.0:
		return max_distance
	
	match attenuation_model:
		ATTENUATION_INVERSE_DISTANCE:
			var t_lin: float = db_to_linear(audibility_threshold_db - volume_db)
			# Unit_size / dist < T_lin
			return unit_size / t_lin
		ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var t_lin: float = db_to_linear(audibility_threshold_db - volume_db)
			# (Unit_size / dist)^2 < T_lin
			return sqrt(unit_size*unit_size / t_lin)
		ATTENUATION_LOGARITHMIC:
			var t_db: float = audibility_threshold_db - volume_db
			# -20 * log(dist / Unit_size) > T_db
			return exp(t_db / -20.0) * unit_size
		ATTENUATION_DISABLED:
			return 0.0
		_:
			push_error("Unknown attenuation model: '", attenuation_model, "'")
			return 0.0


## Checks wheter this [RaytracedAudioPlayer3D] is considered audible from the given position
## [br]See also [member audibility_threshold_db]
func is_audible(from_pos: Vector3) -> bool:
	return get_volume_db_from_pos(from_pos) >= audibility_threshold_db



