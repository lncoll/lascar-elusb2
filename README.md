# Lascar EL-USB-2 — lector y configurador para Linux

Aplicación escrita en **FreePascal / Lazarus** para leer y configurar el
registrador de temperatura y humedad **Lascar EL-USB-2** (Silicon Labs
USBXpress, USB `10c4:0002`) directamente desde Linux, sin necesidad del
software de Windows de Lascar.

Comunicación por USB *bulk* (protocolo EasyLog de Lascar, documentado por el
driver `lascar-el-usb` de [sigrok](https://sigrok.org) y la
[wiki de sigrok](https://sigrok.org/wiki/Lascar_Electronics_EL-USB_protocol)).

## Funciones

- **Configuración**: leer y guardar parámetros del registrador (nombre,
  fecha/hora de inicio, intervalo, unidades °C/°F, alarmas de temperatura y
  humedad) e **iniciar/detener** la grabación.
- **Lectura de datos**: descarga la **memoria completa** del registrador
  (sin truncar a 256 lecturas, como hacían las primeras versiones), con las
  fechas/horas calculadas a partir del inicio y el intervalo.
- **Rejilla de datos** y exportación a **CSV** (separador `;`).
- **Gráfica** (TAChart) de temperatura, humedad y punto de rocío, con zoom y
  desplazamiento, valores máx/mín bajo la leyenda y cursor con los valores de
  cada muestra. El eje X muestra como máximo 15 etiquetas.
- Unidad de protocolo (`elusb2_usb.pas`) **sin LCL**: reutilizable desde
  programas de consola.

## Requisitos

- Linux, Lazarus 3.x / FreePascal 3.2+ con el paquete `TAChartLazarusPkg`.
- `libusb-1.0`.
- El registrador EL-USB-2 conectado por USB.

## Compilar

```bash
lazbuild LascarELUSB2.lpi
```

## Permisos USB sin root

Regla udev (`/etc/udev/rules.d/10-elusb.rules`):

```
SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="0002", MODE="0666"
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## Estructura

| Fichero | Contenido |
| --- | --- |
| `main.pas` / `main.lfm` | Formulario principal (pestañas Configuración y Lectura de datos) |
| `chartform.pas` / `chartform.lfm` | Gráfica de datos (TAChart) |
| `elusb2_usb.pas` | Protocolo USB con el registrador (sin LCL) |
| `LascarELUSB2.lpi` / `.lpr` | Proyecto Lazarus |

## Notas de protocolo (peculiaridades del firmware EL-USB-2)

- El firmware solo responde si hay una **lectura pendiente** en el EP IN antes
  de escribir el comando; las peticiones de lectura deben ser **múltiplo de
  64 bytes**.
- La cabecera del comando de descarga anuncia el **área de datos completa**
  (32768 B en el EL-USB-2), pero el firmware la envía en **ráfagas de 512 B**
  cerradas con paquete corto: hay que relanzar lecturas hasta recibir el
  bloque completo (una sola lectura devuelve 512 B = 256 muestras).
- El número real de lecturas está en el bloque de configuración
  (offset `0x1E`, 16 bits little-endian); tras la última muestra el resto del
  área es `0xFF`/relleno.

## Herramientas de línea de órdenes (`tools/`)

Además de la GUI, el mismo protocolo está implementado como herramientas de
consola:

- `tools/read_elusb2.py` — lector en **Python 3 + pyusb**.
  ```bash
  python3 -m venv .venv && .venv/bin/pip install pyusb   # una vez
  .venv/bin/python read_elusb2.py [-o salida.csv] [--json] [--stop]
  ```
- `tools/elusb2_read.pas` — lector en **Pascal de consola** (misma base de
  código que la GUI, sin LCL).
  ```bash
  fpc -Mobjfpc -O2 elusb2_read.pas
  ./elusb2_read [-o salida.csv] [--json] [--stop]
  ```

Ambas descargan la memoria completa (sin el truncado a 256 lecturas) y
comparten las mismas peculiaridades de protocolo documentadas arriba.
`--stop` detiene la grabación en curso (escribe en el registrador); la
descarga normal es de solo lectura.
