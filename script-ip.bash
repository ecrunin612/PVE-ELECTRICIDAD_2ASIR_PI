#!/bin/bash

# Script para gestionar pools en Proxmox y mostrar/exportar lista de VMs/CTs con sus IPs
# Autor: Esther CN
# Año: 2026
# Uso: ./gestionar_pool.sh [nombre_del_pool]

# Colores para mejor visualización
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Función para verificar si el comando existe
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo -e "${RED}Error: $1 no está instalado${NC}"
        exit 1
    fi
}

# Función para obtener la IP de una VM/CT
get_ip() {
    local TYPE=$1
    local VMID=$2
    local IP="No detectada"
    
    if [ "$TYPE" = "qemu" ]; then
        # Intentar obtener IP vía QEMU Guest Agent
        if qm guest cmd $VMID ping &>/dev/null 2>&1; then
            NETWORK_INFO=$(qm guest cmd $VMID network-get-interfaces 2>/dev/null)
            if [ $? -eq 0 ]; then
                IP=$(echo "$NETWORK_INFO" | jq -r '.[] | select(."ip-addresses" != null) | ."ip-addresses"[] | select(."ip-address-type" == "ipv4" and ."ip-address" != "127.0.0.1") | ."ip-address"' 2>/dev/null | head -n1)
            fi
        fi
        
        # Si no se obtuvo IP del guest agent, buscar en configuración
        if [ "$IP" = "No detectada" ] || [ -z "$IP" ]; then
            IP=$(qm config $VMID 2>/dev/null | grep -E "ipconfig[0-9]+" | grep -oP 'ip=\K[^,]+' | head -n1)
        fi
        
    elif [ "$TYPE" = "lxc" ]; then
        # Para CTs, verificar si está corriendo
        CT_STATUS=$(pct status $VMID 2>/dev/null | awk '{print $2}')
        
        if [ "$CT_STATUS" = "running" ]; then
            # Intentar obtener IP desde dentro del contenedor
            IP=$(pct exec $VMID -- ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
            
            # Si no se obtuvo, intentar con ifconfig
            if [ -z "$IP" ]; then
                IP=$(pct exec $VMID -- ifconfig 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n1)
            fi
        fi
        
        # Si no se obtuvo IP del contenedor, buscar en configuración
        if [ -z "$IP" ] || [ "$IP" = "No detectada" ]; then
            IP=$(pct config $VMID 2>/dev/null | grep -E "net[0-9]+" | grep -oP 'ip=\K[^,]+' | head -n1)
            if [ -z "$IP" ]; then
                IP=$(pct config $VMID 2>/dev/null | grep -E "net[0-9]+" | grep -oP 'ip=\K[^ ]+' | head -n1)
            fi
        fi
    fi
    
    # Si IP está vacía, poner mensaje
    if [ -z "$IP" ]; then
        IP="No detectada"
    fi
    
    echo "$IP"
}

# Función para obtener el nombre de una VM/CT
get_name() {
    local TYPE=$1
    local VMID=$2
    local NAME=""
    
    if [ "$TYPE" = "qemu" ]; then
        NAME=$(qm config $VMID 2>/dev/null | grep "^name:" | awk '{print $2}')
    elif [ "$TYPE" = "lxc" ]; then
        NAME=$(pct config $VMID 2>/dev/null | grep "^hostname:" | awk '{print $2}')
    fi
    
    if [ -z "$NAME" ]; then
        NAME="sin_nombre"
    fi
    
    echo "$NAME"
}

# Función para exportar a archivo
export_to_file() {
    local FILE_PATH="$1"
    local POOL_NAME="$2"
    
    # Crear directorio si no existe
    mkdir -p "$(dirname "$FILE_PATH")" 2>/dev/null
    
    # Crear archivo con cabecera
    echo "TIPO;ID;NOMBRE;DIRECCIÓN IP" > "$FILE_PATH"
    echo "========================================" >> "$FILE_PATH"
    
    # Agregar datos
    for item in "${EXPORT_ARRAY[@]}"; do
        IFS='|' read -r TYPE VMID NAME IP <<< "$item"
        
        # Convertir tipo a formato legible
        if [ "$TYPE" = "qemu" ]; then
            TYPE_TEXT="VM "
        else
            TYPE_TEXT="LXC"
        fi
        
        echo "$TYPE_TEXT;$VMID;$NAME;$IP" >> "$FILE_PATH"
    done
    
    # Agregar información adicional
    echo "" >> "$FILE_PATH"
    echo "========================================" >> "$FILE_PATH"
    echo "Pool: $POOL_NAME" >> "$FILE_PATH"
    echo "Fecha de exportación: $(date '+%Y-%m-%d %H:%M:%S')" >> "$FILE_PATH"
    echo "Total de instancias: ${#EXPORT_ARRAY[@]}" >> "$FILE_PATH"
    echo "Servidor: $(hostname)" >> "$FILE_PATH"
}

# Función para mostrar menú de exportación
show_export_menu() {
    local POOL_NAME="$1"
    local DEFAULT_FILENAME="pool_${POOL_NAME}_$(date '+%Y%m%d_%H%M%S').txt"
    local DEFAULT_PATH="$HOME/$DEFAULT_FILENAME"
    
    echo -e "\n${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}${BOLD}║              MENÚ DE EXPORTACIÓN                         ║${NC}"
    echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${CYAN}${BOLD}Opciones de exportación:${NC}"
    echo -e "  ${GREEN}1)${NC} Exportar a ubicación por defecto:"
    echo -e "     ${YELLOW}$DEFAULT_PATH${NC}"
    echo -e "  ${GREEN}2)${NC} Exportar a ubicación personalizada"
    echo -e "  ${GREEN}3)${NC} Exportar a directorio actual:"
    echo -e "     ${YELLOW}$PWD/$DEFAULT_FILENAME${NC}"
    echo -e "  ${GREEN}4)${NC} No exportar - Solo mostrar en pantalla"
    echo -e "  ${GREEN}5)${NC} Cancelar/Volver"
    
    echo -ne "\n${CYAN}${BOLD}Seleccione una opción [1-5]: ${NC}"
    read -r OPTION
    
    case $OPTION in
        1)
            export_to_file "$DEFAULT_PATH" "$POOL_NAME"
            echo -e "\n${GREEN}${BOLD}✓ Archivo exportado exitosamente:${NC}"
            echo -e "  ${YELLOW}$DEFAULT_PATH${NC}"
            return 0
            ;;
        2)
            echo -ne "\n${CYAN}Ingrese la ruta completa del archivo: ${NC}"
            read -r CUSTOM_PATH
            
            # Expandir ~ si se usa
            CUSTOM_PATH="${CUSTOM_PATH/#\~/$HOME}"
            
            # Verificar si la ruta es válida
            if [ -z "$CUSTOM_PATH" ]; then
                echo -e "${RED}Ruta no válida${NC}"
                return 1
            fi
            
            export_to_file "$CUSTOM_PATH" "$POOL_NAME"
            echo -e "\n${GREEN}${BOLD}✓ Archivo exportado exitosamente:${NC}"
            echo -e "  ${YELLOW}$CUSTOM_PATH${NC}"
            return 0
            ;;
        3)
            LOCAL_PATH="$PWD/$DEFAULT_FILENAME"
            export_to_file "$LOCAL_PATH" "$POOL_NAME"
            echo -e "\n${GREEN}${BOLD}✓ Archivo exportado exitosamente:${NC}"
            echo -e "  ${YELLOW}$LOCAL_PATH${NC}"
            return 0
            ;;
        4)
            echo -e "\n${YELLOW}Continuando sin exportar...${NC}"
            return 0
            ;;
        5)
            echo -e "\n${RED}Operación cancelada${NC}"
            return 1
            ;;
        *)
            echo -e "\n${RED}Opción no válida${NC}"
            return 1
            ;;
    esac
}

# Función para seleccionar pool con menú interactivo
select_pool() {
    # Obtener lista de pools
    mapfile -t POOLS < <(pvesh get /pools --output-format json 2>/dev/null | jq -r '.[].poolid')
    
    # Verificar si hay pools disponibles
    if [ ${#POOLS[@]} -eq 0 ]; then
        echo -e "${RED}${BOLD}No se encontraron pools disponibles${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║           SELECCIÓN DE POOL                              ║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo -e "\n${CYAN}${BOLD}Pools disponibles:${NC}\n"
    
    # Mostrar pools enumerados
    for i in "${!POOLS[@]}"; do
        # Obtener número de miembros del pool
        MEMBER_COUNT=$(pvesh get /pools/${POOLS[$i]} --output-format json 2>/dev/null | jq '.members | length')
        echo -e "  ${GREEN}${BOLD}$((i+1))${NC}) ${YELLOW}${POOLS[$i]}${NC} ${CYAN}(${MEMBER_COUNT} miembros)${NC}"
    done
    
    echo -e "  ${GREEN}${BOLD}0${NC}) ${RED}Salir${NC}"
    
    # Solicitar selección
    echo -ne "\n${CYAN}${BOLD}Seleccione un pool [0-${#POOLS[@]}]: ${NC}"
    read -r SELECTION
    
    # Validar selección
    if [ "$SELECTION" = "0" ]; then
        echo -e "\n${YELLOW}Saliendo...${NC}"
        exit 0
    elif [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le ${#POOLS[@]} ]; then
        SELECTED_POOL="${POOLS[$((SELECTION-1))]}"
        echo -e "\n${GREEN}${BOLD}✓ Pool seleccionado: ${YELLOW}$SELECTED_POOL${NC}"
        return 0
    else
        echo -e "\n${RED}${BOLD}Selección no válida${NC}"
        return 1
    fi
}

# Función principal para procesar el pool
process_pool() {
    local POOL_NAME="$1"
    
    # Verificar si el pool existe
    if ! pvesh get /pools/$POOL_NAME &>/dev/null; then
        echo -e "${RED}Error: El pool '$POOL_NAME' no existe${NC}"
        return 1
    fi
    
    echo -e "\n${BLUE}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║        GESTIÓN DEL POOL: $POOL_NAME$(printf '%*s' $((46 - ${#POOL_NAME})) '')║${NC}"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    
    # Array global para almacenar datos de exportación
    declare -a EXPORT_ARRAY
    
    # Primera pasada: Obtener y mostrar miembros, encender los apagados
    echo -e "\n${CYAN}${BOLD}• Verificando estado de los miembros...${NC}\n"
    
    POOL_MEMBERS=$(pvesh get /pools/$POOL_NAME --output-format json 2>/dev/null | jq -c '.members[]')
    
    if [ -z "$POOL_MEMBERS" ]; then
        echo -e "${YELLOW}El pool '$POOL_NAME' está vacío${NC}"
        return 0
    fi
    
    echo "$POOL_MEMBERS" | while IFS= read -r member; do
        TYPE=$(echo "$member" | jq -r '.type')
        VMID=$(echo "$member" | jq -r '.vmid')
        STATUS=$(echo "$member" | jq -r '.status')
        NAME=$(get_name "$TYPE" "$VMID")
        
        echo -ne "  • $TYPE $VMID ($NAME): "
        
        if [ "$STATUS" = "stopped" ]; then
            echo -e "${YELLOW}APAGADA - Encendiendo...${NC}"
            if [ "$TYPE" = "qemu" ]; then
                qm start $VMID &>/dev/null
            elif [ "$TYPE" = "lxc" ]; then
                pct start $VMID &>/dev/null
            fi
        else
            echo -e "${GREEN}ENCENDIDA${NC}"
        fi
    done
    
    # Esperar a que las instancias arranquen
    echo -e "\n${YELLOW}${BOLD}• Esperando 30 segundos para que las instancias arranquen...${NC}"
    sleep 30
    
    # Segunda pasada: Obtener IPs
    echo -e "\n${CYAN}${BOLD}• Obteniendo direcciones IP...${NC}\n"
    
    while IFS= read -r member; do
        TYPE=$(echo "$member" | jq -r '.type')
        VMID=$(echo "$member" | jq -r '.vmid')
        NAME=$(get_name "$TYPE" "$VMID")
        
        echo -ne "  • Obteniendo IP de $TYPE $VMID ($NAME)... "
        IP=$(get_ip "$TYPE" "$VMID")
        
        if [ "$IP" != "No detectada" ]; then
            echo -e "${GREEN}$IP${NC}"
        else
            echo -e "${RED}No detectada${NC}"
        fi
        
        # Almacenar en array para exportación y visualización
        EXPORT_ARRAY+=("$TYPE|$VMID|$NAME|$IP")
    done < <(echo "$POOL_MEMBERS")
    
    # Mostrar tabla resumen
    echo -e "\n${BLUE}${BOLD}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}${BOLD}║                         RESUMEN DEL POOL                              ║${NC}"
    echo -e "${BLUE}${BOLD}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}${BOLD}║ TIPO  │ ID    │ NOMBRE               │ DIRECCIÓN IP                   ║${NC}"
    echo -e "${BLUE}${BOLD}╠════════════════════════════════════════════════════════════════════════╣${NC}"
    
    for item in "${EXPORT_ARRAY[@]}"; do
        IFS='|' read -r TYPE VMID NAME IP <<< "$item"
        
        # Formatear columnas
        if [ "$TYPE" = "qemu" ]; then
            TYPE_FORMAT="${YELLOW}VM    ${NC}"
        else
            TYPE_FORMAT="${GREEN}LXC   ${NC}"
        fi
        
        # Colorear IP según estado
        if [ "$IP" = "No detectada" ]; then
            IP_FORMAT="${RED}$IP${NC}"
        else
            IP_FORMAT="${GREEN}$IP${NC}"
        fi
        
        printf "${BLUE}${BOLD}║${NC} %-5b ${BLUE}${BOLD}│${NC} %-5s ${BLUE}${BOLD}│${NC} %-20s ${BLUE}${BOLD}│${NC} %-31b ${BLUE}${BOLD}║${NC}\n" \
            "$TYPE_FORMAT" "$VMID" "$NAME" "$IP_FORMAT"
    done
    
    echo -e "${BLUE}${BOLD}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    
    # Mostrar resumen en formato CSV simple
    echo -e "\n${CYAN}${BOLD}• Formato para exportación (CSV):${NC}"
    echo -e "${YELLOW}TIPO;ID;NOMBRE;DIRECCIÓN IP${NC}"
    for item in "${EXPORT_ARRAY[@]}"; do
        IFS='|' read -r TYPE VMID NAME IP <<< "$item"
        
        # Convertir tipo a formato legible
        if [ "$TYPE" = "qemu" ]; then
            TYPE_TEXT="VM "
        else
            TYPE_TEXT="LXC"
        fi
        
        if [ "$IP" = "No detectada" ]; then
            echo -e "${RED}$TYPE_TEXT;$VMID;$NAME;$IP${NC}"
        else
            echo -e "${GREEN}$TYPE_TEXT;$VMID;$NAME;$IP${NC}"
        fi
    done
    
    # Preguntar si desea exportar
    echo -e "\n${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -ne "${MAGENTA}${BOLD}¿Desea exportar los datos a un archivo .txt? (s/N): ${NC}"
    read -r EXPORT_CONFIRM
    
    if [[ "$EXPORT_CONFIRM" =~ ^[Ss]$ ]]; then
        # Mostrar menú de exportación
        if show_export_menu "$POOL_NAME"; then
            echo -e "\n${GREEN}${BOLD}✓ Proceso completado exitosamente${NC}"
        else
            echo -e "\n${YELLOW}⚠ Exportación cancelada. Datos mostrados solo en pantalla.${NC}"
        fi
    else
        echo -e "\n${YELLOW}• Datos mostrados solo en pantalla (no se exportaron)${NC}"
    fi
    
    # Información adicional
    echo -e "\n${CYAN}${BOLD}• Notas:${NC}"
    echo -e "  ${YELLOW}• Si aparece 'No detectada', puede necesitar:${NC}"
    echo -e "    - VM: Tener QEMU Guest Agent instalado y funcionando"
    echo -e "    - CT: Tener el contenedor completamente arrancado"
    echo -e "    - Esperar unos minutos e intentar nuevamente"
    echo -e "\n${GREEN}${BOLD}✓ Script completado${NC}\n"
}

# ============================================
# INICIO DEL SCRIPT
# ============================================

# Verificar comandos necesarios
check_command "pvesh"
check_command "qm"
check_command "pct"
check_command "jq"

echo -e "${BLUE}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     GESTOR DE POOLS PROXMOX - INFORMACIÓN DE RED            ║"
echo "║     Versión 2.0 - Menú Interactivo                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Verificar si se pasó un pool como argumento
if [ $# -ge 1 ]; then
    POOL_NAME="$1"
    echo -e "${CYAN}Usando pool proporcionado como argumento: ${YELLOW}$POOL_NAME${NC}"
    
    # Verificar si el pool existe
    if ! pvesh get /pools/$POOL_NAME &>/dev/null; then
        echo -e "${RED}Error: El pool '$POOL_NAME' no existe${NC}"
        echo -e "${YELLOW}Cambiando a modo de selección interactiva...${NC}"
        if ! select_pool; then
            exit 1
        fi
        POOL_NAME="$SELECTED_POOL"
    fi
else
    # Modo interactivo - Seleccionar pool
    if ! select_pool; then
        echo -e "${RED}No se pudo seleccionar un pool. Saliendo...${NC}"
        exit 1
    fi
    POOL_NAME="$SELECTED_POOL"
fi

# Procesar el pool seleccionado
process_pool "$POOL_NAME"

# Preguntar si desea procesar otro pool
echo -ne "\n${CYAN}${BOLD}¿Desea procesar otro pool? (s/N): ${NC}"
read -r CONTINUE

if [[ "$CONTINUE" =~ ^[Ss]$ ]]; then
    # Reiniciar el script para seleccionar otro pool
    exec "$0"
fi

echo -e "\n${GREEN}${BOLD}¡Hasta luego!${NC}\n"
exit 0
