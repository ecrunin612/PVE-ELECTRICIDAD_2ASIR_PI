#!/bin/bash
#╔══════════════════════════════════════════════════════════════════════════════╗
#║                     SCRIPT DE GESTIÓN PROXMOX v7.5                           ║
#║                  Administración masiva de usuarios, VMs y CTs                ║
#║                                                                              ║
#║  Autor: Esther CN                                                            ║
#║  Departamento: Electricidad                                                  ║
#║  Año: 2026                                                                   ║
#╚══════════════════════════════════════════════════════════════════════════════╝
#
# Descripción: Herramienta interactiva para administrar de forma masiva
#              usuarios, máquinas virtuales, contenedores y pools en Proxmox VE.
#              Incluye validación avanzada de archivos, notificaciones
#              por correo electrónico, menús optimizados y asistente de IPs
#              con exportación de resultados.
#
# Requisitos: Ejecutar como root en un servidor Proxmox VE con jq instalado.
#

#---------------------------------------------------------
# CONFIGURACIÓN GLOBAL
#---------------------------------------------------------

API_TIMEOUT=30
MAX_RETRIES=3
LOG_FILE="$HOME/registro.log"
EMAIL_NOTIFICACION="admin@example.edu"
TEMP_DIR="/tmp/proxmox_gestion_$$"

#---------------------------------------------------------
# FUNCIONES DE REGISTRO (LOG)
#---------------------------------------------------------

function log_message {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%d-%m-%Y %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

function log_error { log_message "ERROR" "$1"; }
function log_info { log_message "INFO" "$1"; }
function log_success { log_message "SUCCESS" "$1"; }
function log_warning { log_message "WARNING" "$1"; }
function log_debug { log_message "DEBUG" "$1"; }

#---------------------------------------------------------
# FUNCIONES DE CORREO
#---------------------------------------------------------

function EnviarNotificacion {
    if [ -z "$EMAIL_NOTIFICACION" ]; then
        return 0
    fi
    
    whiptail --title "NOTIFICACION" --yesno "Desea enviar un resumen por correo a:\n$EMAIL_NOTIFICACION ?" 10 55
    if [ $? -ne 0 ]; then
        log_info "Usuario omitio el envio de notificacion por correo"
        return 0
    fi
    
    local asunto="$1"
    local mensaje="$2"
    local fecha=$(date '+%d-%m-%Y %H:%M:%S')
    
    printf -v correo '
══════════════════════════════════════════════════════════════
              PROXMOX GESTION - NOTIFICACION
══════════════════════════════════════════════════════════════

  Fecha y hora..: %s
  Servidor......: %s
  Administrador.: %s
  Operacion.....: %s

══════════════════════════════════════════════════════════════

%s

══════════════════════════════════════════════════════════════
  Script: PROXMOX Gestion Masiva v7.5
  Autor: Esther CN - Dpto. Electricidad
══════════════════════════════════════════════════════════════
' "$fecha" "$(hostname)" "$USER" "$asunto" "$mensaje"
    
    echo "$correo" | mail -s "[Proxmox] $asunto" "$EMAIL_NOTIFICACION" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_info "Notificacion enviada a $EMAIL_NOTIFICACION"
    else
        log_warning "No se pudo enviar notificacion a $EMAIL_NOTIFICACION"
    fi
}

#---------------------------------------------------------
# FUNCIONES AUXILIARES
#---------------------------------------------------------

function Limpieza {
    rm -f desbloqueatemp opcion numestemp poolstemp eliminatemp1 grouptemp bloqueatemp apagatemp progreso_temp error_temp miembros_temp ips_temp csv_temp creados_temp errores_temp export_temp correo_temp &>/dev/null
    rm -rf "$TEMP_DIR" &>/dev/null
    mkdir -p "$TEMP_DIR"
}

function CheckAPI {
    local intentos=0
    while [ $intentos -lt $MAX_RETRIES ]; do
        if timeout $API_TIMEOUT pvesh get /nodes --output-format=json &>/dev/null; then
            return 0
        fi
        intentos=$((intentos + 1))
        sleep 2
    done
    log_error "No se pudo conectar con la API de Proxmox despues de $MAX_RETRIES intentos"
    return 1
}

function EjecutarComando {
    local comando="$1"
    local mensaje_error="${2:-Error al ejecutar el comando}"
    local intentos=0
    
    while [ $intentos -lt $MAX_RETRIES ]; do
        if timeout $API_TIMEOUT bash -c "$comando" 2>/tmp/error_temp; then
            return 0
        fi
        local error_msg=$(cat /tmp/error_temp 2>/dev/null)
        intentos=$((intentos + 1))
        if [ $intentos -lt $MAX_RETRIES ]; then
            log_warning "Reintento $intentos: $comando - $error_msg"
            sleep 2
        fi
    done
    
    local error_final=$(cat /tmp/error_temp 2>/dev/null)
    log_error "$mensaje_error - Comando: $comando - Detalle: $error_final"
    return 1
}

function MensajeBox {
    whiptail --title "$2" --msgbox "$1" 16 65
}

function SePuedeLeer {
    if [ ! -f "$1" ]; then
        MensajeBox "Imposible crear ficheros temporales.\nVerifica permisos en $(pwd)" "ERROR"
        exit 4
    fi
}

#---------------------------------------------------------
# PANTALLA DE ESPERA (TRANSICIONES SUAVES SIN SALIR DE WHIPTAIL)
#---------------------------------------------------------

function PantallaEspera {
    local mensaje="$1"
    local segundos="${2:-1}"
    
    {
        for (( i=0; i<=100; i+=10 )); do
            echo "$i"
            echo "$mensaje"
            sleep 0.1
        done
        echo "100"
    } | whiptail --title "PROXMOX GESTION" --gauge "Preparando..." 8 60 0
}

#---------------------------------------------------------
# VALIDACIÓN AVANZADA DE ARCHIVOS CSV
#---------------------------------------------------------

function ValidarCSVUsuarios {
    local archivo="$1"
    local errores=0
    local linea=0
    local lineas_con_error=""
    
    log_info "Iniciando validacion avanzada de usuarios: $archivo"
    
    while IFS=";" read -r nombre apellido correo; do
        linea=$((linea + 1))
        
        if [ $linea -eq 1 ]; then
            if ! echo "$nombre;$apellido;$correo" | grep -qi "nombre.*apellido.*correo"; then
                lineas_con_error="$lineas_con_error\n  Linea $linea: Cabecera incorrecta"
                errores=$((errores + 1))
            fi
            continue
        fi
        
        if [ -z "$nombre" ] || [ -z "$correo" ]; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: Campos vacios"
            errores=$((errores + 1))
            continue
        fi
        
        if ! echo "$correo" | grep -q "@"; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: Correo sin @ ($correo)"
            errores=$((errores + 1))
            continue
        fi
        
        local usuario=$(echo "$correo" | cut -d "@" -f1)
        if [ -z "$usuario" ]; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: Sin usuario antes del @"
            errores=$((errores + 1))
        fi
    done < "$archivo"
    
    if [ $errores -gt 0 ]; then
        whiptail --title "ERRORES EN EL ARCHIVO" --msgbox "Se encontraron $errores error(es):\n$lineas_con_error\n\nCorrija estos errores antes de continuar." 18 70
        log_error "Validacion fallida: $errores errores en $archivo"
        return 1
    else
        log_success "Validacion de usuarios completada: $((linea - 1)) registros correctos"
        return 0
    fi
}

function ValidarCSVPlantillas {
    local archivo="$1"
    local errores=0
    local linea=0
    local lineas_con_error=""
    
    log_info "Iniciando validacion avanzada de plantillas: $archivo"
    
    while IFS=";" read -r plantilla pool rangoStart rangoEnd; do
        linea=$((linea + 1))
        
        if [ $linea -eq 1 ]; then
            if ! echo "$plantilla;$pool" | grep -qi "plantilla.*pool"; then
                lineas_con_error="$lineas_con_error\n  Linea $linea: Cabecera incorrecta"
                errores=$((errores + 1))
            fi
            continue
        fi
        
        if [ -z "$plantilla" ] || [ -z "$pool" ] || [ -z "$rangoStart" ] || [ -z "$rangoEnd" ]; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: Campos vacios"
            errores=$((errores + 1))
            continue
        fi
        
        if ! [[ "$rangoStart" =~ ^[0-9]+$ ]]; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: RangoStart no numerico ($rangoStart)"
            errores=$((errores + 1))
        fi
        
        if ! [[ "$rangoEnd" =~ ^[0-9]+$ ]]; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: RangoEnd no numerico ($rangoEnd)"
            errores=$((errores + 1))
        fi
        
        if [[ "$rangoStart" =~ ^[0-9]+$ ]] && [[ "$rangoEnd" =~ ^[0-9]+$ ]]; then
            if [ "$rangoStart" -gt "$rangoEnd" ]; then
                lineas_con_error="$lineas_con_error\n  Linea $linea: Rango invertido ($rangoStart > $rangoEnd)"
                errores=$((errores + 1))
            fi
        fi
        
        if [ -n "$pool" ] && ! echo "$pool" | grep -q "^[a-zA-Z]"; then
            lineas_con_error="$lineas_con_error\n  Linea $linea: Pool '$pool' no empieza con letra"
            errores=$((errores + 1))
        fi
    done < "$archivo"
    
    if [ $errores -gt 0 ]; then
        whiptail --title "ERRORES EN EL ARCHIVO" --msgbox "Se encontraron $errores error(es):\n$lineas_con_error\n\nCorrija estos errores antes de continuar." 18 70
        log_error "Validacion fallida: $errores errores en $archivo"
        return 1
    else
        log_success "Validacion de plantillas completada: $((linea - 1)) registros correctos"
        return 0
    fi
}

#---------------------------------------------------------
# NAVEGADOR DE ARCHIVOS
#---------------------------------------------------------

function NavegadorFiles {
    unset fichero 
    
    if [ -z "$1" ]; then
        ruta=$(ls -lhp "$(pwd)" | awk -F ' ' ' { print $9 " " $5 } ')
    else
        ruta=$(ls -lhp "$1" | awk -F ' ' ' { print $9 " " $5 } ')
    fi

    rutaselect=$(whiptail --title "NAVEGADOR DE ARCHIVOS" --menu "Selecciona el fichero:" 22 75 15 \
        --cancel-button "Volver" --ok-button "Seleccionar" \
        "../" "Subir al directorio superior" $ruta 3>&1 1>&2 2>&3)

    Salida=$?
    if [ $Salida -eq 1 ]; then
        return 1
    elif [ $Salida -eq 0 ]; then
        target="${1:+$1/}$rutaselect"
        if [[ -d "$target" ]]; then
            NavegadorFiles "$target"
        elif [[ -f "$target" ]]; then
            fichero=$(readlink -m "$target")
            unset rutaselect
            return 0
        fi
    fi
}

#---------------------------------------------------------
# NAVEGADOR DE DIRECTORIOS (SOLO CARPETAS)
#---------------------------------------------------------

function NavegadorDirectorios {
    unset directorio_seleccionado
    
    if [ -z "$1" ]; then
        ruta=$(ls -lhp "$(pwd)" | grep "^d" | awk -F ' ' ' { print $9 " " $5 } ')
    else
        ruta=$(ls -lhp "$1" | grep "^d" | awk -F ' ' ' { print $9 " " $5 } ')
    fi

    local seleccion=$(whiptail --title "SELECCIONAR DIRECTORIO" --menu "Selecciona el directorio de destino:" 22 75 15 \
        --cancel-button "Volver" --ok-button "Seleccionar" \
        "../" "Subir al directorio superior" \
        "." "Seleccionar este directorio" $ruta 3>&1 1>&2 2>&3)

    Salida=$?
    if [ $Salida -eq 1 ]; then
        return 1
    elif [ $Salida -eq 0 ]; then
        if [ "$seleccion" = "." ]; then
            if [ -z "$1" ]; then
                directorio_seleccionado="$(pwd)"
            else
                directorio_seleccionado="$1"
            fi
            return 0
        elif [ "$seleccion" = "../" ]; then
            if [ -z "$1" ]; then
                NavegadorDirectorios "$(dirname "$(pwd)")"
            else
                NavegadorDirectorios "$(dirname "$1")"
            fi
        else
            local target="${1:+$1/}$seleccion"
            if [[ -d "$target" ]]; then
                NavegadorDirectorios "$target"
            fi
        fi
    fi
}

#---------------------------------------------------------
# VALIDACIÓN DE ARCHIVOS CSV
#---------------------------------------------------------

function TomarFichero {
    local tipo="$1"
    while true; do
        if ! NavegadorFiles; then
            return 1
        fi
        local cabecera=$(head -n1 "$fichero" | tr -d '\r')
        
        if [ "$tipo" = "usuarios" ]; then
            if echo "$cabecera" | grep -qi "nombre" && echo "$cabecera" | grep -qi "apellido" && echo "$cabecera" | grep -qi "correo"; then
                if ValidarCSVUsuarios "$fichero"; then
                    ficheroUsers=$fichero
                    break
                else
                    whiptail --title "ERROR DE VALIDACION" --yesno "El archivo contiene errores.\n\nDesea intentarlo con otro archivo?" 10 55
                    if [ $? -ne 0 ]; then
                        unset fichero
                        return 1
                    fi
                fi
            else
                whiptail --title "ERROR DE FORMATO" --yesno "Cabecera no compatible.\nDebe contener: NOMBRE, APELLIDOS, CORREO\n\nDesea reintentar?" 14 60
                if [ $? -ne 0 ]; then
                    unset fichero
                    return 1
                fi
            fi
        elif [ "$tipo" = "plantillas" ]; then
            if echo "$cabecera" | grep -qi "plantilla" && echo "$cabecera" | grep -qi "pool"; then
                if ValidarCSVPlantillas "$fichero"; then
                    ficheroMaquinas=$fichero
                    break
                else
                    whiptail --title "ERROR DE VALIDACION" --yesno "El archivo contiene errores.\n\nDesea intentarlo con otro archivo?" 10 55
                    if [ $? -ne 0 ]; then
                        unset fichero
                        return 1
                    fi
                fi
            else
                whiptail --title "ERROR DE FORMATO" --yesno "Cabecera no compatible.\nDebe contener: PLANTILLA, POOL\n\nDesea reintentar?" 14 60
                if [ $? -ne 0 ]; then
                    unset fichero
                    return 1
                fi
            fi
        fi
    done
    unset fichero
    return 0
}

#---------------------------------------------------------
# VALIDACION DE NODO Y FECHA
#---------------------------------------------------------

function PedirNodo {
    while true; do
        nodo=$(whiptail --inputbox "Introduce el nombre del nodo (por defecto 'r940'):" 10 55 --title "NODO PROXMOX" --cancel-button "Volver" 3>&1 1>&2 2>&3)
        Salida=$?
        if [ $Salida -eq 1 ]; then
            return 1
        fi
        if [ -z "$nodo" ]; then
            nodo="r940"
        fi
        
        if ! CheckAPI; then
            whiptail --title "ERROR DE CONEXION" --yesno "No se puede conectar con la API.\n\nDesea reintentar?" 10 55
            if [ $? -ne 0 ]; then
                return 1
            fi
            continue
        fi
        
        nodecheck=$(timeout $API_TIMEOUT pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[]|select(.node == "'$nodo'")|.node')
        if [ -n "$nodecheck" ]; then
            log_info "Nodo validado: $nodo"
            return 0
        else
            nodos_disponibles=$(pvesh get /nodes --output-format=json 2>/dev/null | jq -r '.[].node' | tr '\n' ' ')
            whiptail --title "ERROR DE NODO" --yesno "Nodo '$nodo' no encontrado.\nNodos disponibles: $nodos_disponibles\n\nDesea reintentar?" 14 55
            if [ $? -ne 0 ]; then
                return 1
            fi
        fi
    done
}

function PedirFecha {
    fechabuena=1
    until [ $fechabuena -eq 0 ]; do
        fechacompleta=$(whiptail --inputbox "Introduce la fecha de expiracion (DD-MM-YYYY):\nEjemplo: 01-01-2030" 12 55 --title "FECHA DE EXPIRACION" --cancel-button "Volver" 3>&1 1>&2 2>&3)
        Salida=$?
        if [ $Salida -eq 1 ]; then
            return 1
        fi
        
        if [ -z "$fechacompleta" ]; then
            whiptail --title "ERROR DE FECHA" --msgbox "La fecha no puede estar vacia." 10 55
            continue
        fi
        
        fechacompleta=$(echo "$fechacompleta" | tr '/' '-')
        
        num_guiones=$(echo "$fechacompleta" | tr -cd '-' | wc -c)
        if [ "$num_guiones" -ne 2 ]; then
            whiptail --title "ERROR DE FORMATO" --msgbox "Use formato DD-MM-YYYY (ej: 01-01-2030)" 10 55
            continue
        fi
        
        anio=$(echo $fechacompleta | cut -d "-" -f3)
        mes=$(echo $fechacompleta | cut -d "-" -f2)
        dias=$(echo $fechacompleta | cut -d "-" -f1)
        
        if ! [[ "$anio" =~ ^[0-9]+$ ]] || ! [[ "$mes" =~ ^[0-9]+$ ]] || ! [[ "$dias" =~ ^[0-9]+$ ]]; then
            whiptail --title "ERROR" --msgbox "Solo se permiten numeros y guiones." 10 55
            continue
        fi
        
        anio=$((10#$anio))
        mes=$((10#$mes))
        dias=$((10#$dias))
        
        if [ $anio -lt 2024 ] || [ $anio -gt 9999 ]; then
            whiptail --title "ERROR DE A¥O" --msgbox "El año debe estar entre 2024 y 9999." 10 55
            continue
        fi
        
        if [ $mes -lt 1 ] || [ $mes -gt 12 ]; then
            whiptail --title "ERROR DE MES" --msgbox "El mes debe estar entre 01 y 12." 10 55
            continue
        fi
        
        case $mes in
            1|3|5|7|8|10|12) dias_max=31 ;;
            4|6|9|11) dias_max=30 ;;
            2)
                if (( $anio % 4 == 0 && ($anio % 100 != 0 || $anio % 400 == 0) )); then
                    dias_max=29
                else
                    dias_max=28
                fi
                ;;
        esac
        
        if [ $dias -lt 1 ] || [ $dias -gt $dias_max ]; then
            whiptail --title "ERROR DE DIA" --msgbox "El mes $(printf '%02d' $mes) tiene $dias_max dias." 10 55
            continue
        fi
        
        fecha_padded=$(printf "%04d%02d%02d" $anio $mes $dias)
        if ! date -d "$fecha_padded" >/dev/null 2>&1; then
            whiptail --title "ERROR" --msgbox "Fecha no valida en el calendario." 10 55
            continue
        fi
        
        fechaactual=$(date +%Y%m%d)
        if [ $fecha_padded -le $fechaactual ]; then
            whiptail --title "ERROR" --msgbox "La fecha debe ser posterior a hoy ($(date '+%d-%m-%Y'))." 10 55
            continue
        fi
        
        fecha=$(printf "%04d-%02d-%02d" $anio $mes $dias)
        log_info "Fecha validada: $fecha"
        fechabuena=0
    done
    return 0
}

#---------------------------------------------------------
# GESTION DE USUARIOS
#---------------------------------------------------------

function CrearUsuarios {
    if ! CheckAPI; then
        MensajeBox "Error de conexion con la API de Proxmox." "ERROR"
        return
    fi

    PantallaEspera "Preparando creacion de usuarios..." 1

    MensajeBox "Selecciona el fichero con los usuarios" "CREAR USUARIOS"
    if ! TomarFichero "usuarios"; then
        return
    fi

    grupo=$(echo $ficheroUsers | awk -F "/" '{print $NF}' | cut -d "." -f1)
    log_info "Iniciando creacion de usuarios - Grupo: $grupo"
    
    grupoExiste=$(pvesh get /access/groups 2>/dev/null | grep -w "$grupo")
    if [ -z "$grupoExiste" ]; then
        EjecutarComando "pveum groupadd $grupo" "No se pudo crear el grupo '$grupo'"
        log_success "Grupo '$grupo' creado"
    fi

    if ! PedirFecha; then
        unset ficheroUsers
        return
    fi
    expire=$(date +%s --date "$fecha 00:00:00")

    total_usuarios=$(tail -n +2 "$ficheroUsers" | grep -c ";")
    
    > "$TEMP_DIR/creados.txt"
    > "$TEMP_DIR/errores.txt"
    echo "0" > "$TEMP_DIR/creados_count.txt"
    echo "0" > "$TEMP_DIR/omitidos_count.txt"
    echo "0" > "$TEMP_DIR/errores_count.txt"

    IFS=$";"
    total=0
    
    if [ $total_usuarios -gt 0 ]; then
        {
            echo "0"
            echo "Iniciando creacion de usuarios..."
            
            while read -r nombre apellido correo; do
                if [[ ($total -ne 0 && -n "$correo") ]]; then
                    password=$(echo "$correo" | cut -f 1 -d "@")
                    
                    if [ -z "$password" ]; then
                        echo "Linea $total: Correo invalido '$correo'" >> "$TEMP_DIR/errores.txt"
                        cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                        total=$(($total + 1))
                        continue
                    fi
                    
                    percent=$((total * 100 / total_usuarios))
                    echo "$percent"
                    echo "Procesando: $password..."
                    
                    userExiste=$(pvesh get /access/users 2>/dev/null | grep -wio "$password")
                    if [ -n "$userExiste" ]; then
                        cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/omitidos_count.txt"
                    else
                        error_useradd=$(pveum useradd $password@pve -group $grupo -expire $expire -firstname "$nombre" -lastname "$apellido" 2>&1)
                        if [ $? -eq 0 ]; then
                            pvesh set /access/password --userid $password@pve --password $password 2>/dev/null
                            echo "$password@pve ($nombre $apellido)" >> "$TEMP_DIR/creados.txt"
                            cnt=$(cat "$TEMP_DIR/creados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/creados_count.txt"
                        else
                            echo "Fallo al crear $password@pve: $error_useradd" >> "$TEMP_DIR/errores.txt"
                            cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                        fi
                    fi
                fi
                total=$(($total + 1))
            done < "$ficheroUsers"
            
            echo "100"
            echo "Proceso completado"
            sleep 1
        } | whiptail --title "CREANDO USUARIOS" --gauge "Preparando..." 8 60 0
    fi
    
    unset IFS
    
    creados=$(cat "$TEMP_DIR/creados_count.txt")
    omitidos=$(cat "$TEMP_DIR/omitidos_count.txt")
    errores=$(cat "$TEMP_DIR/errores_count.txt")
    
    log_info "Resumen: Creados=$creados | Omitidos=$omitidos | Errores=$errores | Grupo=$grupo"
    unset fecha ficheroUsers
    
    mensaje="RESUMEN DE CREACION DE USUARIOS\n\n─────────────────────────────\nUsuarios creados:     $creados\nUsuarios omitidos:    $omitidos\nErrores:              $errores\n─────────────────────────────\nTotal procesados:     $((creados + omitidos + errores))\nGrupo:                $grupo\nFecha expiracion:     $fecha"
    
    if [ $creados -gt 0 ]; then
        mensaje="$mensaje\n\nUSUARIOS CREADOS:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/creados.txt"
    fi
    
    if [ $errores -gt 0 ]; then
        mensaje="$mensaje\n\nERRORES DETECTADOS:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/errores.txt"
    fi
    
    mensaje="$mensaje\n\nRevisa el log: $LOG_FILE\n\nPulse VOLVER para regresar al menu principal"
    
    # Correo con formato tabla
    correo_msg=""
    printf -v correo_msg '%sGRUPO: %s\nFECHA DE EXPIRACION: %s\n\n' "$correo_msg" "$grupo" "$fecha"
    printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
    printf -v correo_msg '%s│ RESULTADOS                                          │\n' "$correo_msg"
    printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
    printf -v correo_msg '%s│ Creados..: %-42s │\n' "$correo_msg" "$creados"
    printf -v correo_msg '%s│ Omitidos.: %-42s │\n' "$correo_msg" "$omitidos"
    printf -v correo_msg '%s│ Errores..: %-42s │\n' "$correo_msg" "$errores"
    printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    
    if [ $creados -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ USUARIOS CREADOS                                    │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/creados.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    fi
    
    if [ $errores -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ ERRORES                                             │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/errores.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n' "$correo_msg"
    fi
    
    EnviarNotificacion "Usuarios creados - $grupo" "$correo_msg"
    
    whiptail --title "PROXMOX" --yesno "$mensaje" 22 75
    if [ $? -ne 0 ]; then
        clear
        exit 0
    fi
}

function BorrarUsuarios {
    if ! CheckAPI; then
        MensajeBox "Error de conexion con la API." "ERROR"
        return
    fi

    PantallaEspera "Preparando eliminacion de usuarios..." 1

    MensajeBox "Selecciona el fichero con los usuarios a eliminar" "ELIMINAR USUARIOS"
    if ! TomarFichero "usuarios"; then
        return
    fi

    grupo=$(echo $ficheroUsers | awk -F "/" '{print $NF}' | cut -d "." -f1)
    log_info "Iniciando eliminacion de usuarios - Grupo: $grupo"

    total_usuarios=$(tail -n +2 "$ficheroUsers" | grep -c ";")

    > "$TEMP_DIR/eliminados.txt"
    > "$TEMP_DIR/errores.txt"
    echo "0" > "$TEMP_DIR/eliminados_count.txt"
    echo "0" > "$TEMP_DIR/no_encontrados_count.txt"
    echo "0" > "$TEMP_DIR/errores_count.txt"

    IFS=$";"
    total=0
    
    if [ $total_usuarios -gt 0 ]; then
        {
            echo "0"
            echo "Iniciando eliminacion de usuarios..."
            
            while read -r nombre apellido correo; do
                if test $total -ne 0; then
                    password=$(echo "$correo" | cut -f 1 -d "@")
                    
                    if [ -z "$password" ]; then
                        echo "Linea $total: Correo invalido" >> "$TEMP_DIR/errores.txt"
                        cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                        total=$(($total + 1))
                        continue
                    fi
                    
                    percent=$((total * 100 / total_usuarios))
                    echo "$percent"
                    echo "Procesando: $password..."
                    
                    userExiste=$(pvesh get /access/users 2>/dev/null | grep -wio "$password")
                    if [ -n "$userExiste" ]; then
                        error_delete=$(pveum userdel $password@pve 2>&1)
                        if [ $? -eq 0 ]; then
                            echo "$password@pve ($nombre $apellido)" >> "$TEMP_DIR/eliminados.txt"
                            cnt=$(cat "$TEMP_DIR/eliminados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/eliminados_count.txt"
                        else
                            echo "Fallo al eliminar $password@pve: $error_delete" >> "$TEMP_DIR/errores.txt"
                            cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                        fi
                    else
                        cnt=$(cat "$TEMP_DIR/no_encontrados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/no_encontrados_count.txt"
                    fi
                fi
                total=$(($total + 1))
            done < "$ficheroUsers"
            
            echo "100"
            echo "Proceso completado"
            sleep 1
        } | whiptail --title "ELIMINANDO USUARIOS" --gauge "Preparando..." 8 60 0
    fi
    
    unset IFS
    
    usuarios_borrados=$(cat "$TEMP_DIR/eliminados_count.txt")
    no_encontrados=$(cat "$TEMP_DIR/no_encontrados_count.txt")
    errores=$(cat "$TEMP_DIR/errores_count.txt")
    
    eliminar_grupo="No"
    grupo_vacio=false
    
    if [ $usuarios_borrados -gt 0 ]; then
        usuarios_restantes=$(pvesh get /access/groups/$grupo 2>/dev/null | grep -c "@")
        if [ -z "$usuarios_restantes" ]; then
            usuarios_restantes=0
        fi
        
        if [ "$usuarios_restantes" -eq 0 ]; then
            grupo_vacio=true
        fi
    fi
    
    if [ "$grupo_vacio" = true ]; then
        whiptail --title "GRUPO VACIO" --yesno "El grupo '$grupo' ha quedado vacio.\n\nDesea eliminar tambien el grupo?" 12 55
        if [ $? -eq 0 ]; then
            if pveum groupdel $grupo 2>/dev/null; then
                log_success "Grupo eliminado: $grupo"
                eliminar_grupo="Si"
            else
                log_error "No se pudo eliminar el grupo '$grupo'"
            fi
        else
            log_info "Usuario decidio conservar el grupo '$grupo' (vacio)"
        fi
    fi
    
    log_info "Resumen: Eliminados=$usuarios_borrados | No encontrados=$no_encontrados | Errores=$errores"
    unset ficheroUsers
    
    mensaje="RESUMEN DE ELIMINACION DE USUARIOS\n\n─────────────────────────────\nUsuarios eliminados:      $usuarios_borrados\nUsuarios no encontrados:  $no_encontrados\nErrores:                  $errores\n─────────────────────────────\nTotal procesados:         $((usuarios_borrados + no_encontrados + errores))\nGrupo:                    $grupo"
    
    if [ $usuarios_borrados -gt 0 ]; then
        mensaje="$mensaje\n\nUSUARIOS ELIMINADOS:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/eliminados.txt"
    fi
    
    if [ "$eliminar_grupo" = "Si" ]; then
        mensaje="$mensaje\n\nEl grupo '$grupo' fue eliminado."
    fi
    
    if [ $errores -gt 0 ]; then
        mensaje="$mensaje\n\nERRORES:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/errores.txt"
    fi
    
    mensaje="$mensaje\n\nRevisa el log: $LOG_FILE\n\nPulse VOLVER para regresar al menu principal"
    
    # Correo con formato tabla
    correo_msg=""
    printf -v correo_msg '%sGRUPO: %s\n\n' "$correo_msg" "$grupo"
    printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
    printf -v correo_msg '%s│ RESULTADOS                                          │\n' "$correo_msg"
    printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
    printf -v correo_msg '%s│ Eliminados.....: %-37s │\n' "$correo_msg" "$usuarios_borrados"
    printf -v correo_msg '%s│ No encontrados.: %-37s │\n' "$correo_msg" "$no_encontrados"
    printf -v correo_msg '%s│ Errores........: %-37s │\n' "$correo_msg" "$errores"
    printf -v correo_msg '%s│ Grupo eliminado: %-36s │\n' "$correo_msg" "$eliminar_grupo"
    printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    
    if [ $usuarios_borrados -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ USUARIOS ELIMINADOS                                 │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/eliminados.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n' "$correo_msg"
    fi
    
    EnviarNotificacion "Usuarios eliminados - $grupo" "$correo_msg"
    
    whiptail --title "PROXMOX" --yesno "$mensaje" 22 75
    if [ $? -ne 0 ]; then
        clear
        exit 0
    fi
}

#---------------------------------------------------------
# BUSQUEDA DE IDs LIBRES
#---------------------------------------------------------

function newID {
    numeroNuevo=$1
    numeroMaximo=$2
    
    pvesh get /nodes/$3/qemu --output-format=json-pretty 2>/dev/null | jq '.[].vmid' | sort -n | grep -wA 999 $numeroNuevo >>numestemp
    SePuedeLeer "numestemp"
    echo $numeroMaximo >> numestemp
    
    while read numeroExiste; do
        if [ $numeroNuevo -ne $numeroExiste ] && [ $numeroNuevo -le $numeroMaximo ]; then
            nuevoID=$numeroNuevo
            break
        fi
        let numeroNuevo=numeroNuevo+1
    done < numestemp

    if [ -z "$nuevoID" ]; then
        log_error "No hay IDs libres en rango VM $1-$2"
        MensajeBox "Todos los IDs del rango $1-$2 estan ocupados." "ERROR"
        rm numestemp
        exit 5
    fi
    rm numestemp
}

function newIDlxc {
    numeroNuevo=$1
    numeroMaximo=$2
    
    pvesh get /nodes/$3/lxc --output-format=json-pretty 2>/dev/null | jq '.[].vmid' | sort -n | grep -wA 999 $numeroNuevo >>numestemp
    SePuedeLeer "numestemp"
    echo $numeroMaximo >> numestemp
    
    while read numeroExiste; do
        if [ $numeroNuevo -ne $numeroExiste ] && [ $numeroNuevo -le $numeroMaximo ]; then
            nuevoID=$numeroNuevo
            break
        fi
        let numeroNuevo=numeroNuevo+1
    done < numestemp

    if [ -z "$nuevoID" ]; then
        log_error "No hay IDs libres en rango CT $1-$2"
        MensajeBox "Todos los IDs del rango $1-$2 estan ocupados." "ERROR"
        rm numestemp
        exit 5
    fi
    rm numestemp
}

#---------------------------------------------------------
# CREACION DE RECURSOS INDIVIDUALES
#---------------------------------------------------------

function CrearRecursosIndividuales {
    if ! CheckAPI; then
        MensajeBox "Error de conexion con la API" "ERROR"
        return
    fi

    PantallaEspera "Preparando creacion de recursos..." 1

    MensajeBox "Selecciona el fichero con los usuarios" "CREAR RECURSOS"
    if ! TomarFichero "usuarios"; then return; fi

    MensajeBox "Selecciona el fichero con las plantillas (VM y/o CT)" "CREAR RECURSOS"
    if ! TomarFichero "plantillas"; then return; fi

    if ! PedirNodo; then return; fi

    log_info "Iniciando creacion de recursos individuales - Nodo: $nodo"

    total_usuarios=$(tail -n +2 "$ficheroUsers" | grep -c ";")
    total_plantillas=$(tail -n +2 "$ficheroMaquinas" | grep -c ";")
    total_operaciones=$((total_usuarios * total_plantillas))
    
    > "$TEMP_DIR/creados.txt"
    > "$TEMP_DIR/errores.txt"
    echo "0" > "$TEMP_DIR/creados_count.txt"
    echo "0" > "$TEMP_DIR/omitidos_count.txt"
    echo "0" > "$TEMP_DIR/errores_count.txt"

    IFS=$";"
    total=0
    operacion=0
    
    if [ $total_operaciones -gt 0 ]; then
        {
            echo "0"
            echo "Iniciando creacion de recursos..."
            
            while read -r nombre apellido correo; do
                if [[ ($total -ne 0 && -n "$correo") ]]; then
                    password=$(echo "$correo" | cut -f 1 -d "@")
                    
                    userExiste=$(pvesh get /access/users --output-format=json-pretty 2>/dev/null | grep -wio "$password")
                    
                    if [ -n "$userExiste" ]; then
                        total2=0
                        while IFS=";" read -u 9 plantilla pool rangoStart rangoEnd; do
                            if [ $total2 -ne 0 ]; then
                                if [ -z "$plantilla" ] || [ -z "$pool" ]; then
                                    total2=$(($total2 + 1))
                                    continue
                                fi
                                
                                operacion=$((operacion + 1))
                                percent=$((operacion * 100 / total_operaciones))
                                echo "$percent"
                                
                                numPlantilla=$(pvesh get /nodes/$nodo/qemu --output-format=json-pretty 2>/dev/null | jq -r '.[]|select(.name == "'$plantilla'")|.vmid')
                                
                                if [ -n "$numPlantilla" ]; then
                                    nombremaquina=$plantilla-$password
                                    echo "VM: $nombremaquina..."
                                    
                                    poolexiste=$(pvesh get /pools --output-format=json-pretty 2>/dev/null | grep -wio "$pool")
                                    maquinaExiste=$(pvesh get /nodes/$nodo/qemu --output-format=json-pretty 2>/dev/null | grep -wio "$nombremaquina")
                                    
                                    if [ -z "$poolexiste" ]; then
                                        pvesh create /pools -poolid $pool 2>/dev/null
                                    fi

                                    if [ -n "$maquinaExiste" ]; then
                                        cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/omitidos_count.txt"
                                    else
                                        newID $rangoStart $rangoEnd $nodo
                                        error_clone=$(pvesh create /nodes/$nodo/qemu/$numPlantilla/clone -newid $nuevoID --pool $pool -name $nombremaquina 2>&1)
                                        if [ $? -eq 0 ]; then
                                            qm snapshot $nuevoID "Estado_Inicial" --description "Snapshot inicial" 2>/dev/null
                                            pvesh set /access/acl --path /vms/$nuevoID --user $password@pve --role PVEVMUser 2>/dev/null
                                            echo "VM: $nombremaquina (ID: $nuevoID) -> $password@pve" >> "$TEMP_DIR/creados.txt"
                                            cnt=$(cat "$TEMP_DIR/creados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/creados_count.txt"
                                        else
                                            echo "VM '$nombremaquina' para $password: $error_clone" >> "$TEMP_DIR/errores.txt"
                                            cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                                        fi
                                    fi
                                else
                                    numPlantilla=$(pvesh get /nodes/$nodo/lxc --output-format=json-pretty 2>/dev/null | jq -r '.[]|select(.name == "'$plantilla'")|.vmid')
                                    
                                    if [ -n "$numPlantilla" ]; then
                                        nombrecontenedor=$plantilla-$password
                                        echo "CT: $nombrecontenedor..."
                                        
                                        poolexiste=$(pvesh get /pools --output-format=json-pretty 2>/dev/null | grep -wio "$pool")
                                        contenedorExiste=$(pvesh get /nodes/$nodo/lxc --output-format=json-pretty 2>/dev/null | grep -wio "$nombrecontenedor")
                                        
                                        if [ -z "$poolexiste" ]; then
                                            pvesh create /pools -poolid $pool 2>/dev/null
                                        fi

                                        if [ -n "$contenedorExiste" ]; then
                                            cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/omitidos_count.txt"
                                        else
                                            newIDlxc $rangoStart $rangoEnd $nodo
                                            error_clone=$(pvesh create /nodes/$nodo/lxc/$numPlantilla/clone -newid $nuevoID --pool $pool -hostname $nombrecontenedor 2>&1)
                                            if [ $? -eq 0 ]; then
                                                pct snapshot $nuevoID "Estado_Inicial" --description "Snapshot inicial" 2>/dev/null
                                                pvesh set /access/acl --path /vms/$nuevoID --user $password@pve --role PVEVMUser 2>/dev/null
                                                echo "CT: $nombrecontenedor (ID: $nuevoID) -> $password@pve" >> "$TEMP_DIR/creados.txt"
                                                cnt=$(cat "$TEMP_DIR/creados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/creados_count.txt"
                                            else
                                                echo "CT '$nombrecontenedor' para $password: $error_clone" >> "$TEMP_DIR/errores.txt"
                                                cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                                            fi
                                        fi
                                    else
                                        echo "Plantilla '$plantilla' no encontrada para $password" >> "$TEMP_DIR/errores.txt"
                                        cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                                    fi
                                fi
                            fi
                            total2=$(($total2 + 1))
                        done 9< "$ficheroMaquinas"
                    else
                        echo "Usuario $password no existe - Omitido" >> "$TEMP_DIR/errores.txt"
                        cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + total_plantillas)) > "$TEMP_DIR/omitidos_count.txt"
                    fi
                fi
                total=$(($total + 1))
            done < "$ficheroUsers"
            
            echo "100"
            echo "Proceso completado"
            sleep 1
        } | whiptail --title "CREANDO RECURSOS" --gauge "Preparando..." 8 60 0
    fi
    
    unset IFS
    unset pool ficheroUsers ficheroMaquinas
    
    creados=$(cat "$TEMP_DIR/creados_count.txt")
    omitidos=$(cat "$TEMP_DIR/omitidos_count.txt")
    errores=$(cat "$TEMP_DIR/errores_count.txt")
    
    log_info "Resumen: Creados=$creados | Omitidos=$omitidos | Errores=$errores"
    
    mensaje="RESUMEN DE CREACION DE RECURSOS\n\n─────────────────────────────\nRecursos creados:     $creados\nRecursos omitidos:    $omitidos\nErrores:              $errores\n─────────────────────────────\nTotal operaciones:    $total_operaciones\nNodo:                 $nodo"
    
    if [ $creados -gt 0 ]; then
        mensaje="$mensaje\n\nRECURSOS CREADOS:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/creados.txt"
    fi
    
    if [ $errores -gt 0 ]; then
        mensaje="$mensaje\n\nERRORES:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/errores.txt"
    fi
    
    mensaje="$mensaje\n\nRevisa el log: $LOG_FILE\n\nPulse VOLVER para regresar al menu principal"
    
    # Correo con formato tabla
    correo_msg=""
    printf -v correo_msg '%sNODO: %s\nTOTAL OPERACIONES: %s\n\n' "$correo_msg" "$nodo" "$total_operaciones"
    printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
    printf -v correo_msg '%s│ RESULTADOS                                          │\n' "$correo_msg"
    printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
    printf -v correo_msg '%s│ Creados..: %-42s │\n' "$correo_msg" "$creados"
    printf -v correo_msg '%s│ Omitidos.: %-42s │\n' "$correo_msg" "$omitidos"
    printf -v correo_msg '%s│ Errores..: %-42s │\n' "$correo_msg" "$errores"
    printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    
    if [ $creados -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ RECURSOS CREADOS                                    │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/creados.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    fi
    
    if [ $errores -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ ERRORES                                             │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/errores.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n' "$correo_msg"
    fi
    
    EnviarNotificacion "Recursos creados - $nodo" "$correo_msg"
    
    whiptail --title "PROXMOX" --yesno "$mensaje" 22 75
    if [ $? -ne 0 ]; then
        clear
        exit 0
    fi
}

#---------------------------------------------------------
# CREACION DE RECURSOS COMPARTIDOS
#---------------------------------------------------------

function CrearRecursosCompartidos {
    if ! CheckAPI; then
        MensajeBox "Error de conexion con la API" "ERROR"
        return
    fi

    PantallaEspera "Preparando creacion de recursos compartidos..." 1

    declare -a ficheros=()
    while true; do
        MensajeBox "Selecciona un fichero de usuarios" "RECURSOS COMPARTIDOS"
        if TomarFichero "usuarios"; then
            ficheros+=("$ficheroUsers")
            unset ficheroUsers
        else
            break
        fi
        whiptail --title "RECURSOS COMPARTIDOS" --yesno "Desea añadir otro fichero?" 8 50
        if [ $? -ne 0 ]; then break; fi
    done

    if [ ${#ficheros[@]} -eq 0 ]; then return; fi

    num_usuarios=0
    for f in "${ficheros[@]}"; do
        lines=$(wc -l < "$f")
        if [ $num_usuarios -eq 0 ]; then
            num_usuarios=$((lines - 1))
        elif [ $((lines - 1)) -ne $num_usuarios ]; then
            MensajeBox "Los ficheros no tienen el mismo numero de usuarios." "ERROR"
            unset ficheros
            return
        fi
    done

    MensajeBox "Selecciona el fichero de plantillas (VM y/o CT)" "RECURSOS COMPARTIDOS"
    if ! TomarFichero "plantillas"; then return; fi

    if ! PedirNodo; then return; fi

    log_info "Iniciando creacion de recursos compartidos - Equipos: $num_usuarios"

    total_plantillas=$(tail -n +2 "$ficheroMaquinas" | grep -c ";")
    total_operaciones=$((num_usuarios * total_plantillas))
    
    > "$TEMP_DIR/creados.txt"
    > "$TEMP_DIR/errores.txt"
    echo "0" > "$TEMP_DIR/creados_count.txt"
    echo "0" > "$TEMP_DIR/omitidos_count.txt"
    echo "0" > "$TEMP_DIR/errores_count.txt"
    echo "0" > "$TEMP_DIR/equipos_omitidos_count.txt"

    if [ $total_operaciones -gt 0 ]; then
        {
            echo "0"
            echo "Iniciando creacion de recursos compartidos..."
            
            for (( i=1; i<=num_usuarios; i++ )); do
                team_passwords=()
                team_iniciales=()
                all_exist=true
                
                for f in "${ficheros[@]}"; do
                    linea=$(sed -n "$((i+1))p" "$f" | tr -d '\r')
                    IFS=";" read -r nombre apellido correo <<< "$linea"
                    password=$(echo "$correo" | cut -f 1 -d "@")
                    if [ -z "$(pvesh get /access/users --output-format=json 2>/dev/null | jq -r '.[].userid' | grep -wio "$password")" ]; then
                        echo "Usuario $password no existe - Equipo $i omitido" >> "$TEMP_DIR/errores.txt"
                        all_exist=false
                        break
                    fi
                    team_passwords+=("$password")
                    inicial_nombre=$(echo "$nombre" | cut -c1 | tr '[:lower:]' '[:upper:]')
                    inicial_apellido=$(echo "$apellido" | cut -d' ' -f1 | cut -c1 | tr '[:lower:]' '[:upper:]')
                    team_iniciales+=("${inicial_nombre}${inicial_apellido}")
                done

                if ! $all_exist; then
                    cnt=$(cat "$TEMP_DIR/equipos_omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/equipos_omitidos_count.txt"
                    continue
                fi

                sufijo_equipo=$(IFS="-"; echo "${team_iniciales[*]}")

                total2=0
                while IFS=";" read -u 9 plantilla pool rangoStart rangoEnd; do
                    if [ $total2 -ne 0 ]; then
                        if [ -z "$plantilla" ] || [ -z "$pool" ]; then
                            total2=$(($total2 + 1))
                            continue
                        fi
                        
                        numPlantilla=$(pvesh get /nodes/$nodo/qemu --output-format=json-pretty 2>/dev/null | jq -r '.[]|select(.name == "'$plantilla'")|.vmid')
                        
                        if [ -n "$numPlantilla" ]; then
                            nombremaquina="$plantilla-$sufijo_equipo"
                            echo "VM: $nombremaquina..."
                            
                            poolexiste=$(pvesh get /pools --output-format=json-pretty 2>/dev/null | grep -wio "$pool")
                            maquinaExiste=$(pvesh get /nodes/$nodo/qemu --output-format=json-pretty 2>/dev/null | grep -wio "$nombremaquina")
                            
                            if [ -z "$poolexiste" ]; then
                                pvesh create /pools -poolid $pool 2>/dev/null
                            fi
                            
                            if [ -n "$maquinaExiste" ]; then
                                cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/omitidos_count.txt"
                            else
                                newID $rangoStart $rangoEnd $nodo
                                error_clone=$(pvesh create /nodes/$nodo/qemu/$numPlantilla/clone -newid $nuevoID --pool $pool -name $nombremaquina 2>&1)
                                if [ $? -eq 0 ]; then
                                    qm snapshot $nuevoID "Estado_Inicial" --description "Snapshot inicial" 2>/dev/null
                                    for j in "${!team_passwords[@]}"; do
                                        pvesh set /access/acl --path /vms/$nuevoID --user ${team_passwords[$j]}@pve --role PVEVMUser 2>/dev/null
                                    done
                                    echo "VM: $nombremaquina (ID: $nuevoID) -> Equipo: $sufijo_equipo [${team_passwords[*]}]" >> "$TEMP_DIR/creados.txt"
                                    cnt=$(cat "$TEMP_DIR/creados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/creados_count.txt"
                                else
                                    echo "VM '$nombremaquina' (equipo $sufijo_equipo): $error_clone" >> "$TEMP_DIR/errores.txt"
                                    cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                                fi
                            fi
                        else
                            numPlantilla=$(pvesh get /nodes/$nodo/lxc --output-format=json-pretty 2>/dev/null | jq -r '.[]|select(.name == "'$plantilla'")|.vmid')
                            
                            if [ -n "$numPlantilla" ]; then
                                nombrecontenedor="$plantilla-$sufijo_equipo"
                                echo "CT: $nombrecontenedor..."
                                
                                poolexiste=$(pvesh get /pools --output-format=json-pretty 2>/dev/null | grep -wio "$pool")
                                contenedorExiste=$(pvesh get /nodes/$nodo/lxc --output-format=json-pretty 2>/dev/null | grep -wio "$nombrecontenedor")
                                
                                if [ -z "$poolexiste" ]; then
                                    pvesh create /pools -poolid $pool 2>/dev/null
                                fi
                                
                                if [ -n "$contenedorExiste" ]; then
                                    cnt=$(cat "$TEMP_DIR/omitidos_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/omitidos_count.txt"
                                else
                                    newIDlxc $rangoStart $rangoEnd $nodo
                                    error_clone=$(pvesh create /nodes/$nodo/lxc/$numPlantilla/clone -newid $nuevoID --pool $pool -hostname $nombrecontenedor 2>&1)
                                    if [ $? -eq 0 ]; then
                                        pct snapshot $nuevoID "Estado_Inicial" --description "Snapshot inicial" 2>/dev/null
                                        for j in "${!team_passwords[@]}"; do
                                            pvesh set /access/acl --path /vms/$nuevoID --user ${team_passwords[$j]}@pve --role PVEVMUser 2>/dev/null
                                        done
                                        echo "CT: $nombrecontenedor (ID: $nuevoID) -> Equipo: $sufijo_equipo [${team_passwords[*]}]" >> "$TEMP_DIR/creados.txt"
                                        cnt=$(cat "$TEMP_DIR/creados_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/creados_count.txt"
                                    else
                                        echo "CT '$nombrecontenedor' (equipo $sufijo_equipo): $error_clone" >> "$TEMP_DIR/errores.txt"
                                        cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                                    fi
                                fi
                            else
                                echo "Plantilla '$plantilla' no encontrada para equipo $sufijo_equipo" >> "$TEMP_DIR/errores.txt"
                                cnt=$(cat "$TEMP_DIR/errores_count.txt"); echo $((cnt + 1)) > "$TEMP_DIR/errores_count.txt"
                            fi
                        fi
                    fi
                    total2=$(($total2 + 1))
                done 9< "$ficheroMaquinas"
            done
            
            echo "100"
            echo "Proceso completado"
            sleep 1
        } | whiptail --title "CREANDO RECURSOS COMPARTIDOS" --gauge "Preparando..." 8 60 0
    fi

    unset IFS pool ficheroMaquinas ficheros
    
    creados=$(cat "$TEMP_DIR/creados_count.txt")
    omitidos=$(cat "$TEMP_DIR/omitidos_count.txt")
    errores=$(cat "$TEMP_DIR/errores_count.txt")
    equipos_omitidos=$(cat "$TEMP_DIR/equipos_omitidos_count.txt")
    
    log_info "Resumen compartidos: Creados=$creados | Omitidos=$omitidos | Errores=$errores | Equipos omitidos=$equipos_omitidos"
    
    mensaje="RESUMEN DE CREACION DE RECURSOS COMPARTIDOS\n\n─────────────────────────────\nRecursos creados:     $creados\nRecursos omitidos:    $omitidos\nErrores:              $errores\n─────────────────────────────\nTotal operaciones:    $total_operaciones\nEquipos procesados:   $num_usuarios\nEquipos omitidos:     $equipos_omitidos\nNodo:                 $nodo"
    
    if [ $creados -gt 0 ]; then
        mensaje="$mensaje\n\nRECURSOS CREADOS:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/creados.txt"
    fi
    
    if [ $errores -gt 0 ]; then
        mensaje="$mensaje\n\nERRORES:"
        while read -r line; do
            [ -n "$line" ] && mensaje="$mensaje\n  - $line"
        done < "$TEMP_DIR/errores.txt"
    fi
    
    mensaje="$mensaje\n\nRevisa el log: $LOG_FILE\n\nPulse VOLVER para regresar al menu principal"
    
    # Correo con formato tabla
    correo_msg=""
    printf -v correo_msg '%sNODO: %s\nTOTAL OPERACIONES: %s\nEQUIPOS PROCESADOS: %s\nEQUIPOS OMITIDOS: %s\n\n' "$correo_msg" "$nodo" "$total_operaciones" "$num_usuarios" "$equipos_omitidos"
    printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
    printf -v correo_msg '%s│ RESULTADOS                                          │\n' "$correo_msg"
    printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
    printf -v correo_msg '%s│ Creados..: %-42s │\n' "$correo_msg" "$creados"
    printf -v correo_msg '%s│ Omitidos.: %-42s │\n' "$correo_msg" "$omitidos"
    printf -v correo_msg '%s│ Errores..: %-42s │\n' "$correo_msg" "$errores"
    printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    
    if [ $creados -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ RECURSOS CREADOS                                    │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/creados.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    fi
    
    if [ $errores -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ ERRORES                                             │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/errores.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n' "$correo_msg"
    fi
    
    EnviarNotificacion "Recursos compartidos - $nodo" "$correo_msg"
    
    whiptail --title "PROXMOX" --yesno "$mensaje" 22 75
    if [ $? -ne 0 ]; then
        clear
        exit 0
    fi
}

#---------------------------------------------------------
# FUNCIONES PARA GESTION DE POOLS
#---------------------------------------------------------

function get_pools {
    pvesh get /pools --output-format json 2>/dev/null | jq -r '.[].poolid' 2>/dev/null
}

function get_pool_members {
    local pool=$1
    pvesh get /pools/$pool --output-format json 2>/dev/null | jq -r '.members[]? | "\(.vmid):\(.type)"' 2>/dev/null
}

function get_vm_name {
    local vmid=$1
    qm config $vmid 2>/dev/null | grep "^name:" | awk '{print $2}'
}

function get_ct_name {
    local ctid=$1
    pct config $ctid 2>/dev/null | grep "^hostname:" | awk '{print $2}'
}

#---------------------------------------------------------
# FUNCIONES DE EXPORTACIÓN Y CORREO
#---------------------------------------------------------

function ExportarArchivo {
    local archivo="$1"
    local pool="$2"
    local total_ips=0
    
    if [ -f "$TEMP_DIR/ips_resultado.txt" ]; then
        total_ips=$(wc -l < "$TEMP_DIR/ips_resultado.txt")
    fi
    
    {
        echo "========================================="
        echo "  DIRECCIONES IP DEL POOL: $pool"
        echo "========================================="
        echo "TIPO;ID;NOMBRE;DIRECCION IP"
        echo "========================================="
        
        if [ -f "$TEMP_DIR/ips_resultado.txt" ]; then
            while IFS=";" read -r tipo vmid name ip; do
                echo "$tipo;$vmid;$name;$ip"
            done < "$TEMP_DIR/ips_resultado.txt"
        fi
        
        echo "========================================="
        echo "Pool: $pool"
        echo "Fecha de exportacion: $(date '+%d-%m-%Y %H:%M:%S')"
        echo "Total de instancias: $total_ips"
        echo "Servidor: $(hostname)"
        echo "Script: PROXMOX Gestion v7.5 - Esther CN"
        echo "========================================="
    } > "$archivo"
    
    log_success "Resultados exportados a: $archivo"
    whiptail --title "EXPORTACION COMPLETADA" --msgbox "Resultados exportados correctamente a:\n\n$archivo" 10 65
}

function EnviarIPsPorEmail {
    local pool="$1"
    
    # Verificar si hay correo configurado
    if [ -z "$EMAIL_NOTIFICACION" ]; then
        whiptail --title "ERROR" --msgbox "No hay un correo de notificacion configurado.\n\nEdite la variable EMAIL_NOTIFICACION al inicio del script." 10 60
        return
    fi
    
    # Preguntar destinatario (por defecto el configurado)
    local destinatario=$(whiptail --title "ENVIAR POR CORREO" --inputbox "Direccion de correo electronico:" 10 55 "$EMAIL_NOTIFICACION" 3>&1 1>&2 2>&3)
    
    if [ $? -ne 0 ] || [ -z "$destinatario" ]; then
        return
    fi
    
    # Construir el contenido del correo
    local fecha=$(date '+%d-%m-%Y %H:%M:%S')
    local total_ips=0
    
    if [ -f "$TEMP_DIR/ips_resultado.txt" ]; then
        total_ips=$(wc -l < "$TEMP_DIR/ips_resultado.txt")
    fi
    
    local correo_temp="$TEMP_DIR/correo_ips.txt"
    
    {
        echo "══════════════════════════════════════════════════════════════"
        echo "              DIRECCIONES IP DEL POOL: $pool"
        echo "══════════════════════════════════════════════════════════════"
        echo ""
        echo "  TIPO  ;  ID  ;  NOMBRE            ;  DIRECCION IP"
        echo "  ─────────────────────────────────────────────────────────"
        echo ""
        
        if [ -f "$TEMP_DIR/ips_resultado.txt" ]; then
            while IFS=";" read -r tipo vmid name ip; do
                if [ "$tipo" = "VM" ]; then
                    printf "  VM    ; %4s ; %-18s ; %s\n" "$vmid" "$name" "$ip"
                else
                    printf "  LXC   ; %4s ; %-18s ; %s\n" "$vmid" "$name" "$ip"
                fi
            done < "$TEMP_DIR/ips_resultado.txt"
        fi
        
        echo ""
        echo "══════════════════════════════════════════════════════════════"
        echo "  Pool: $pool"
        echo "  Fecha de exportacion: $fecha"
        echo "  Total de instancias: $total_ips"
        echo "  Servidor: $(hostname)"
        echo "  Script: PROXMOX Gestion v7.5 - Esther CN"
        echo "══════════════════════════════════════════════════════════════"
    } > "$correo_temp"
    
    # Enviar correo
    cat "$correo_temp" | mail -s "[Proxmox] IPs del pool: $pool" "$destinatario" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "Correo con IPs enviado a: $destinatario"
        whiptail --title "CORREO ENVIADO" --msgbox "Resultados enviados correctamente a:\n\n$destinatario" 10 55
    else
        log_error "No se pudo enviar el correo a: $destinatario"
        whiptail --title "ERROR" --msgbox "No se pudo enviar el correo.\n\nVerifique que mailx este instalado y configurado:\n  apt-get install mailx" 12 60
    fi
    
    rm -f "$correo_temp"
}

function MenuExportacion {
    local pool="$1"
    local archivo_export=""
    
    while true; do
        local opcion_exp=$(whiptail --title "EXPORTAR RESULTADOS" --menu "Seleccione el destino de exportacion:" 18 65 7 \
            "1" "Exportar a directorio home (~/)" \
            "2" "Exportar a ubicacion personalizada" \
            "3" "Exportar a directorio actual" \
            "4" "Enviar por correo electronico" \
            "5" "No exportar - Solo mostrar" \
            "6" "Volver al menu principal" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ] || [ "$opcion_exp" = "6" ]; then
            return
        fi
        
        case $opcion_exp in
            1)
                archivo_export="$HOME/ips_${pool}_$(date '+%Y%m%d_%H%M%S').txt"
                ExportarArchivo "$archivo_export" "$pool"
                return
                ;;
            2)
                PantallaEspera "Abriendo navegador de directorios..." 1
                if NavegadorDirectorios; then
                    archivo_export="$directorio_seleccionado/ips_${pool}_$(date '+%Y%m%d_%H%M%S').txt"
                    ExportarArchivo "$archivo_export" "$pool"
                fi
                return
                ;;
            3)
                archivo_export="$(pwd)/ips_${pool}_$(date '+%Y%m%d_%H%M%S').txt"
                ExportarArchivo "$archivo_export" "$pool"
                return
                ;;
            4)
                EnviarIPsPorEmail "$pool"
                return
                ;;
            5)
                whiptail --title "INFORMACION" --msgbox "Resultados mostrados en pantalla.\nNo se ha exportado ningun archivo." 8 55
                return
                ;;
        esac
    done
}

#---------------------------------------------------------
# ASISTENTE DE IPs
#---------------------------------------------------------

function AsistenteIPs {
    if ! CheckAPI; then
        MensajeBox "Error de conexion con la API" "ERROR"
        return
    fi

    # Bienvenida
    whiptail --title "ASISTENTE DE DIRECCIONES IP" --msgbox "Bienvenido al Asistente de Direcciones IP\n\nEste asistente le permite:\n\n  - Seleccionar un pool\n  - Encender automaticamente los recursos apagados\n  - Esperar 30 segundos para que obtengan IP\n  - Mostrar las direcciones IP de cada recurso\n  - Exportar los resultados a un archivo\n  - Enviar los resultados por correo electronico\n\nPulse OK para continuar" 20 65

    while true; do
        # Seleccionar pool
        local pools=$(get_pools)
        
        if [ -z "$pools" ]; then
            whiptail --title "Error" --msgbox "No se encontraron pools en el sistema." 8 50
            return
        fi
        
        local pools_array=($pools)
        local menu_options=()
        for pool in "${pools_array[@]}"; do
            local members=$(get_pool_members "$pool")
            local member_count=0
            if [ -n "$members" ]; then
                member_count=$(echo "$members" | grep -c .)
            fi
            menu_options+=("$pool" "(${member_count} miembros)")
        done
        
        local elpool=$(whiptail --title "ASISTENTE IPs - Seleccionar Pool" --menu "Selecciona el pool para obtener sus IPs:" 18 65 8 --cancel-button "Salir" "${menu_options[@]}" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            return
        fi

        # Encender apagados
        local members=$(get_pool_members "$elpool")
        local encendidos=0
        local ya_encendidos=0
        
        if [ -n "$members" ]; then
            {
                echo "0"
                echo "Verificando estado de los recursos..."
                sleep 1
                
                local total=0
                local current=0
                local temp_array=()
                while IFS=':' read vmid type; do
                    temp_array+=("$vmid:$type")
                    total=$((total + 1))
                done <<< "$members"
                
                for member in "${temp_array[@]}"; do
                    IFS=':' read vmid type <<< "$member"
                    current=$((current + 1))
                    percent=$((current * 100 / total))
                    
                    if [ "$type" = "qemu" ]; then
                        local status=$(qm status $vmid 2>/dev/null | awk '{print $2}')
                        if [ "$status" = "stopped" ]; then
                            echo "$percent"
                            echo "Encendiendo VM $vmid..."
                            qm start $vmid 2>/dev/null &
                            encendidos=$((encendidos + 1))
                        else
                            echo "$percent"
                            echo "VM $vmid ya esta encendida..."
                            ya_encendidos=$((ya_encendidos + 1))
                        fi
                    elif [ "$type" = "lxc" ]; then
                        local status=$(pct status $vmid 2>/dev/null | awk '{print $2}')
                        if [ "$status" = "stopped" ]; then
                            echo "$percent"
                            echo "Encendiendo CT $vmid..."
                            pct start $vmid 2>/dev/null &
                            encendidos=$((encendidos + 1))
                        else
                            echo "$percent"
                            echo "CT $vmid ya esta encendido..."
                            ya_encendidos=$((ya_encendidos + 1))
                        fi
                    fi
                    sleep 0.5
                done
                
                echo "100"
                echo "Verificacion completada"
                sleep 1
            } | whiptail --title "ENCENDIENDO RECURSOS" --gauge "Verificando..." 8 65 0
        fi
        
        whiptail --title "Resumen de encendido" --msgbox "Resultado del encendido:\n\n  Recursos encendidos: $encendidos\n  Ya estaban encendidos: $ya_encendidos\n\nSe procedera a esperar 30 segundos\npara que los recursos obtengan IP." 12 55

        # Esperar 30s
        {
            for (( i=30; i>=0; i-- )); do
                percent=$(( (30 - i) * 100 / 30 ))
                echo "$percent"
                echo "Esperando $i segundos..."
                sleep 1
            done
            echo "100"
            echo "Espera completada"
            sleep 1
        } | whiptail --title "ESPERANDO..." --gauge "Los recursos estan obteniendo direcciones IP..." 8 65 0

        # Obtener IPs
        > "$TEMP_DIR/ips_resultado.txt"
        
        {
            echo "0"
            echo "Obteniendo miembros del pool..."
            
            local temp_array=()
            while IFS=':' read vmid type; do
                temp_array+=("$vmid:$type")
            done <<< "$members"
            
            local total=${#temp_array[@]}
            local current=0
            
            for member in "${temp_array[@]}"; do
                IFS=':' read vmid type <<< "$member"
                current=$((current + 1))
                percent=$((current * 100 / total))
                
                local name=""
                local ip=""
                
                if [ "$type" = "qemu" ]; then
                    name=$(get_vm_name "$vmid")
                    [ -z "$name" ] && name="Sin nombre"
                    echo "$percent"
                    echo "Consultando IP de VM $vmid ($name)..."
                    ip=$(qm agent $vmid network-get-interfaces 2>/dev/null | jq -r '.[] | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' 2>/dev/null | head -n1)
                    [ -z "$ip" ] && ip="No disponible"
                    echo "VM;$vmid;$name;$ip" >> "$TEMP_DIR/ips_resultado.txt"
                elif [ "$type" = "lxc" ]; then
                    name=$(get_ct_name "$vmid")
                    [ -z "$name" ] && name="Sin nombre"
                    echo "$percent"
                    echo "Consultando IP de CT $vmid ($name)..."
                    ip=$(pct exec $vmid -- ip -4 addr show 2>/dev/null | grep inet | grep -v 127.0.0.1 | awk '{print $2}' | cut -d "/" -f1 | head -n1)
                    [ -z "$ip" ] && ip="No disponible"
                    echo "LXC;$vmid;$name;$ip" >> "$TEMP_DIR/ips_resultado.txt"
                fi
                sleep 0.5
            done
            
            echo "100"
            echo "Obtencion de IPs completada"
            sleep 1
        } | whiptail --title "OBTENIENDO DIRECCIONES IP" --gauge "Conectando con el pool..." 8 65 0

        # Mostrar resultados
        local resultado=""
        resultado="${resultado}=========================================\n"
        resultado="${resultado}  DIRECCIONES IP DEL POOL: $elpool\n"
        resultado="${resultado}=========================================\n"
        resultado="${resultado}  TIPO  ;  ID  ;  NOMBRE            ;  DIRECCION IP\n"
        resultado="${resultado}-----------------------------------------\n"
        
        local total_ips=0
        
        while IFS=";" read -r tipo vmid name ip; do
            if [ "$tipo" = "VM" ]; then
                resultado="${resultado}  VM    ; $(printf '%4s' $vmid) ; $(printf '%-18s' "$name") ; $ip\n"
            else
                resultado="${resultado}  LXC   ; $(printf '%4s' $vmid) ; $(printf '%-18s' "$name") ; $ip\n"
            fi
            total_ips=$((total_ips + 1))
        done < "$TEMP_DIR/ips_resultado.txt"
        
        resultado="${resultado}=========================================\n"
        resultado="${resultado}  Pool: $elpool\n"
        resultado="${resultado}  Total de instancias: $total_ips\n"
        resultado="${resultado}  Servidor: $(hostname)\n"
        resultado="${resultado}  Fecha: $(date '+%d-%m-%Y %H:%M:%S')\n"
        resultado="${resultado}=========================================\n"
        
        whiptail --title "RESULTADOS - Pool: $elpool" --msgbox "$resultado" 22 75

        # Menú de exportación
        MenuExportacion "$elpool"

        # ¿Otro pool?
        whiptail --title "ASISTENTE IPs" --yesno "Desea consultar las IPs de otro pool?" 8 55
        if [ $? -ne 0 ]; then
            break
        fi
    done
}

#---------------------------------------------------------
# GESTION DE POOLS (ELIMINAR)
#---------------------------------------------------------

function delete_pool {
    local pool=$1
    
    members=$(get_pool_members "$pool")
    
    if [ -n "$members" ]; then
        whiptail --title "Error" --msgbox "El pool '$pool' NO esta vacio. No se puede eliminar." 8 60
        return 1
    else
        if whiptail --title "Confirmar" --yesno "El pool '$pool' esta vacio.\n\nQuieres eliminar el pool?" 10 60; then
            if pvesh delete /pools/$pool 2>/dev/null; then
                log_success "Pool eliminado: $pool"
                whiptail --title "Exito" --msgbox "Pool '$pool' eliminado correctamente" 8 50
                return 0
            else
                log_error "Error al eliminar el pool '$pool'"
                whiptail --title "Error" --msgbox "Error al eliminar el pool '$pool'" 8 50
                return 1
            fi
        else
            whiptail --title "Informacion" --msgbox "Pool no eliminado (conservado para uso futuro)" 8 50
            return 0
        fi
    fi
}

function list_pools {
    local pools=$(get_pools)
    local info=""
    
    if [ -z "$pools" ]; then
        whiptail --title "Informacion" --msgbox "No se encontraron pools en el sistema" 8 50
        return 1
    fi
    
    for pool in $pools; do
        info="${info}POOL: ${pool}\n"
        info="${info}-------------------------------------\n"
        
        local members=$(get_pool_members "$pool")
        
        if [ -z "$members" ]; then
            info="${info}  (vacio - sin miembros)\n"
        else
            while IFS=':' read vmid type; do
                local name=""
                if [ "$type" = "qemu" ]; then
                    name=$(qm config $vmid 2>/dev/null | grep "^name:" | awk '{print $2}')
                elif [ "$type" = "lxc" ]; then
                    name=$(pct config $vmid 2>/dev/null | grep "^hostname:" | awk '{print $2}')
                fi
                [ -z "$name" ] && name="Sin nombre"
                
                if [ "$type" = "qemu" ]; then
                    info="${info}  [VM] ${vmid} - ${name}\n"
                else
                    info="${info}  [CT] ${vmid} - ${name}\n"
                fi
            done <<< "$members"
        fi
        info="${info}\n"
    done
    
    whiptail --title "Listado de Pools" --msgbox "$info" 25 70
}

function delete_vms_from_pool {
    local pool=$1
    log_info "Iniciando eliminacion de VMs/CTs del pool: $pool"
    
    members=$(get_pool_members "$pool")
    
    if [ -z "$members" ]; then
        whiptail --title "Informacion" --msgbox "El pool '$pool' ya esta vacio." 8 50
        delete_pool "$pool"
        return 0
    fi
    
    local member_list=""
    local member_array=()
    local vm_count=0
    local ct_count=0
    
    while IFS=':' read vmid type; do
        if [ "$type" == "qemu" ]; then
            name=$(get_vm_name "$vmid")
            [ -z "$name" ] && name="Sin nombre"
            member_list="${member_list}  [VM] ${vmid} - ${name}\n"
            member_array+=("$vmid:$type")
            vm_count=$((vm_count + 1))
        elif [ "$type" == "lxc" ]; then
            name=$(get_ct_name "$vmid")
            [ -z "$name" ] && name="Sin nombre"
            member_list="${member_list}  [CT] ${vmid} - ${name}\n"
            member_array+=("$vmid:$type")
            ct_count=$((ct_count + 1))
        fi
    done <<< "$members"
    
    local confirm_msg="ADVERTENCIA: Esta accion es IRREVERSIBLE\n\nSe eliminaran TODOS los siguientes miembros del pool '${pool}':\n\n${member_list}\nTotal: ${#member_array[@]} elementos (VMs: $vm_count, CTs: $ct_count)\n\nEsta completamente seguro?"
    
    if ! whiptail --title "CONFIRMACION REQUERIDA" --yesno "$confirm_msg" 22 70; then
        whiptail --title "Cancelado" --msgbox "Operacion cancelada" 8 40
        return 0
    fi
    
    local confirm_text=$(whiptail --title "CONFIRMACION FINAL" --inputbox "Para confirmar, escribe 'ELIMINAR' en mayusculas:" 10 60 3>&1 1>&2 2>&3)
    
    if [ "$confirm_text" != "ELIMINAR" ]; then
        whiptail --title "Cancelado" --msgbox "Operacion cancelada - Texto incorrecto" 8 50
        return 0
    fi
    
    > "$TEMP_DIR/eliminados_pool.txt"
    local total=${#member_array[@]}
    local current=0
    local failed=0
    local success=0
    
    {
        echo "0"
        echo "Iniciando eliminacion..."
        sleep 1
        
        for member in "${member_array[@]}"; do
            IFS=':' read vmid type <<< "$member"
            current=$((current + 1))
            percent=$((current * 100 / total))
            
            if [ "$type" == "qemu" ]; then
                echo "$percent"
                echo "Eliminando VM $vmid..."
                qm stop $vmid 2>/dev/null
                sleep 2
                if qm destroy $vmid --purge 1 2>/dev/null; then
                    echo "VM $vmid eliminada" >> "$TEMP_DIR/eliminados_pool.txt"
                    success=$((success + 1))
                else
                    echo "Fallo al eliminar VM $vmid" >> "$TEMP_DIR/eliminados_pool.txt"
                    failed=$((failed + 1))
                fi
            elif [ "$type" == "lxc" ]; then
                echo "$percent"
                echo "Eliminando CT $vmid..."
                pct stop $vmid 2>/dev/null
                sleep 2
                if pct destroy $vmid --purge 1 2>/dev/null; then
                    echo "CT $vmid eliminado" >> "$TEMP_DIR/eliminados_pool.txt"
                    success=$((success + 1))
                else
                    echo "Fallo al eliminar CT $vmid" >> "$TEMP_DIR/eliminados_pool.txt"
                    failed=$((failed + 1))
                fi
            fi
        done
        
        echo "100"
        if [ $failed -eq 0 ]; then
            echo "Eliminacion completada ($success elementos)"
        else
            echo "Eliminacion: $success exitos, $failed fallos"
        fi
        sleep 1
    } | whiptail --title "Progreso" --gauge "Preparando..." 8 65 0
    
    if [ $failed -eq 0 ]; then
        whiptail --title "Completado" --msgbox "Eliminacion completada exitosamente.\n\nElementos eliminados: $success" 10 55
    else
        whiptail --title "Completado con errores" --msgbox "Eliminacion completada con incidencias.\n\nExitos: $success\nFallos: $failed\n\nRevise el log: $LOG_FILE" 12 60
    fi
    
    correo_msg=""
    printf -v correo_msg '%sPOOL: %s\nTOTAL ELEMENTOS: %s\n\n' "$correo_msg" "$pool" "$total"
    printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
    printf -v correo_msg '%s│ RESULTADOS                                          │\n' "$correo_msg"
    printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
    printf -v correo_msg '%s│ Exitos..: %-42s │\n' "$correo_msg" "$success"
    printf -v correo_msg '%s│ Fallos..: %-42s │\n' "$correo_msg" "$failed"
    printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n\n' "$correo_msg"
    
    if [ $success -gt 0 ]; then
        printf -v correo_msg '%s┌─────────────────────────────────────────────────────┐\n' "$correo_msg"
        printf -v correo_msg '%s│ ELEMENTOS ELIMINADOS                                │\n' "$correo_msg"
        printf -v correo_msg '%s├─────────────────────────────────────────────────────┤\n' "$correo_msg"
        while read -r line; do
            [ -n "$line" ] && printf -v correo_msg '%s│ %-52s │\n' "$correo_msg" "$line"
        done < "$TEMP_DIR/eliminados_pool.txt"
        printf -v correo_msg '%s└─────────────────────────────────────────────────────┘\n' "$correo_msg"
    fi
    
    EnviarNotificacion "Pool eliminado - $pool" "$correo_msg"
    
    delete_pool "$pool"
}

function select_pool {
    local pools=$(get_pools)
    
    if [ -z "$pools" ]; then
        whiptail --title "Error" --msgbox "No se encontraron pools en el sistema." 10 60
        return 1
    fi
    
    local pools_array=($pools)
    local menu_options=()
    for pool in "${pools_array[@]}"; do
        local members=$(get_pool_members "$pool")
        local member_count=0
        if [ -n "$members" ]; then
            member_count=$(echo "$members" | grep -c .)
        fi
        menu_options+=("$pool" "(${member_count} miembros)")
    done
    
    local selected_pool=$(whiptail --title "Seleccionar Pool" --menu "Elige el pool que deseas gestionar:" 15 60 5 "${menu_options[@]}" 3>&1 1>&2 2>&3)
    
    if [ $? -eq 0 ] && [ -n "$selected_pool" ]; then
        echo "$selected_pool"
        return 0
    else
        return 1
    fi
}

function MenuGestionPools {
    while true; do
        choice=$(whiptail --title "GESTOR DE POOLS" --menu "Selecciona una opcion:" 18 65 6 \
            "1" "Listar todos los pools existentes" \
            "2" "Eliminar VMs/CTs de un pool" \
            "3" "Asistente de direcciones IP" \
            "4" "Volver al menu principal" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ] || [ "$choice" = "4" ]; then
            return
        fi
        
        case $choice in
            1) list_pools ;;
            2) 
                selected_pool=$(select_pool)
                if [ $? -eq 0 ]; then
                    delete_vms_from_pool "$selected_pool"
                fi
                ;;
            3) AsistenteIPs ;;
        esac
    done
}

#---------------------------------------------------------
# MENU PRINCIPAL
#---------------------------------------------------------

function MenuPrincipal {
    # Pantalla de bienvenida
    whiptail --title "PROXMOX - GESTION MASIVA v7.5" --msgbox "BIENVENIDO AL SISTEMA DE GESTION PROXMOX\n\nAutor: Esther CN\nDepartamento: Electricidad\n\nEste script le permite:\n\n  - Crear y eliminar usuarios masivamente\n  - Crear maquinas virtuales y contenedores\n  - Gestionar pools (listar, eliminar)\n  - Asistente de direcciones IP\n    (encender recursos, obtener IPs, exportar,\n     enviar por correo electronico)\n\nSeleccione una opcion del menu para comenzar." 22 65
    
    while true; do
        opcion=$(whiptail --title "PROXMOX - GESTION MASIVA v7.5" --menu "Selecciona una opcion:" 18 65 8 \
        "1" "Crear usuarios desde fichero" \
        "2" "Eliminar usuarios desde fichero" \
        "3" "Crear recursos individuales (VM/CT)" \
        "4" "Crear recursos compartidos (VM/CT)" \
        "5" "Gestionar pools (listar/eliminar/IPs)" \
        "6" "Salir" 3>&1 1>&2 2>&3)
        
        if [ $? -ne 0 ]; then
            clear
            exit 0
        fi
        
        case $opcion in
            1) PantallaEspera "Cargando modulo de usuarios..." 1; CrearUsuarios ;;
            2) PantallaEspera "Cargando modulo de eliminacion..." 1; BorrarUsuarios ;;
            3) PantallaEspera "Cargando modulo de recursos..." 1; CrearRecursosIndividuales ;;
            4) PantallaEspera "Cargando modulo de recursos compartidos..." 1; CrearRecursosCompartidos ;;
            5) PantallaEspera "Cargando gestor de pools..." 1; MenuGestionPools ;;
            6) clear; exit 0 ;;
        esac
    done
}

#---------------------------------------------------------
# AYUDA Y PARAMETROS
#---------------------------------------------------------

if [ -n "$1" ]; then
    case "$1" in
        -h | -H | --help)
            echo "PROXMOX Gestion Masiva v7.5"
            echo "Autor: Esther CN - Dpto. Electricidad"
            echo "Uso: $0 [opcion]"
            echo "  -h, --help     Ayuda"
            echo "  -l, --log      Ver log"
            echo "  --rm-log       Borrar log"
            echo "  -V, --version  Version"
            exit 0
            ;;
        -l | -L | --log)
            [ -f "$LOG_FILE" ] && cat "$LOG_FILE" | more || echo "No hay log"
            exit 0
            ;;
        --rm-log)
            rm "$LOG_FILE" &>/dev/null
            echo "Log eliminado"
            exit 0
            ;;
        -V | -v | --version)
            echo "Script PROXMOX v7.5 - Esther CN - Dpto. Electricidad"
            exit 0
            ;;
        *)
            echo "Opcion invalida. Use -h"
            exit 3
            ;;
    esac
fi

#---------------------------------------------------------
# INICIO
#---------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    whiptail --title "Error" --msgbox "Este script debe ejecutarse como root" 8 45
    exit 1
fi

if ! command -v pvesh &> /dev/null; then
    whiptail --title "Error" --msgbox "Este script solo funciona en Proxmox VE" 8 45
    exit 1
fi

if ! command -v whiptail &> /dev/null; then
    apt-get update && apt-get install -y whiptail
fi

if ! command -v jq &> /dev/null; then
    apt-get update && apt-get install -y jq
fi

if [ -n "$EMAIL_NOTIFICACION" ] && ! command -v mail &> /dev/null; then
    apt-get update && apt-get install -y mailx
fi

Limpieza

echo "========================================================" >> "$LOG_FILE"
echo "INICIO: $(date '+%d-%m-%Y %H:%M:%S') - v7.5 - Esther CN - Dpto. Electricidad" >> "$LOG_FILE"
echo "========================================================" >> "$LOG_FILE"

MenuPrincipal
