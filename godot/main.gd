extends Node2D
## Stickman Brawl: Godot 4 test build.
## One fighter (Street Brawler) against the CPU on the Notebook arena, with the notebook VFX:
## hit-stop, directional shake, zoom punch, white flash, slashArc, scribbleDash, comicStar,
## inkSplatter (with floor marks), dustPuff, and the Blazing Knuckles! fiery surge.
## Everything is drawn in code (thick #1A1A1A ink, flat colours), like the HTML game.

const W := 960.0
const H := 540.0
const GROUND := 452.0
const GRAV := 2200.0
const JUMP_V := -820.0
const SPEED := 290.0
const INK := Color("1a1a1a")
const PAPER := Color("f7f8fb")
const GRID := Color("cfdcec")
const ROUND_TIME := 60.0
const WINS_NEEDED := 2

# attacks: damage, length, hit window, reach, knockback, stun
const ATK := {
	"punch": {"dmg": 5, "dur": .26, "from": .06, "to": .14, "reach": 62.0, "kb": 140.0, "stun": .25, "heavy": false, "launch": 0.0},
	"upper": {"dmg": 9, "dur": .42, "from": .10, "to": .20, "reach": 62.0, "kb": 220.0, "stun": .45, "heavy": true, "launch": -560.0},
	"kick": {"dmg": 8, "dur": .40, "from": .14, "to": .24, "reach": 80.0, "kb": 320.0, "stun": .35, "heavy": true, "launch": 0.0},
	"air": {"dmg": 7, "dur": .34, "from": .06, "to": .20, "reach": 66.0, "kb": 200.0, "stun": .30, "heavy": false, "launch": 0.0},
	"blaze": {"dmg": 0, "dur": 1.05, "from": 9.0, "to": 9.0, "reach": 0.0, "kb": 0.0, "stun": 0.0, "heavy": true, "launch": 0.0},
}
const PLATS := [Vector3(150, 300, 330), Vector3(660, 810, 330)]   # x0, x1, y (one-way ledges)

class Fighter:
	var name := ""
	var x := 0.0
	var y := 452.0
	var vx := 0.0
	var vy := 0.0
	var face := 1
	var hp := 100.0
	var max_hp := 100.0
	var spec := 0.0
	var on_ground := true
	var air_jumps := 1
	var atk = null            # Dictionary while attacking
	var hitstun := 0.0
	var blocking := false
	var roll = null           # Dictionary while rolling
	var col := Color.WHITE
	var cpu := false
	var brawler := false
	var chain := 0
	var chain_t := 0.0
	var white_t := 0.0
	var inv := 0.0
	var drop_t := 0.0
	var walk_ph := 0.0
	var slide_t := 0.0
	var ko := false
	var inp := {"left": false, "right": false, "block": false, "down": false, "punch": 0.0, "kick": 0.0, "jump": 0.0, "special": 0.0, "dodge": 0.0, "dodge_dir": 0}
	var ai_t := 0.0
	var ai_block := 0.0

var p1: Fighter
var p2: Fighter
var fighters: Array = []
var particles: Array = []
var ink_marks: Array = []
var floaters: Array = []
var clock := 0.0
var shake := 0.0
var shk = null
var hitstop := 0.0
var zp = null
var juice_t := -9.0
var phase := "intro"
var phase_t := 0.0
var round_no := 1
var wins := [0, 0]
var time_left := ROUND_TIME
var banner := ""
var banner_t := 0.0
var callout := ""
var callout_t := 0.0
var callout_col := Color("1d4fd7")
var cam := Vector2(W / 2, H / 2)
var cam_z := 1.0
var world: Node2D
var hud: Node2D
var font: Font
var touch_on := false
var touches := {}          # touch index -> button id
var tap_last := {"l": -9.0, "r": -9.0}
var selftest := false
var st_frames := 0
var st_stats := {"hits": 0, "specials": 0, "kos": 0, "rounds": 0}

const BTN := {
	"left": Vector2(78, 466), "right": Vector2(178, 466),
	"punch": Vector2(-90, 470), "kick": Vector2(-180, 488), "jump": Vector2(-96, 372), "block": Vector2(-190, 392), "special": Vector2(-278, 472),
}
const BTN_R := 40.0

func _ready() -> void:
	selftest = OS.get_cmdline_user_args().has("--selftest")
	font = ThemeDB.fallback_font
	world = Node2D.new()
	add_child(world)
	world.draw.connect(_draw_world)
	hud = Node2D.new()
	add_child(hud)
	hud.draw.connect(_draw_hud)
	touch_on = DisplayServer.is_touchscreen_available()
	new_match()

# ---------------------------------------------------------------- match flow
func new_match() -> void:
	wins = [0, 0]
	round_no = 1
	new_round()

func new_round() -> void:
	p1 = Fighter.new()
	p1.name = "Street Brawler"
	p1.x = 280.0
	p1.col = Color("2a62d8")
	p1.brawler = true
	p1.cpu = selftest
	p2 = Fighter.new()
	p2.name = "Doodle"
	p2.x = 680.0
	p2.face = -1
	p2.col = Color("d1352b")
	p2.cpu = true
	fighters = [p1, p2]
	particles.clear()
	ink_marks.clear()
	floaters.clear()
	time_left = ROUND_TIME
	phase = "intro"
	phase_t = 0.0
	set_banner("ROUND %d" % round_no)
	shake = 0.0
	shk = null
	hitstop = 0.0
	zp = null

func set_banner(t: String) -> void:
	banner = t
	banner_t = 0.0

func set_callout(t: String, c: Color) -> void:
	callout = t
	callout_t = 0.0
	callout_col = c

func end_round(winner: int, why: String) -> void:
	if phase != "fight":
		return
	phase = "ko"
	phase_t = 0.0
	if winner >= 0:
		wins[winner] += 1
	set_banner(why)
	st_stats.kos += 1

# ---------------------------------------------------------------- feel: hit-stop, shake, zoom punch
func trigger_hitstop(d: float) -> void:
	hitstop = maxf(hitstop, minf(.07, d))

func trigger_shake(i: float, ax := 0.0, ay := 1.0) -> void:
	if i <= 0.0:
		return
	var v := Vector2(ax, ay)
	if v.length() < 0.001:
		v = Vector2(0, 1)
	if shk == null or i >= shake:
		shk = {"i": i, "d": v.normalized(), "t": 0.0}
	shake = maxf(shake, i)

func shake_tick(real: float) -> void:
	if shk == null:
		shake = 0.0
		return
	shk.t += real
	var q: float = shk.t / .15
	if q >= 1.0:
		shk = null
		shake = 0.0
	else:
		shake = shk.i * (1.0 - q) * (1.0 - q)

func impact_juice(e: Fighter, pos: Vector2) -> void:
	if clock - juice_t < .12:
		return
	juice_t = clock
	trigger_hitstop(.06)
	zp = {"p": pos, "t": 0.0}
	if e:
		e.white_t = .04

# ---------------------------------------------------------------- VFX spawners
func spawn(p: Dictionary) -> void:
	if not p.has("t"):
		p.t = 0.0
	if not p.has("v"):
		p.v = Vector2.ZERO
	particles.append(p)

func slash_arc(pos: Vector2, face: int, r: float, a0: float, a1: float, w: float, c = null, life := .2) -> void:
	spawn({"type": "slash", "p": pos, "face": face, "r": r, "a0": a0, "a1": a1, "w": w, "c": c, "life": life})

func scribble_dash(pos: Vector2, dir: int) -> void:
	spawn({"type": "scrib", "p": pos, "dir": dir, "len": randf_range(22, 58), "dk": randf() < .45, "sd": randf() * 97.0, "life": randf_range(.22, .32)})

func comic_star(pos: Vector2, r: float, dir := 0) -> void:
	spawn({"type": "star", "p": pos, "r": r, "rot": randf() * TAU, "sd": randf() * 97.0, "dir": dir, "life": .24, "v": Vector2(dir * 90.0, 0)})

func dust_puff(pos: Vector2, n := 2, r := 11.0, dir := 0) -> void:
	for i in n:
		var d := 0.0 if n == 1 else (1.0 if i % 2 else -1.0)
		spawn({"type": "puff", "p": pos + Vector2(d * randf_range(4, 12), -4), "r": r * randf_range(.8, 1.15),
			"v": Vector2(d * randf_range(40, 90) + dir * 60.0, randf_range(-40, -10)), "life": randf_range(.38, .5)})

func ink_splatter(pos: Vector2, dir: int, c: Color, n := 5) -> void:
	for i in n:
		spawn({"type": "ink", "p": pos, "v": Vector2(dir * randf_range(60, 360) + randf_range(-70, 70), randf_range(-320, -40)), "c": c, "r": randf_range(2.5, 5.5), "life": 3.4})

func blaze_surge(x0: float, yy: float, dir: int, ex: float) -> void:
	spawn({"type": "surge", "p": Vector2(x0, yy), "dir": dir, "len": maxf(160.0, absf(ex - x0) + 170.0), "sd": randf() * 9.0, "life": .34})
	for k in 2:
		spawn({"type": "shock", "p": Vector2(ex + dir * 10, yy), "dir": dir, "t": -k * .06, "life": .25})
	for k in 15:
		spawn({"type": "flame", "p": Vector2(ex + randf_range(-10, 20) * dir, yy + randf_range(-26, 26)), "v": Vector2(dir * randf_range(320, 760), randf_range(-220, 90)), "r": randf_range(3.5, 6.5), "life": randf_range(.32, .5)})
	for k in 6:
		spawn({"type": "puff", "p": Vector2(ex + dir * randf_range(0, 40), GROUND - 4), "r": randf_range(9, 14), "v": Vector2(dir * randf_range(90, 240), randf_range(-40, -8)), "t": -k * .02, "life": randf_range(.4, .55)})

func floater(pos: Vector2, txt: String, c: Color) -> void:
	floaters.append({"p": pos, "txt": txt, "c": c, "t": 0.0})

# ---------------------------------------------------------------- the loop
func _process(delta: float) -> void:
	var real := minf(delta, .05)
	if selftest:
		real = 1.0 / 60.0
		st_frames += 1
		if st_frames % 600 == 0:
			p1.spec = 100.0
			p2.spec = 100.0
		if st_frames >= 3600:
			print("SELFTEST OK ", st_stats)
			get_tree().quit()
			return
	clock += real
	for f in fighters:
		if f.white_t > 0:
			f.white_t -= real
	shake_tick(real)
	if banner != "":
		banner_t += real
		if banner_t > 1.0:
			banner = ""
	if callout != "":
		callout_t += real
		if callout_t > 1.15:
			callout = ""
	if zp != null:
		zp.t += real
		if zp.t > .32:
			zp = null
	phase_t += real
	if phase == "intro":
		if phase_t > .9 and banner.begins_with("ROUND"):
			set_banner("FIGHT!")
		if phase_t > 1.5:
			phase = "fight"
	elif phase == "ko":
		if phase_t > 2.6:
			st_stats.rounds += 1
			if wins[0] >= WINS_NEEDED or wins[1] >= WINS_NEEDED:
				phase = "over"
				phase_t = 0.0
				set_banner("YOU WIN!" if wins[0] > wins[1] else "YOU LOSE")
			else:
				round_no += 1
				new_round()
	elif phase == "over":
		if selftest and phase_t > 1.0:
			new_match()
	if hitstop > 0.0:
		hitstop -= real
		update_fx(real)       # fighters hold still, the particles keep going
	else:
		update_world(real)
	update_cam(real)
	world.queue_redraw()
	hud.queue_redraw()

func update_world(dt: float) -> void:
	if phase == "fight":
		time_left -= dt
		if time_left <= 0.0:
			time_left = 0.0
			end_round(0 if p1.hp >= p2.hp else 1, "TIME!")
	read_input()
	for f in fighters:
		if f.cpu and phase == "fight":
			ai_think(f, p2 if f == p1 else p1, dt)
	for f in fighters:
		update_fighter(f, p2 if f == p1 else p1, dt)
	update_fx(dt)

func update_cam(real: float) -> void:
	var mid := Vector2((p1.x + p2.x) / 2.0, (p1.y + p2.y) / 2.0 - 120.0)
	var spread := absf(p1.x - p2.x)
	var tz := 1.0 + clampf((560.0 - spread) / 560.0, 0.0, 1.0) * .1
	var k := 1.0 - exp(-real * 3.0)
	cam_z += (tz - cam_z) * k
	cam += (mid - cam) * k
	var vs := get_viewport_rect().size
	var hw := vs.x / 2.0 / cam_z
	var hh := H / 2.0 / cam_z
	cam.x = clampf(cam.x, minf(hw, W / 2), maxf(W - hw, W / 2))
	cam.y = clampf(cam.y, hh, H - hh)
	# zoom punch toward the hit, easing back to 1.0x
	var zq := 0.0
	if zp != null:
		zq = zp.t / .04 if zp.t < .04 else pow(maxf(0.0, 1.0 - (zp.t - .04) / .28), 2)
	var c := cam
	if zp != null:
		c += (zp.p - cam) * .3 * zq
	var z := cam_z * (1.0 + .06 * zq)
	var off := Vector2.ZERO
	if shake > 0.0 and shk != null:
		var o := cos(shk.t * TAU * 24.0) * shake * .5
		off = shk.d * o + Vector2(randf() - .5, randf() - .5) * shake * .12
	world.scale = Vector2(z, z)
	world.position = Vector2(vs.x / 2.0, H / 2.0) - c * z + off

# ---------------------------------------------------------------- input
func read_input() -> void:
	if p1.cpu:
		return
	var i := p1.inp
	i.left = Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT) or touches.values().has("left")
	i.right = Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT) or touches.values().has("right")
	i.block = Input.is_physical_key_pressed(KEY_L) or touches.values().has("block")
	i.down = Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)

func press(act: String) -> void:
	if phase == "over":
		new_match()
		return
	var i := p1.inp
	if act == "left" or act == "right":
		var k := "l" if act == "left" else "r"
		if clock - tap_last[k] < .25:
			i.dodge = .15
			i.dodge_dir = -1 if act == "left" else 1
			tap_last[k] = -9.0
		else:
			tap_last[k] = clock
		return
	i[act] = .16 if act == "jump" else .2

func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		if not k.pressed or k.echo:
			return
		match k.physical_keycode:
			KEY_J, KEY_Z:
				press("punch")
			KEY_K, KEY_X:
				press("kick")
			KEY_W, KEY_UP:
				press("jump")
			KEY_SPACE:
				press("special")
			KEY_A, KEY_LEFT:
				press("left")
			KEY_D, KEY_RIGHT:
				press("right")
			KEY_ENTER:
				if phase == "over":
					new_match()
	elif ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		touch_on = true
		if t.pressed:
			var b := btn_at(t.position)
			if phase == "over":
				new_match()
			elif b != "":
				touches[t.index] = b
				if b != "block":
					press(b)
		else:
			touches.erase(t.index)
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		if touches.has(d.index) and (touches[d.index] == "left" or touches[d.index] == "right"):
			var b2 := btn_at(d.position)
			if b2 == "left" or b2 == "right":
				touches[d.index] = b2
	elif ev is InputEventMouseButton:
		var m := ev as InputEventMouseButton
		if m.pressed and phase == "over":
			new_match()

func btn_pos(id: String) -> Vector2:
	var p: Vector2 = BTN[id]
	var vs := get_viewport_rect().size
	if p.x < 0:
		p.x = vs.x + p.x
	return p

func btn_at(pos: Vector2) -> String:
	for id in BTN:
		if pos.distance_to(btn_pos(id)) < BTN_R * 1.25:
			return id
	return ""

# ---------------------------------------------------------------- CPU
func ai_think(f: Fighter, t: Fighter, dt: float) -> void:
	var i := f.inp
	f.ai_t -= dt
	f.ai_block -= dt
	var d := t.x - f.x
	var dist := absf(d)
	i.left = false
	i.right = false
	i.block = f.ai_block > 0.0
	if f.ai_t > 0.0:
		if dist > 72.0 and f.ai_block <= 0.0:
			i.right = d > 0
			i.left = d < 0
		return
	f.ai_t = randf_range(.12, .3)
	if t.atk != null and dist < 110.0 and randf() < .45:
		f.ai_block = .35
		return
	if f.spec >= 100.0 and dist < 220.0:
		i.special = .2
	elif dist > 72.0:
		i.right = d > 0
		i.left = d < 0
		if randf() < .06:
			i.jump = .16
	else:
		var r := randf()
		if r < .5:
			i.punch = .2
		elif r < .75:
			i.kick = .2
		elif r < .82:
			i.dodge = .15
			i.dodge_dir = -1 if d > 0 else 1
		elif r < .9:
			i.jump = .16

# ---------------------------------------------------------------- fighters
func start_attack(f: Fighter, type: String) -> void:
	var a: Dictionary = ATK[type].duplicate()
	a.type = type
	a.t = 0.0
	a.hit = false
	a.j = 0
	a.up = false
	f.atk = a
	if type == "upper":
		slash_arc(Vector2(f.x + f.face * 2, f.y - 78), f.face, 70.0, 1.3, -1.8, 14.0)
	elif type == "air":
		slash_arc(Vector2(f.x + f.face * 2, f.y - 70), f.face, 76.0, -.9, .7, 12.0)
	elif type == "blaze":
		f.spec = 0.0
		st_stats.specials += 1

func update_fighter(f: Fighter, t: Fighter, dt: float) -> void:
	var i := f.inp
	for k in ["punch", "kick", "jump", "special", "dodge"]:
		if i[k] > 0.0:
			i[k] -= dt
	f.chain_t -= dt
	f.inv -= dt
	f.drop_t -= dt
	var prev_y := f.y
	if f.ko:
		f.vx *= pow(.05, dt)
	elif f.roll != null:
		var r: Dictionary = f.roll
		r.t += dt
		f.vx = r.dir * lerpf(600.0, 140.0, clampf(r.t / r.dur, 0.0, 1.0))
		r.sd += dt * 40.0
		while r.sd >= 1.0:
			r.sd -= 1.0
			scribble_dash(Vector2(f.x - r.dir * 24, f.y - randf_range(8, 72)), r.dir)
		if r.t >= r.dur:
			f.roll = null
	elif f.hitstun > 0.0:
		f.hitstun -= dt
		f.vx *= pow(.02, dt)
		if f.on_ground and absf(f.vx) > 260.0:
			f.slide_t -= dt
			if f.slide_t <= 0.0:
				f.slide_t = .07
				dust_puff(Vector2(f.x - signf(f.vx) * 10, f.y), 1, 9.0, -int(signf(f.vx)))
	elif f.atk != null:
		update_attack(f, t, dt)
	else:
		if phase == "fight":
			f.face = 1 if t.x >= f.x else -1
		f.blocking = i.block and f.on_ground and phase == "fight"
		var dir := (1 if i.right else 0) - (1 if i.left else 0)
		if phase != "fight":
			dir = 0
		if f.blocking:
			f.vx *= pow(.001, dt)
		else:
			f.vx = lerpf(f.vx, dir * SPEED, 1.0 - pow(.0005, dt))
		if phase == "fight":
			if i.dodge > 0.0 and f.on_ground:
				i.dodge = 0.0
				f.roll = {"t": 0.0, "dur": .38, "dir": i.dodge_dir if i.dodge_dir != 0 else -f.face, "sd": 0.0}
				f.inv = .3
			elif i.jump > 0.0 and (f.on_ground or f.air_jumps > 0):
				i.jump = 0.0
				if not f.on_ground:
					f.air_jumps -= 1
					dust_puff(Vector2(f.x, f.y + 6), 2, 13.0)    # Sky Step
				else:
					dust_puff(Vector2(f.x, f.y), 3, 11.0)
				f.vy = JUMP_V
				f.on_ground = false
				if i.down:
					f.drop_t = .25
			elif i.special > 0.0 and f.spec >= 100.0 and f.on_ground:
				i.special = 0.0
				start_attack(f, "blaze")
			elif i.punch > 0.0:
				i.punch = 0.0
				if not f.on_ground:
					start_attack(f, "air")
				else:
					if f.chain_t > 0.0 and f.chain < 2:
						f.chain += 1
					else:
						f.chain = 0
					start_attack(f, "upper" if f.chain == 2 else "punch")
					if f.chain == 2:
						f.chain = 0
			elif i.kick > 0.0:
				i.kick = 0.0
				start_attack(f, "kick")
		if i.down and f.on_ground and f.y < GROUND - 1:
			f.drop_t = .25
			f.on_ground = false
		f.walk_ph += dt * absf(f.vx) / 30.0
	# gravity and landing
	if not f.on_ground or f.vy < 0.0:
		f.vy += GRAV * (1.25 if f.vy > 0 else 1.0) * dt
	f.x += f.vx * dt
	f.y += f.vy * dt
	f.x = clampf(f.x, 36.0, W - 36.0)
	var land := -1.0
	if f.vy >= 0.0:
		if f.drop_t <= 0.0:
			for p in PLATS:
				if f.x >= p.x and f.x <= p.y and prev_y <= p.z + 1.0 and f.y >= p.z:
					land = p.z
		if land < 0.0 and f.y >= GROUND:
			land = GROUND
	if land >= 0.0:
		if not f.on_ground:
			if f.vy > 300.0 and not f.ko:
				dust_puff(Vector2(f.x, land), 3, 11.0)
			if f.atk != null and f.atk.type == "air":
				f.atk = null
		f.y = land
		f.vy = 0.0
		f.on_ground = true
		f.air_jumps = 1
	else:
		f.on_ground = false

func update_attack(f: Fighter, t: Fighter, dt: float) -> void:
	var a: Dictionary = f.atk
	a.t += dt
	if a.type == "blaze":
		update_blaze(f, t, a, dt)
	else:
		if f.on_ground:
			f.vx *= pow(.002, dt)
		if a.t >= a.from and a.t <= a.to and not a.hit:
			var dx := (t.x - f.x) * f.face
			if dx > -10.0 and dx < a.reach + 22.0 and absf((t.y - 60.0) - (f.y - 60.0)) < 95.0 and not t.ko:
				a.hit = true
				strike(f, t, a)
	if f.atk != null and a.t >= a.dur:
		if a.type == "punch":
			f.chain_t = .42
		f.atk = null

# BLAZING KNUCKLES!: step in, two quick jabs, then one horizontal fiery surge through the rival
func update_blaze(f: Fighter, t: Fighter, a: Dictionary, dt: float) -> void:
	if a.t < .18:
		var gap := (t.x - f.x) * f.face - 52.0
		f.vx = f.face * clampf(gap * 10.0, 0.0, 1200.0)
		return
	f.vx *= pow(.001, dt)
	for n in 2:
		var ti := .26 + n * .16
		if a.t >= ti and not (a.j & (1 << n)):
			a.j |= 1 << n
			var cy := f.y - (88.0 + (8.0 if n else -6.0))
			spawn({"type": "thrust", "p": Vector2(f.x + f.face * 6, cy), "face": f.face, "r": 58.0, "life": .17})
			if in_reach(f, t, 140.0):
				inflict(f, t, 10, f.face, 30.0, .5, false, 0.0, true)
	if a.t >= .62 and not a.up:
		a.up = true
		set_callout("BLAZING KNUCKLES!", Color("1d4fd7") if f == p1 else Color("d1352b"))
		var ex := t.x if in_reach(f, t, 150.0) else f.x + f.face * 90.0
		blaze_surge(f.x + f.face * 40.0, f.y - 86.0, f.face, ex)
		trigger_shake(13.0, f.face, 0.0)
		if in_reach(f, t, 150.0):
			inflict(f, t, 18, f.face, 540.0, .6, true, -230.0, true)

func in_reach(f: Fighter, t: Fighter, r: float) -> bool:
	var dx := (t.x - f.x) * f.face
	return dx > -20.0 and dx < r and not t.ko

func strike(f: Fighter, t: Fighter, a: Dictionary) -> void:
	inflict(f, t, a.dmg, f.face, a.kb, a.stun, a.heavy, a.launch, false)

func inflict(src: Fighter, def: Fighter, dmg: float, dir: int, kb: float, stun: float, heavy: bool, launch: float, special: bool) -> void:
	if def.inv > 0.0 or def.ko or phase != "fight":
		return
	var hit_pos := Vector2(def.x - dir * 6.0, def.y - 86.0)
	if def.blocking and def.face == -dir and not special:
		def.vx = dir * kb * .3
		comic_star(hit_pos, 18.0)
		trigger_shake(3.0, dir, 0.0)
		def.spec = minf(100.0, def.spec + 2.0)
		return
	st_stats.hits += 1
	def.hp = maxf(0.0, def.hp - dmg)
	def.hitstun = stun
	def.atk = null
	def.roll = null
	def.vx = dir * kb
	if launch != 0.0:
		def.vy = launch
		def.on_ground = false
	if heavy:
		comic_star(hit_pos, 40.0, dir)
		ink_splatter(hit_pos, dir, def.col, 5)
		trigger_shake(clampf(4.0 + dmg * .45, 8.0, 16.0), dir, -.35)
		trigger_hitstop(.04)
	else:
		comic_star(hit_pos, 20.0, dir)
		ink_splatter(hit_pos, dir, def.col, 2)
		trigger_shake(4.0, dir, -.35)
		trigger_hitstop(.02)
	if special and heavy:
		impact_juice(def, hit_pos)
	src.spec = minf(100.0, src.spec + dmg * 1.4)
	def.spec = minf(100.0, def.spec + dmg * .7)
	floater(Vector2(def.x, def.y - 140.0), "-%d" % int(dmg), Color("d1352b"))
	if def.hp <= 0.0:
		def.ko = true
		def.vy = -420.0
		def.vx = dir * 320.0
		def.on_ground = false
		trigger_hitstop(.07)
		end_round(0 if def == p2 else 1, "K.O.!")

# ---------------------------------------------------------------- particles
func update_fx(dt: float) -> void:
	for p in particles:
		p.t += dt
		if p.t < 0.0:
			continue
		match p.type:
			"ink":
				var y0: float = p.p.y
				p.v.y += 900.0 * dt
				p.p += p.v * dt
				var gy := surface_below(p.p.x, y0, p.p.y)
				if p.v.y > 0.0 and gy > -1.0:
					if randf() < .4:
						if ink_marks.size() >= 36:
							ink_marks.pop_front()
						ink_marks.append({"p": Vector2(p.p.x, gy + 1.0), "r": p.r * randf_range(.9, 1.4), "c": p.c})
					p.t = p.life
				elif p.p.y > H + 20.0:
					p.t = p.life
			"star":
				p.p += p.v * dt
				p.v *= pow(.02, dt)
			"flame":
				p.p += p.v * dt
				p.v.x *= pow(.25, dt)
				p.v.y = p.v.y * pow(.3, dt) - 120.0 * dt
			"puff":
				p.p += p.v * dt
				p.v.x *= pow(.08, dt)
				p.v.y *= pow(.2, dt)
	particles = particles.filter(func(q): return q.t < q.life)
	for fl in floaters:
		fl.t += dt
		fl.p.y -= 40.0 * dt
	floaters = floaters.filter(func(q): return q.t < .9)

func surface_below(x: float, y0: float, y1: float) -> float:
	for p in PLATS:
		if x >= p.x and x <= p.y and y0 <= p.z + 2.0 and y1 >= p.z:
			return p.z
	if y1 >= GROUND:
		return GROUND
	return -9.0

# ================================================================= DRAWING
func ellipse_pts(c: Vector2, rx: float, ry: float, n := 28) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := float(i) / n * TAU
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts

func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * clampf(a, 0.0, 1.0))

func closed(pts: PackedVector2Array) -> PackedVector2Array:
	var o := pts.duplicate()
	o.append(pts[0])
	return o

func _draw_world() -> void:
	var w := world
	var vs := get_viewport_rect().size
	# notebook paper (drawn wide so wide phones never see an edge)
	w.draw_rect(Rect2(-W, -H, W * 3, H * 3), PAPER)
	for gx in range(-960, 1921, 32):
		w.draw_line(Vector2(gx + .5, -540), Vector2(gx + .5, 1080), GRID, 1.0)
	for gy in range(-540, 1081, 32):
		w.draw_line(Vector2(-960, gy + .5), Vector2(1920, gy + .5), GRID, 1.0)
	w.draw_line(Vector2(70.5, -540), Vector2(70.5, 1080), Color(.82, .21, .17, .35), 2.0)
	# hills, sun, ground
	var hill := PackedVector2Array([Vector2(-960, GROUND), Vector2(0, 372), Vector2(80, 318), Vector2(140, 350), Vector2(240, 270), Vector2(330, 348), Vector2(410, 320), Vector2(500, 386), Vector2(600, 330), Vector2(690, 372), Vector2(790, 300), Vector2(880, 352), Vector2(960, 326), Vector2(1920, GROUND)])
	w.draw_colored_polygon(hill, Color(1, 1, 1, .6))
	w.draw_polyline(hill, Color("a9bbd3"), 3.0, true)
	w.draw_arc(Vector2(842, 196), 26, 0, TAU, 40, Color("e3b100"), 3.5, true)
	for k in 10:
		var an := k / 10.0 * TAU + clock * .25
		var l := 46.0 if k % 2 else 52.0
		w.draw_line(Vector2(842, 196) + Vector2(cos(an), sin(an)) * 34, Vector2(842, 196) + Vector2(cos(an), sin(an)) * l, Color("e3b100"), 3.5, true)
	w.draw_rect(Rect2(-960, GROUND, 2880, 600), Color(.106, .137, .2, .06))
	var gl := PackedVector2Array()
	for gx in range(-960, 1921, 20):
		gl.append(Vector2(gx, GROUND + sin(gx * .05) * 1.5))
	w.draw_polyline(gl, INK, 5.0, true)
	for p in PLATS:
		var r := Rect2(p.x, p.z, p.y - p.x, 13)
		w.draw_rect(r, Color.WHITE)
		w.draw_rect(r, INK, false, 3.0)
		w.draw_line(Vector2(p.x + 6, p.z + 6.5), Vector2(p.y - 6, p.z + 6.5), Color("a9bbd3"), 1.5)
	for m in ink_marks:
		w.draw_colored_polygon(ellipse_pts(m.p, m.r, m.r * .3, 16), with_alpha(m.c, .85))
	for f in fighters:
		w.draw_colored_polygon(ellipse_pts(Vector2(f.x, ground_under(f)), 26, 5, 16), Color(.1, .1, .15, .12))
	for f in [p2, p1]:
		draw_fighter(w, f)
	draw_particles(w)
	for fl in floaters:
		var a: float = 1.0 - fl.t / .9
		w.draw_string_outline(font, fl.p + Vector2(-20, 0), fl.txt, HORIZONTAL_ALIGNMENT_CENTER, 40, 22, 6, with_alpha(Color.WHITE, a))
		w.draw_string(font, fl.p + Vector2(-20, 0), fl.txt, HORIZONTAL_ALIGNMENT_CENTER, 40, 22, with_alpha(fl.c, a))

func ground_under(f: Fighter) -> float:
	for p in PLATS:
		if f.x >= p.x and f.x <= p.y and f.y <= p.z + 2.0:
			return p.z
	return GROUND

# ---- stick fighter, posed from its state; drawn white with an ink outline while flashing
func pose_of(f: Fighter) -> Dictionary:
	var P := {"lean": 0.0, "hip": Vector2(0, -50), "fF": Vector2(13, 0), "fB": Vector2(-13, 0), "hF": Vector2(26, -66), "hB": Vector2(-12, -60), "rot": 0.0}
	var bob := sin(clock * 4.0 + f.x) * 1.5
	P.hF += Vector2(0, bob)
	P.hB += Vector2(0, bob)
	if f.ko:
		P.rot = -f.face * (PI / 2.0 if f.on_ground else 1.0)
		return P
	if f.roll != null:
		P.ball = true
		return P
	if f.hitstun > 0.0:
		P.lean = -14.0
		P.hF = Vector2(-4, -58)
		P.hB = Vector2(-30, -78)
		return P
	if f.atk != null:
		var a: Dictionary = f.atk
		var e := clampf((a.t - a.from * .5) / maxf(.05, a.to - a.from * .5), 0.0, 1.0)
		if a.t > a.to:
			e = clampf(1.0 - (a.t - a.to) / maxf(.05, a.dur - a.to), 0.0, 1.0)
		match a.type:
			"punch":
				P.hF = Vector2(26, -66).lerp(Vector2(64, -86), e)
				P.lean = 6.0 * e
			"upper":
				P.hF = Vector2(30, -60).lerp(Vector2(40, -142), e)
				P.lean = -3.0
			"kick":
				P.fF = Vector2(13, 0).lerp(Vector2(72, -58), e)
				P.lean = -10.0 * e
			"air":
				P.hF = Vector2(26, -66).lerp(Vector2(62, -48), e)
				P.fF = Vector2(20, -16)
				P.fB = Vector2(-8, -8)
			"blaze":
				var jab := 0.0
				for ti in [.26, .42, .62]:
					var u: float = a.t - ti
					if u > -.06 and u < .14:
						jab = maxf(jab, 1.0 - absf(u - .03) / .11)
				P.hF = Vector2(26, -66).lerp(Vector2(68, -86), clampf(jab, 0.0, 1.0))
				P.lean = 8.0
		return P
	if f.blocking:
		P.hF = Vector2(22, -88)
		P.hB = Vector2(18, -72)
		return P
	if not f.on_ground:
		P.fF = Vector2(16, -16)
		P.fB = Vector2(-10, -6)
		P.hF = Vector2(30, -84)
		P.hB = Vector2(-26, -80)
		return P
	if absf(f.vx) > 40.0:
		var s := sin(f.walk_ph)
		P.fF = Vector2(16 * s, -absf(cos(f.walk_ph)) * 4)
		P.fB = Vector2(-16 * s, -absf(sin(f.walk_ph + .7)) * 3)
		P.hF = Vector2(18 - 10 * s, -64)
		P.hB = Vector2(-10 + 10 * s, -62)
		P.lean = 4.0
	return P

func draw_fighter(w: Node2D, f: Fighter) -> void:
	var P := pose_of(f)
	var base := Vector2(f.x, f.y)
	var rot: float = P.rot
	var tp := func(v: Vector2) -> Vector2:
		var q := Vector2(v.x * f.face, v.y)
		return base + q.rotated(rot)
	var flash := f.white_t > 0.0
	if P.has("ball"):
		var c := base + Vector2(0, -28)
		for pass_i in (2 if flash else 1):
			var col := INK if (flash and pass_i == 0) else (Color.WHITE if flash else f.col)
			var lw := 8.0 if (flash and pass_i == 0) else 5.5
			w.draw_arc(c, 26, 0, TAU, 32, col, lw, true)
		w.draw_circle(c + Vector2(8 * f.face, -8), 9, Color.WHITE)
		w.draw_arc(c + Vector2(8 * f.face, -8), 9, 0, TAU, 20, f.col, 4.0, true)
		return
	var hip: Vector2 = tp.call(P.hip)
	var neck: Vector2 = tp.call(Vector2(P.lean, -92))
	var sh: Vector2 = tp.call(Vector2(P.lean * .9, -84))
	var head: Vector2 = tp.call(Vector2(P.lean + 2, -106))
	var segs := [[tp.call(P.fF), hip], [tp.call(P.fB), hip], [hip, neck], [sh, tp.call(P.hF)], [sh, tp.call(P.hB)]]
	var passes := [[INK, 9.0], [Color.WHITE, 5.5]] if flash else [[f.col, 5.5]]
	for ps in passes:
		for s in segs:
			w.draw_line(s[0], s[1], ps[0], ps[1], true)
			w.draw_circle(s[0], ps[1] / 2.0, ps[0])
			w.draw_circle(s[1], ps[1] / 2.0, ps[0])
	# head
	w.draw_circle(head, 13, Color.WHITE)
	w.draw_arc(head, 13, 0, TAU, 28, INK if flash else f.col, 4.5 if not flash else 3.0, true)
	if not flash:
		if f.brawler:
			# yellow headband with two flying tails
			w.draw_line(head + Vector2(-12.5, -5), head + Vector2(12.5, -5), Color("f6c928"), 4.5, true)
			var knot := head + Vector2(-12 * f.face, -4)
			w.draw_line(knot, knot + Vector2(-16 * f.face, 6 + sin(clock * 9) * 3), Color("f6c928"), 3.5, true)
			w.draw_line(knot, knot + Vector2(-13 * f.face, 13 + sin(clock * 9 + 1) * 3), Color("f6c928"), 3.5, true)
			for hnd in [P.hF, P.hB]:
				var hp: Vector2 = tp.call(hnd)
				w.draw_circle(hp, 6.5, Color("d1352b"))
				w.draw_arc(hp, 6.5, 0, TAU, 16, INK, 2.0, true)
		# eye
		var ex: Vector2 = head + Vector2(5 * f.face, -2)
		if f.ko:
			w.draw_line(ex + Vector2(-3, -3), ex + Vector2(3, 3), INK, 2.0)
			w.draw_line(ex + Vector2(-3, 3), ex + Vector2(3, -3), INK, 2.0)
		else:
			w.draw_circle(ex, 2.2, INK)

func draw_particles(w: Node2D) -> void:
	for p in particles:
		if p.t < 0.0:
			continue
		var q: float = p.t / p.life
		match p.type:
			"slash":
				# tapered crescent ribbon: white core (crimson if coloured), ink outline, sweeps open along the swing
				var u := minf(1.0, q * (4.5 if p.c != null else 3.2) + .15)
				var al := 1.0 if q < .55 else maxf(0.0, 1.0 - (q - .55) / .45)
				var n := 16
				var outer := PackedVector2Array()
				var inner := PackedVector2Array()
				for i in n + 1:
					var tt := float(i) / n
					var an: float = p.a0 + (p.a1 - p.a0) * u * tt
					var th: float = p.w * pow(sin(PI * minf(1.0, tt * 1.05)), .8) * (1.0 - q * .35)
					outer.append(p.p + Vector2(cos(an) * (p.r + th / 2) * p.face, sin(an) * (p.r + th / 2)))
					inner.append(p.p + Vector2(cos(an) * (p.r - th / 2) * p.face, sin(an) * (p.r - th / 2)))
				inner.reverse()
				var poly := outer + inner
				var fill: Color = p.c if p.c != null else Color.WHITE
				if Geometry2D.triangulate_polygon(poly).size() > 0:
					w.draw_colored_polygon(poly, with_alpha(fill, al))
				w.draw_polyline(closed(poly), with_alpha(INK, al), 2.6, true)
			"thrust":
				var al2 := 1.0 - q * q
				w.draw_line(p.p + Vector2(14 * p.face, 0), p.p + Vector2((p.r + 14) * p.face, 0), with_alpha(Color("ff6b00"), al2), 6.0 * (1.0 - q) + 2.0, true)
				w.draw_line(p.p + Vector2(p.r * .35 * p.face, -6), p.p + Vector2((p.r + 20) * p.face, 0), with_alpha(INK, al2 * .6), 1.5, true)
				w.draw_line(p.p + Vector2(p.r * .35 * p.face, 6), p.p + Vector2((p.r + 20) * p.face, 0), with_alpha(INK, al2 * .6), 1.5, true)
			"scrib":
				var L: float = p.len * (1.0 - q * .35)
				var pts := PackedVector2Array([p.p + Vector2(0, sin(p.sd + 1) * 1.6), p.p + Vector2(-p.dir * L * .45, sin(p.sd + 2) * 1.6), p.p + Vector2(-p.dir * L, sin(p.sd + 3) * 1.6)])
				w.draw_polyline(pts, with_alpha(INK if p.dk else Color("8d929c"), 1.0 - q), 2.0 if p.dk else 2.4, true)
			"star":
				# jagged 10-point starburst: yellow, orange, white core; leans along the hit
				var k := (.55 + q / .25 * .6) if q < .25 else (1.15 - (q - .25) * .3)
				var al3 := 1.0 if q < .7 else maxf(0.0, 1.0 - (q - .7) / .3)
				var sx := 1.3 if p.dir != 0 else 1.0
				var sy := .85 if p.dir != 0 else 1.0
				for layer in [[1.0, .52, Color("fff200"), 3.0], [.55, .55, Color("ff5500"), 1.6], [.22, .6, Color.WHITE, 0.0]]:
					var R: float = p.r * k * layer[0]
					var sp := PackedVector2Array()
					for i in 20:
						var an: float = p.rot + i / 20.0 * TAU
						var jj: float = 1.0 + sin(p.sd + i * 2.3) * .12
						var rr: float = (R * layer[1] if i % 2 else R) * jj
						sp.append(p.p + Vector2(cos(an) * rr * sx, sin(an) * rr * sy))
					w.draw_colored_polygon(sp, with_alpha(layer[2], al3))
					if layer[3] > 0.0:
						w.draw_polyline(closed(sp), with_alpha(INK, al3), layer[3], true)
			"puff":
				# grey cartoon cloud with an ink outline
				var r: float = p.r * (.7 + q * .7)
				var al4 := (1.0 - q) * .95
				var cs := [[Vector2(-r * .45, 0), r * .7], [Vector2(r * .35, -r * .3), r * .8], [Vector2(r * .2, r * .3), r * .55]]
				for c in cs:
					w.draw_arc(p.p + c[0], c[1], 0, TAU, 20, with_alpha(INK, al4), 1.8, true)
				for c in cs:
					w.draw_circle(p.p + c[0], c[1] - .9, with_alpha(Color("d9d9d9"), al4))
			"ink":
				# velocity-stretched paint drop
				var sp2: float = p.v.length()
				var L2: float = p.r * (1.0 + minf(2.2, sp2 / 260.0))
				var ang: float = p.v.angle()
				var dp := PackedVector2Array()
				for i in 12:
					var a2 := float(i) / 12.0 * TAU
					var rx: float = p.r if cos(a2) > 0 else L2
					dp.append(p.p + Vector2(cos(a2) * rx, sin(a2) * p.r * .8).rotated(ang))
				w.draw_colored_polygon(dp, p.c)
				w.draw_polyline(closed(dp), INK, 1.2, true)
			"surge":
				# tapered flame comet: orange body, white-hot core, 3.5px ink outline
				var hd := minf(1.0, 1.0 - pow(1.0 - minf(1.0, q / .42), 3))
				var tl := maxf(0.0, (q - .18) / .82)
				var hx: float = p.dir * p.len * hd
				var tx: float = p.dir * p.len * minf(hd, tl * 1.05)
				var al5 := 1.0 if q < .72 else maxf(0.0, 1.0 - (q - .72) / .28)
				var R0 := 24.0 * (1.0 - q * .35)
				for layer2 in [[R0, true, Color("ff6b00")], [R0 * .45, false, Color.WHITE]]:
					var th2: float = layer2[0]
					var top := PackedVector2Array()
					var bot := PackedVector2Array()
					for i in 19:
						var uu := i / 18.0
						var xx: float = tx + (hx - tx) * uu
						var hh: float = th2 * pow(uu, .7) * (1.0 + (sin(uu * 17.0 + p.t * 45.0 + p.sd) * .12 if layer2[1] else 0.0))
						top.append(p.p + Vector2(xx, -hh))
						bot.append(p.p + Vector2(xx, hh))
					var cap := PackedVector2Array()
					for i in 9:
						var a3: float = -PI / 2 + i / 8.0 * PI
						cap.append(p.p + Vector2(hx + cos(a3) * th2 * p.dir, sin(a3) * th2))
					bot.reverse()
					var shape := top + cap + bot
					if Geometry2D.triangulate_polygon(shape).size() > 0:
						w.draw_colored_polygon(shape, with_alpha(layer2[2], al5))
					if layer2[1]:
						w.draw_polyline(closed(shape), with_alpha(INK, al5), 3.5, true)
			"shock":
				# two rings that grow and thin out over 0.25 s
				var rr2 := 18.0 + q * 100.0
				var th3 := 1.0 - q
				w.draw_polyline(closed(ellipse_pts(p.p, rr2 * .42, rr2)), INK, 6.0 * th3 + 1.6, true)
				w.draw_polyline(closed(ellipse_pts(p.p, rr2 * .42, rr2)), Color("ff6b00"), 3.0 * th3 + .6, true)
				var ic: Vector2 = p.p + Vector2(-p.dir * 6, 0)
				w.draw_polyline(closed(ellipse_pts(ic, rr2 * .3, rr2 * .7)), INK, 5.0 * th3 + 2.0, true)
				w.draw_polyline(closed(ellipse_pts(ic, rr2 * .3, rr2 * .7)), Color.WHITE, maxf(.5, 5.0 * th3), true)
			"flame":
				var al6 := minf(1.0, (1.0 - q) * 1.6)
				var L3: float = p.r * (1.0 + minf(3.0, p.v.length() / 200.0))
				var ang2: float = p.v.angle()
				var fp := PackedVector2Array()
				for i in 12:
					var a4 := float(i) / 12.0 * TAU
					var rx2: float = p.r if cos(a4) > 0 else L3
					fp.append(p.p + Vector2(cos(a4) * rx2, sin(a4) * p.r * .7).rotated(ang2))
				w.draw_colored_polygon(fp, with_alpha(Color("ff6b00"), al6))
				w.draw_polyline(closed(fp), with_alpha(INK, al6), 1.6, true)
				w.draw_colored_polygon(ellipse_pts(p.p, p.r * .45, p.r * .3, 10), with_alpha(Color.WHITE, al6))

# ---------------------------------------------------------------- HUD (screen space)
func _draw_hud() -> void:
	var h := hud
	var vs := get_viewport_rect().size
	var cx := vs.x / 2.0
	# health and special bars
	for side in 2:
		var f: Fighter = p1 if side == 0 else p2
		var x0 := 20.0 if side == 0 else vs.x - 20.0 - 360.0
		h.draw_string(font, Vector2(x0, 22), f.name + (" · YOU" if side == 0 and not selftest else ""), HORIZONTAL_ALIGNMENT_LEFT if side == 0 else HORIZONTAL_ALIGNMENT_RIGHT, 360, 15, INK)
		var r := Rect2(x0, 28, 360, 20)
		h.draw_rect(r, Color.WHITE)
		var fr := f.hp / f.max_hp
		var hr := Rect2(x0 + (0.0 if side == 0 else 360.0 * (1.0 - fr)), 28, 360.0 * fr, 20)
		h.draw_rect(hr, f.col)
		h.draw_rect(r, INK, false, 2.5)
		var sr := Rect2(x0 + (0.0 if side == 0 else 160.0), 52, 200, 9)
		h.draw_rect(sr, Color.WHITE)
		var sf := f.spec / 100.0
		h.draw_rect(Rect2(sr.position.x + (0.0 if side == 0 else 200.0 * (1.0 - sf)), 52, 200.0 * sf, 9), Color("f6c928") if f.spec >= 100.0 else Color("e9b949"))
		h.draw_rect(sr, INK, false, 2.0)
		for k in WINS_NEEDED:
			var dc := Vector2(cx + (-60.0 - k * 18.0 if side == 0 else 60.0 + k * 18.0), 72)
			h.draw_circle(dc, 6, f.col if wins[side] > k else Color.WHITE)
			h.draw_arc(dc, 6, 0, TAU, 16, INK, 2.0, true)
	h.draw_circle(Vector2(cx, 36), 26, Color.WHITE)
	h.draw_arc(Vector2(cx, 36), 26, 0, TAU, 32, INK, 3.0, true)
	h.draw_string(font, Vector2(cx - 30, 45), str(int(ceil(time_left))), HORIZONTAL_ALIGNMENT_CENTER, 60, 24, INK)
	# banner and special callout
	if banner != "":
		var a := minf(1.0, banner_t / .1) * (1.0 if banner_t < .8 else maxf(0.0, 1.0 - (banner_t - .8) / .2))
		if phase == "over":
			a = 1.0
		var bc := Color("d1352b") if banner in ["FIGHT!", "K.O.!", "YOU LOSE"] else Color("1d4fd7")
		h.draw_string_outline(font, Vector2(0, H * .4), banner, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 64, 12, with_alpha(Color.WHITE, a))
		h.draw_string(font, Vector2(0, H * .4), banner, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 64, with_alpha(bc, a))
		if phase == "over":
			h.draw_string(font, Vector2(0, H * .4 + 44), "Tap or press Enter to play again", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 20, INK)
	if callout != "":
		var a2 := minf(1.0, callout_t / .08) * (1.0 if callout_t < .9 else maxf(0.0, 1.0 - (callout_t - .9) / .25))
		h.draw_string_outline(font, Vector2(0, 118), callout, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 38, 10, with_alpha(Color.WHITE, a2))
		h.draw_string(font, Vector2(0, 118), callout, HORIZONTAL_ALIGNMENT_CENTER, vs.x, 38, with_alpha(callout_col, a2))
	# touch buttons (see-through, like the HTML pad)
	if touch_on and not selftest:
		var lab := {"left": "◀", "right": "▶", "punch": "PUNCH", "kick": "KICK", "jump": "▲", "block": "BLOCK", "special": "SPECIAL"}
		for id in BTN:
			var c := btn_pos(id)
			var held := touches.values().has(id)
			var fill := Color(1, 1, 1, .55 if held else .3)
			if id == "special" and p1.spec >= 100.0:
				fill = Color(.965, .788, .157, .75)
			h.draw_circle(c, BTN_R, fill)
			h.draw_arc(c, BTN_R, 0, TAU, 36, Color(.1, .1, .1, .7), 3.0, true)
			var fs := 13 if lab[id].length() > 2 else 26
			h.draw_string(font, c + Vector2(-BTN_R, fs * .35), lab[id], HORIZONTAL_ALIGNMENT_CENTER, BTN_R * 2, fs, Color(.1, .1, .1, .85))
	elif not selftest and phase == "intro" and round_no == 1:
		h.draw_string(font, Vector2(0, vs.y - 18), "A/D move · W jump · J punch · K kick · L block · Space special · double-tap A/D to dodge", HORIZONTAL_ALIGNMENT_CENTER, vs.x, 15, Color(.1, .1, .1, .7))
