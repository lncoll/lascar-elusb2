#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
read_elusb2.py — Descarga los datos de un datalogger Lascar EL-USB-2 (temperatura + humedad)
a CSV, sin el software de Windows.

El EL-USB-2 es un dispositivo USBXpress (ID USB 10c4:0002, MCU SiLabs C8051F321):
NO es un puerto serie (/dev/ttyUSB0); se habla con él mediante transferencias USB
bulk (EP 0x02 salida / 0x82 entrada).

Protocolo según el driver oficial de sigrok (libsigrok, driver "lascar-el-usb",
https://sigrok.org/wiki/Lascar_Electronics_EL-USB_protocol):

  1. Init (modo SiLabs F32x): 3 vendor control transfers
       ctrl 0x40/0x00 wV=0xffff   (puede fallar con STALL: es normal)
       ctrl 0x40/0x02 wV=0x0002
       ctrl 0x40/0x02 wV=0x0001
  2. Flush: drenar datos pendientes del EP IN (reads de 5 ms hasta timeout).
  3. CRÍTICO: dejar una LECTURA PENDIENTE en el EP IN *antes* de escribir el
     comando (el firmware solo responde si hay un read a la espera).
  4. Comandos (bulk OUT, 3 bytes):
       0x00 0xff 0xff  -> leer configuración (cabecera 3 B: 0x02 + longitud LE)
       0x01 lo hi      -> guardar configuración (responde 1 byte 0xff)
       0x03 0xff 0xff  -> transferir datos grabados (cabecera 3 B + bloque)
  5. Config (EL-USB-2): modelo cfg[0]=3; nombre cfg[2:18]; inicio cfg[0x12..0x17];
     offset cfg[0x18] (4B LE); intervalo cfg[0x1c] (2B LE); nº muestras cfg[0x1e]
     (2B LE); alarmas cfg[0x20]; flags cfg[0x21]; temp: raw/2 - 40 (°C); HR: raw/2.

Uso:
    python3 read_elusb2.py                  # descarga a elusb2_AAAAMMDD_HHMMSS.csv
    python3 read_elusb2.py -o datos.csv     # fichero concreto
    python3 read_elusb2.py --stop           # además, DETIENE la grabación en curso
    python3 read_elusb2.py --json           # volcado crudo (config + datos) a JSON

Requisitos: pyusb   (Debian/Ubuntu: sudo apt install python3-usb  |  pip install pyusb)

Permisos sin root (regla udev, /etc/udev/rules.d/10-elusb.rules):
    SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="0002", MODE="0666"
    sudo udevadm control --reload-rules && sudo udevadm trigger

La descarga NO modifica el estado del logger (solo lectura). "--stop" sí escribe.
"""

import argparse
import csv
import datetime as dt
import json
import math
import sys
import threading
import time

import usb.core
import usb.util

VID = 0x10C4            # Silicon Labs
PID = 0x0002            # F32x USBXpress (EL-USB-1/2/3/4/5/CO/TC...)
EP_OUT = 0x02
EP_IN = 0x82
CTRL_TO = 100
XFER_TO = 3000

MODELS = {
    1: "EL-USB-1", 2: "EL-USB-1", 3: "EL-USB-2", 4: "EL-USB-3",
    5: "EL-USB-4", 6: "EL-USB-3", 7: "EL-USB-4", 8: "EL-USB-LITE",
    9: "EL-USB-CO", 10: "EL-USB-TC", 11: "EL-USB-CO300", 12: "EL-USB-2-LCD",
    13: "EL-USB-2+", 14: "EL-USB-1-PRO", 15: "EL-USB-TC-LCD",
    16: "EL-USB-2-LCD+", 17: "EL-USB-5", 18: "EL-USB-1-RCG",
    19: "EL-USB-1-LCD", 20: "EL-OEM-3", 21: "EL-USB-1-LCD",
}


# ---------------------------------------------------------------- USB bajo nivel

def init_device(dev):
    """Modo SiLabs F32x: 3 vendor control transfers (el primero puede stallar)."""
    for req, wv in ((0x00, 0xffff), (0x02, 0x0002), (0x02, 0x0001)):
        try:
            dev.ctrl_transfer(0x40, req, wv, 0, None, CTRL_TO)
        except usb.core.USBError:
            pass          # sigrok: "some of these fail, but it needs doing"


def flush(dev):
    """Drena datos pendientes del EP IN (reads de 5 ms hasta timeout)."""
    while True:
        try:
            if not len(dev.read(EP_IN, 256, 5)):
                break
        except usb.core.USBError as e:
            if e.errno == 110:      # timeout -> limpio
                break
            raise


def _pending_read(dev, n, to):
    """Read en hilo (queda pendiente) y devuelve el resultado."""
    res = {}

    def reader():
        try:
            res["data"] = list(dev.read(EP_IN, n, to))
            res["ok"] = True
        except Exception as e:      # noqa: BLE001
            res["err"] = e
            res["ok"] = False

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    return th, res


def cmd_read(dev, cmd, n, to=XFER_TO):
    """CRÍTICO: deja la lectura pendiente ANTES de escribir el comando (patrón sigrok)."""
    th, res = _pending_read(dev, n, to)
    time.sleep(0.05)
    dev.write(EP_OUT, cmd, 1000)
    th.join(to / 1000 + 1)
    if not res.get("ok"):
        raise res.get("err") if "err" in res else usb.core.USBError("timeout")
    return res["data"]


def plain_read(dev, n, to=XFER_TO):
    """Lectura sin comando previo (los datos ya van a llegar)."""
    th, res = _pending_read(dev, n, to)
    time.sleep(0.05)
    th.join(to / 1000 + 1)
    if not res.get("ok"):
        raise res.get("err") if "err" in res else usb.core.USBError("timeout")
    return res["data"]


def read_config(dev):
    """Comando 0x00: devuelve el buffer de configuración."""
    init_device(dev)
    flush(dev)
    header = cmd_read(dev, [0x00, 0xFF, 0xFF], 256)
    if len(header) < 3 or header[0] != 0x02:
        raise RuntimeError(f"cabecera de configuración inesperada: {header}")
    blen = header[1] | (header[2] << 8)
    data = list(header[3:])                    # por si la cabecera trae datos pegados
    need = blen - len(data)
    if need > 0:
        data += plain_read(dev, need)
    return data[:blen]


def read_data(dev):
    """Comando 0x03: descarga los datos grabados. Devuelve (header, bytes).

    La cabecera anuncia el área de datos completa (32768 B en el EL-USB-2),
    pero el firmware la envía en ráfagas de 512 B cerradas con paquete corto
    y solo continúa mientras se le relancen lecturas. Una única lectura se
    queda en la primera ráfaga (512 B = 256 muestras): hay que leer en bucle
    hasta completar los blen bytes (patrón del driver sigrok).
    """
    init_device(dev)
    flush(dev)
    first = cmd_read(dev, [0x03, 0xFF, 0xFF], 256)
    if len(first) < 3 or first[0] != 0x02:
        raise RuntimeError(f"cabecera de datos inesperada: {first}")
    blen = first[1] | (first[2] << 8)
    data = list(first[3:])
    while len(data) < blen:
        try:
            data += plain_read(dev, 4096)   # cada read devuelve una ráfaga (≤512 B)
        except usb.core.USBError as e:
            print(f"AVISO: lectura de datos incompleta ({e}); usando lo recibido.",
                  file=sys.stderr)
            break
    return first[:3], data[:blen]


def save_config(dev, cfg):
    """Comando 0x01: guarda la configuración (¡modifica el logger!).
    El ACK (0xff) llega DESPUÉS de escribir el bloque de configuración."""
    init_device(dev)
    flush(dev)
    blen = len(cfg)
    th, res = _pending_read(dev, 1, XFER_TO)
    time.sleep(0.05)
    dev.write(EP_OUT, [0x01, blen & 0xFF, (blen >> 8) & 0xFF], 1000)
    dev.write(EP_OUT, cfg, 1000)
    th.join(XFER_TO / 1000 + 1)
    if not res.get("ok"):
        raise res.get("err") if "err" in res else usb.core.USBError("timeout")
    return res["data"] == [0xFF]


# ---------------------------------------------------------------- utilidades

def le16(b):
    return b[0] | (b[1] << 8)


def le32(b):
    return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)


def dew_point(t_c, rh):
    """Punto de rocío en °C (Magnus)."""
    if rh <= 0 or t_c < -40 or t_c > 60:
        return float("nan")
    log_ew = 0.66077 + (7.5 * t_c / (237.3 + t_c)) + (math.log10(rh) - 2)
    return round(((0.66077 - log_ew) * 237.3) / (log_ew - 8.16077), 1)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="Lee un datalogger Lascar EL-USB-2")
    ap.add_argument("-o", "--output", help="fichero CSV de salida")
    ap.add_argument("--stop", action="store_true",
                    help="detener la grabación en curso tras descargar (escribe en el logger)")
    ap.add_argument("--json", action="store_true", help="volcar config+datos crudos a JSON")
    args = ap.parse_args()

    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("ERROR: no se encuentra ningún Lascar EL-USB (10c4:0002).\n"
                 "  - ¿Está enchufado? Comprueba con: lsusb\n"
                 "  - ¿Permisos? Prueba con sudo, o instala la regla udev del encabezado.")

    try:
        cfg = read_config(dev)
    except usb.core.USBError as e:
        sys.exit(f"ERROR leyendo configuración: {e}\n"
                 "  ¿Permisos? Prueba con sudo o instala la regla udev del encabezado.")

    model_id = cfg[0]
    model_name = MODELS.get(model_id, f"modelo desconocido ({model_id})")
    if model_id not in (3, 12, 13, 16):
        print(f"AVISO: script pensado para EL-USB-2; detectado: {model_name}")

    name = bytes(cfg[2:18]).split(b"\x00")[0].decode("latin-1")
    serial = str(le32(cfg[0x34:0x38]))
    unit = le16(cfg[0x2E:0x30])          # 0 = °C, 1 = °F
    start = dt.datetime(2000 + cfg[0x17], cfg[0x16], cfg[0x15],
                        cfg[0x12], cfg[0x13], cfg[0x14])
    offset = le32(cfg[0x18:0x1C])        # segundos hasta el inicio de la grabación
    first_rec = start + dt.timedelta(seconds=offset)
    interval = le16(cfg[0x1C:0x1E])
    sample_count = le16(cfg[0x1E:0x20])
    alarm_en = cfg[0x20]                 # bitfield de alarmas habilitadas
    hi_alarm = cfg[0x22] / 2.0 - 40
    lo_alarm = cfg[0x23] / 2.0 - 40
    hi_hum_alarm = cfg[0x38] / 2.0
    lo_hum_alarm = cfg[0x39] / 2.0
    flags = le16(cfg[0x20:0x22]) & 0x1FFF   # byte alto bit 0 = grabando (sigrok)
    logging = bool(flags & 0x0100)       # bit 8: grabando
    alarm_names = ["T alta", "T baja", "T alta hold", "T baja hold",
                   "HR alta", "HR baja", "HR alta hold", "HR baja hold"]
    enabled = [alarm_names[i] for i in range(8) if alarm_en & (1 << i)]

    print(f"Dispositivo : {model_name}")
    print(f"Serie       : {serial}")
    print(f"Nombre      : {name}")
    print(f"Firmware    : {bytes(cfg[0x30:0x34]).decode('latin-1')}")
    print(f"Unidades    : {'°C' if unit == 0 else '°F'}")
    print(f"Inicio prog.: {start:%d/%m/%Y %H:%M:%S}")
    print(f"1ª lectura  : {first_rec:%d/%m/%Y %H:%M:%S}")
    print(f"Intervalo   : {interval} s")
    print(f"Lecturas    : {sample_count}")
    print(f"Alarmas     : T alta {hi_alarm:.1f} | T baja {lo_alarm:.1f} | "
          f"HR alta {hi_hum_alarm:.0f}% | HR baja {lo_hum_alarm:.0f}%")
    print(f"Estado      : {'GRABANDO' if logging else 'detenido'}")
    print(f"Alarmas act.: {', '.join(enabled) if enabled else 'ninguna'}")

    header, data = read_data(dev)
    n_samples = min(sample_count, len(data) // 2)
    readings = [(data[i * 2], data[i * 2 + 1]) for i in range(n_samples)]

    if args.json:
        out_json = args.output or "elusb2_dump.json"
        with open(out_json, "w") as f:
            json.dump({
                "model": model_name, "serial": serial, "name": name,
                "unit": unit, "first_rec": first_rec.isoformat(),
                "interval": interval, "sample_count": sample_count,
                "config": cfg, "data_header": header, "raw_data": data,
            }, f, indent=2)
        print(f"Volcado JSON: {out_json}")
        return

    out = args.output or f"elusb2_{dt.datetime.now():%Y%m%d_%H%M%S}.csv"
    unit_text = "Temperatura(°C)" if unit == 0 else "Temperatura(°F)"
    with open(out, "w", newline="") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(["N", "FechaHora", unit_text, "Humedad(%rh)", "PuntoRocio(°C)", "Serie"])
        t = first_rec
        written = 0
        for t_raw, h_raw in readings:
            temp = t_raw / 2.0 - 40          # °C (base -40, medios grados)
            if unit != 0:
                temp = temp * 9 / 5 + 32     # -> °F
            hum = h_raw / 2.0
            if temp == 0.0 and hum == 0.0:   # medición inválida
                t += dt.timedelta(seconds=interval)
                continue
            t_c = temp if unit == 0 else (temp - 32) * 5 / 9
            dp = dew_point(t_c, hum)
            w.writerow([written + 1, t.strftime("%d/%m/%Y %H:%M:%S"),
                        f"{temp:.1f}", f"{hum:.0f}",
                        f"{dp:.1f}" if not math.isnan(dp) else "", serial])
            t += dt.timedelta(seconds=interval)
            written += 1
    print(f"CSV generado: {out} ({written} filas)")

    if args.stop:
        if logging:
            cfg[0x21] = cfg[0x21] & ~0x01     # limpia el bit de grabación
        if save_config(dev, cfg):
            print("Configuración guardada (grabación detenida).")
        else:
            print("AVISO: el logger no confirmó la escritura (0xff).", file=sys.stderr)


if __name__ == "__main__":
    main()
