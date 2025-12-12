extends Node2D

# --- REFERENCIAS A OBJETOS DE LA ESCENA (NODOS) ---
# Asumo que estos están en la raíz, como en tu script original
@onready var capa_fondo = $Fondo
@onready var capa_camino = $Camino
@onready var cursor_visual = $Cursor
@onready var camara = $Camera2D

# --- REFERENCIAS A LA INTERFAZ (UI) SEGÚN TUS IMÁGENES ---
@onready var ui_salas_restantes = $CanvasLayer/Label # El texto de arriba del todo

# Contenedor VBox
@onready var input_niveles = $CanvasLayer/VBoxContainer/HBoxContainer/TXT_NivelesCompletados
@onready var input_pasillos = $CanvasLayer/VBoxContainer/HBoxContainer2/TXT_MaxPasillos
@onready var slider_velocidad = $CanvasLayer/VBoxContainer/HBoxContainer3/HSlider_VelAnim
@onready var check_semilla = $CanvasLayer/VBoxContainer/HBoxContainer4/CheckButton
@onready var input_semilla = $CanvasLayer/VBoxContainer/HBoxContainer5/TXT_Seed
@onready var play_button = $CanvasLayer/VBoxContainer/PlayButton

# --- CONFIGURACIÓN INTERNA ---
# Valores por defecto (se sobrescriben con lo que pongas en la UI)
var niveles_completados: int = 0 
var max_pasillos: int = 5
var usar_semilla_fija: bool = false
var valor_semilla: int = 123456

# --- CONFIGURACIÓN DE TIEMPOS (BASE) ---
# Estas son las velocidades "Normales" (x1)
var delay_paso_gusano: float = 0.1       
var delay_escaner_mover: float = 0.01    
var delay_escaner_hallazgo: float = 0.15 
var delay_seleccion_confirmar: float = 0.25 
var delay_entre_extracciones: float = 0.5   
var delay_entre_loot: float = 0.5            
var delay_recorrer_cursor: float = 0.03  
var delay_colocar_pasillo: float = 0.5   
var animacion_duracion: float = 0.6      

# --- VARIABLES DEL GENERADOR ---
const GRID_SIZE = 20
const TILE_SIZE = 32
const ATLAS_COORDS = Vector2i(0, 0)
const SOURCE_ID = 0

var num_salas_objetivo = 0
var num_extracciones = 0
var num_loot_rooms = 0 
var num_pasillos = 0

var posiciones_ocupadas = []
var posicion_primera_sala = Vector2i(GRID_SIZE/2, GRID_SIZE - 1)
var cabeza_pos = posicion_primera_sala
var generando = false

var candidatos_globales = []
var lista_evitar = [] 

var sprites_grises = []
var sprites_rojos = []
var sprites_dorados = []
var sprites_pasillos = [] 
var nodo_nave_visual = null 

func _ready():
	print("--- R.E.P.O SIMULATOR INICIADO ---")
	
	# Configuración inicial de cámara y rejilla
	dibujar_rejilla_base()
	var tamaño_mapa_pixeles = Vector2(GRID_SIZE, GRID_SIZE) * TILE_SIZE
	var centro_mapa = tamaño_mapa_pixeles / 2.0
	camara.position = centro_mapa
	actualizar_visuales_cursor()
	
	# Conectar el botón Play
	if play_button:
		play_button.pressed.connect(_on_play_button_pressed)
	else:
		printerr("ERROR: No encuentro el PlayButton. Revisa la ruta en el script.")

# --- FUNCIÓN PRINCIPAL AL PULSAR PLAY ---
func _on_play_button_pressed():
	if generando: return # Evitar doble clic
	
	# 1. LEER DATOS DE LA UI (Niveles, Semilla, etc.)
	leer_configuracion_de_ui()
	
	# 2. INICIAR LA SECUENCIA
	ejecutar_secuencia_completa()

func leer_configuracion_de_ui():
	# Leemos los LineEdit. Usamos "text" y lo convertimos a "int"
	if input_niveles:
		niveles_completados = int(input_niveles.text)
	
	if input_pasillos:
		max_pasillos = int(input_pasillos.text)
		
	if check_semilla:
		usar_semilla_fija = check_semilla.button_pressed
		
	if input_semilla:
		valor_semilla = int(input_semilla.text)

# --- CALCULADORA DE VELOCIDAD ---
func obtener_delay(tiempo_base: float) -> float:
	var multiplicador = 1.0
	# Leemos el valor del slider en tiempo real
	if slider_velocidad:
		multiplicador = slider_velocidad.value
	
	# Evitar dividir por cero o números negativos
	if multiplicador <= 0.1: multiplicador = 0.1
	
	return tiempo_base / multiplicador

# --- ORQUESTADOR DE LA SECUENCIA ---
func ejecutar_secuencia_completa():
	limpiar_todo()
	
	# Configurar semilla
	if usar_semilla_fija:
		seed(valor_semilla)
		print(">>> SEMILLA FIJA: ", valor_semilla)
	else:
		randomize()
		var semilla_random = randi()
		seed(semilla_random)
		print(">>> SEMILLA RANDOM: ", semilla_random)
		# Opcional: Escribir la semilla random en el input para que el usuario la vea
		if input_semilla: input_semilla.text = str(semilla_random)
	
	calcular_formulas_oficiales() 
	
	# SECUENCIA DE FASES (Con esperas dinámicas)
	await generar_mazmorra()
	await espera_dinamica(0.3)
	
	await escanear_matriz_completa()
	await espera_dinamica(0.3)
	
	await ejecutar_seleccion_extracciones()
	await espera_dinamica(0.3)
	
	await ejecutar_seleccion_loot()
	await espera_dinamica(0.3)
	
	await generar_pasillos_finales()
	print(">>> SECUENCIA COMPLETADA <<<")

# Pequeña ayuda para esperar entre fases afectado por el slider
func espera_dinamica(tiempo: float):
	await get_tree().create_timer(obtener_delay(tiempo)).timeout

func calcular_formulas_oficiales():
	var base = min(5 + niveles_completados, 10)
	var extra = 0
	if niveles_completados >= 10:
		extra = min(niveles_completados - 9, 5)
	num_salas_objetivo = base + extra
	
	if num_salas_objetivo >= 15: num_extracciones = 4
	elif num_salas_objetivo >= 10: num_extracciones = 3
	elif num_salas_objetivo >= 8: num_extracciones = 2
	elif num_salas_objetivo >= 6: num_extracciones = 1
	else: num_extracciones = 0
	num_loot_rooms = ceil(float(num_salas_objetivo) / 3.0)

# ==========================================
#              FASES DEL JUEGO
# ==========================================

# --- FASE 1: GUSANO (Generar mapa) ---
func generar_mazmorra():
	generando = true
	var salas_por_poner = num_salas_objetivo 
	var direccion = Vector2i.UP
	
	cabeza_pos = posicion_primera_sala
	posiciones_ocupadas.append(cabeza_pos)
	pintar_suelo_brillante(cabeza_pos)
	
	salas_por_poner -= 1 
	if ui_salas_restantes: ui_salas_restantes.text = "NÚMERO DE SALAS: " + str(salas_por_poner)
	actualizar_visuales_cursor()
	
	await get_tree().create_timer(obtener_delay(delay_paso_gusano)).timeout

	while salas_por_poner > 0:
		await get_tree().create_timer(obtener_delay(delay_paso_gusano)).timeout
		
		if randf() > 0.1: 
			direccion = obtener_direccion_random()
		
		var siguiente_paso = cabeza_pos + direccion
		
		if not es_valido(siguiente_paso):
			direccion = obtener_direccion_random()
			continue 
			
		cabeza_pos = siguiente_paso
		actualizar_visuales_cursor()
		
		if cabeza_pos not in posiciones_ocupadas:
			posiciones_ocupadas.append(cabeza_pos)
			pintar_suelo_brillante(cabeza_pos)
			salas_por_poner -= 1
			if ui_salas_restantes: ui_salas_restantes.text = "NÚMERO DE SALAS: " + str(salas_por_poner)
	
	crear_nave_visual_externa()
	cursor_visual.visible = false
	generando = false

# --- FASE 2: ESCÁNER (Grid Azul) ---
func escanear_matriz_completa():
	generando = true
	candidatos_globales.clear()
	cursor_visual.visible = true
	cursor_visual.modulate = Color(0, 1, 1) # Cyan
	
	for y in range(GRID_SIZE):
		for x in range(GRID_SIZE):
			var pos_actual = Vector2i(x, y)
			cursor_visual.position = (Vector2(pos_actual) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
			
			if pos_actual in posiciones_ocupadas:
				continue
			
			await get_tree().create_timer(obtener_delay(delay_escaner_mover)).timeout
			
			if contar_vecinos_activos(pos_actual) == 1:
				candidatos_globales.append(pos_actual)
				cursor_visual.scale = Vector2(0.8, 0.8)
				marcar_gris(pos_actual)
				await get_tree().create_timer(obtener_delay(delay_escaner_hallazgo)).timeout
				cursor_visual.scale = Vector2(0.5, 0.5)

	generando = false
	cursor_visual.visible = false

# --- FASE 3: EXTRACCIONES (Rojo) ---
func ejecutar_seleccion_extracciones():
	generando = true
	cursor_visual.visible = true
	cursor_visual.modulate = Color(1, 0, 0) # Rojo
	
	lista_evitar.clear()
	lista_evitar.append(posicion_primera_sala)
	
	var a_colocar = num_extracciones
	
	while a_colocar > 0 and candidatos_globales.size() > 0:
		var mejor = buscar_mejor_candidato_maximin()
		if mejor != null:
			animar_cursor_seleccion(mejor)
			
			await get_tree().create_timer(obtener_delay(delay_seleccion_confirmar)).timeout
			
			spawn_sprite_animado(mejor, Color(1.3, 0.0, 0.0, 1.0), 0.7, sprites_rojos)
			lista_evitar.append(mejor)
			candidatos_globales.erase(mejor)
			eliminar_vecinos_de_candidatos(mejor)
			a_colocar -= 1
			
			if a_colocar > 0:
				await get_tree().create_timer(obtener_delay(delay_entre_extracciones)).timeout
				
		else: break
	cursor_visual.visible = false
	generando = false

# --- FASE 4: BOTÍN (Dorado) ---
func ejecutar_seleccion_loot():
	generando = true
	cursor_visual.visible = true
	cursor_visual.modulate = Color(1, 0.84, 0) # Dorado
	
	var a_colocar = num_loot_rooms
	
	while a_colocar > 0 and candidatos_globales.size() > 0:
		var mejor = candidatos_globales.pick_random()
		if mejor != null:
			animar_cursor_seleccion(mejor)
			
			await get_tree().create_timer(obtener_delay(delay_seleccion_confirmar)).timeout
			
			spawn_sprite_animado(mejor, Color(1.4, 1.0, 0.0, 1.0), 0.7, sprites_dorados)
			lista_evitar.append(mejor)
			candidatos_globales.erase(mejor)
			eliminar_vecinos_de_candidatos(mejor)
			a_colocar -= 1
			
			if a_colocar > 0:
				await get_tree().create_timer(obtener_delay(delay_entre_loot)).timeout
				
		else: break
	cursor_visual.visible = false
	generando = false

# --- FASE 5: PASILLOS (Gris claro) ---
func generar_pasillos_finales():
	generando = true
	cursor_visual.visible = true
	cursor_visual.modulate = Color(0.8, 0.8, 0.8) 
	cursor_visual.scale = Vector2(1, 1) 
	
	# Reseteamos contador local
	num_pasillos = 0 
	
	for sala in posiciones_ocupadas:
		cursor_visual.position = (Vector2(sala) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
		
		await get_tree().create_timer(obtener_delay(delay_recorrer_cursor)).timeout
		
		if num_pasillos >= max_pasillos: break
		if sala in lista_evitar: continue
			
		var vecino_up = (sala + Vector2i.UP) in posiciones_ocupadas
		var vecino_down = (sala + Vector2i.DOWN) in posiciones_ocupadas
		var vecino_left = (sala + Vector2i.LEFT) in posiciones_ocupadas
		var vecino_right = (sala + Vector2i.RIGHT) in posiciones_ocupadas
		
		var es_pasillo = false
		if vecino_up and vecino_down and not vecino_left and not vecino_right: es_pasillo = true
		elif vecino_left and vecino_right and not vecino_up and not vecino_down: es_pasillo = true
			
		if es_pasillo and randf() < 0.5:
			spawn_sprite_animado(sala, Color(1.2, 1.2, 1.2, 1.0), 0.7, sprites_pasillos)
			num_pasillos += 1
			await get_tree().create_timer(obtener_delay(delay_colocar_pasillo)).timeout
	
	cursor_visual.visible = false
	generando = false

# ==========================================
#              HELPERS / UTILIDADES
# ==========================================

func crear_nave_visual_externa():
	if nodo_nave_visual: nodo_nave_visual.queue_free()
	var nave = Sprite2D.new()
	nave.texture = cursor_visual.texture
	nave.modulate = Color(0.2, 0.5, 2.0, 1.0) 
	var pos_grid_ficticia = Vector2(posicion_primera_sala.x, GRID_SIZE)
	nave.position = (pos_grid_ficticia * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
	nave.z_index = 2
	nave.scale = Vector2(0,0)
	add_child(nave)
	nodo_nave_visual = nave
	
	var duracion_real = obtener_delay(0.5)
	var tween = create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(nave, "scale", Vector2(1,1), duracion_real)

func spawn_sprite_animado(pos, color, escala_final, lista_ref):
	var m = Sprite2D.new()
	m.texture = cursor_visual.texture
	m.position = (Vector2(pos) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
	m.z_index = 1
	add_child(m)
	lista_ref.append(m)
	m.scale = Vector2(0, 0) 
	m.modulate = Color(10, 10, 10, 1) 
	
	# Animación también afectada por velocidad
	var duracion_real = obtener_delay(animacion_duracion)
	
	var tween = create_tween()
	tween.set_trans(Tween.TRANS_ELASTIC)
	tween.set_ease(Tween.EASE_OUT)
	tween.tween_property(m, "scale", Vector2(escala_final, escala_final), duracion_real)
	tween.parallel().set_trans(Tween.TRANS_SINE).tween_property(m, "modulate", color, duracion_real * 0.5)
	return m

func animar_cursor_seleccion(pos):
	cursor_visual.position = (Vector2(pos) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
	cursor_visual.scale = Vector2(1.5, 1.5)

func marcar_gris(pos):
	var m = Sprite2D.new()
	m.texture = cursor_visual.texture
	m.modulate = Color(0.5, 0.5, 0.5, 0.6)
	m.scale = Vector2(0.4, 0.4)
	m.position = (Vector2(pos) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)
	m.z_index = 1
	add_child(m)
	sprites_grises.append(m)

func buscar_mejor_candidato_maximin():
	var mejor_candidato = null
	var max_distancia = -1.0
	for cand in candidatos_globales:
		var min_dist_a_peligro = 999999.0
		for peligro in lista_evitar:
			var d = Vector2(cand).distance_to(Vector2(peligro))
			if d < min_dist_a_peligro: min_dist_a_peligro = d
		if min_dist_a_peligro > max_distancia:
			max_distancia = min_dist_a_peligro
			mejor_candidato = cand
	return mejor_candidato

func es_valido(pos):
	return pos.x >= 0 and pos.x < GRID_SIZE and pos.y >= 0 and pos.y < GRID_SIZE

func obtener_direccion_random():
	return [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT].pick_random()

func dibujar_rejilla_base():
	if capa_fondo:
		for x in range(GRID_SIZE):
			for y in range(GRID_SIZE):
				capa_fondo.set_cell(Vector2i(x,y), SOURCE_ID, ATLAS_COORDS)

func pintar_suelo_brillante(pos_grid):
	if capa_camino:
		capa_camino.set_cell(pos_grid, SOURCE_ID, ATLAS_COORDS)

func actualizar_visuales_cursor():
	cursor_visual.position = (Vector2(cabeza_pos) * TILE_SIZE) + Vector2(TILE_SIZE/2, TILE_SIZE/2)

func contar_vecinos_activos(pos):
	var contador = 0
	for dir in [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]:
		if (pos + dir) in posiciones_ocupadas: contador += 1
	return contador

func eliminar_vecinos_de_candidatos(ganador):
	var dirs = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	for dir in dirs:
		var vecino = ganador + dir
		if vecino in candidatos_globales:
			candidatos_globales.erase(vecino)

func limpiar_todo():
	for lista in [sprites_grises, sprites_rojos, sprites_dorados, sprites_pasillos]:
		for m in lista: 
			if is_instance_valid(m): m.queue_free()
		lista.clear()
	
	if nodo_nave_visual and is_instance_valid(nodo_nave_visual): 
		nodo_nave_visual.queue_free()
	
	candidatos_globales.clear()
	lista_evitar.clear()
	posiciones_ocupadas.clear()
	
	dibujar_rejilla_base()
	if capa_camino: capa_camino.clear() 
	cursor_visual.visible = true
