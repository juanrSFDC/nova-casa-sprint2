#!/usr/bin/env python3
"""Publica la temperatura de la batería de este portátil como señal de Nova Casa.

Segunda fuente real (D-8, 25-oct): lee la batería con ioreg (macOS) y publica cada lectura como un
Senal_Sensor__e por la API REST, con la sesión ya autenticada del CLI de Salesforce (sf). Ni token ni
contraseña: si el CLI no tiene sesión, la publicación falla y se dice. La señal entra por el mismo
suscriptor que la del simulador: fuente nova-casa-portatil, activo AST-BOG-PORTATIL-001 (cuarto
técnico, umbral 30/35 °C). Al pararlo (Ctrl+C), la fuente queda en silencio y la vigilancia de E-07 lo
avisa pasados sus Minutos de silencio.

Un solo script a la vez: dos portátiles publicando a la misma fuente y al mismo activo mezclarían sus
series. Guía: docs/guia-demo-portatil.md.

    python3 herramientas/sensor_portatil.py                # una lectura cada 30 s
    python3 herramientas/sensor_portatil.py --intervalo 10
    python3 herramientas/sensor_portatil.py --una-vez      # una sola señal y sale (0 bien, 1 mal)
    python3 herramientas/sensor_portatil.py --seco         # muestra el cuerpo sin publicar
    python3 herramientas/sensor_portatil.py --simular      # respaldo: 30 → 36 °C en unos 10 min, sin batería
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import time

FUENTE = "nova-casa-portatil"
EDIFICIO = "BLD-BOG-001"
ACTIVO = "AST-BOG-PORTATIL-001"
SENSOR = "SNS-BOG-PORTATIL-001"
RUTA_EVENTO = "/services/data/v67.0/sobjects/Senal_Sensor__e/"
INTERVALO_MINIMO = 5
# --simular: de 30 a 36 °C, en línea recta, durante 10 minutos; después se queda en 36.
SIMULADA_DESDE = 30.0
SIMULADA_HASTA = 36.0
SIMULADA_SEGUNDOS = 600
# La línea exacta de la batería; VirtualTemperature es otra cosa y no se usa.
PATRON_TEMPERATURA = re.compile(r'^\s*"Temperature" = (\d+)$', re.MULTILINE)


class SinLectura(Exception):
    """No se pudo leer la batería; el mensaje dice qué hacer."""


def leer_argumentos():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--intervalo", type=int, default=30,
                        help="segundos entre lecturas (mínimo %d; 30 por defecto)" % INTERVALO_MINIMO)
    parser.add_argument("--una-vez", action="store_true", help="manda una sola señal y sale")
    parser.add_argument("--org", default="novacasa", help="alias de la org en el CLI (novacasa por defecto)")
    parser.add_argument("--seco", action="store_true", help="muestra el cuerpo de una señal sin publicarla")
    parser.add_argument("--simular", action="store_true",
                        help="no lee la batería: sube de 30 a 36 °C en unos 10 min (respaldo para la demo)")
    argumentos = parser.parse_args()
    if argumentos.intervalo < INTERVALO_MINIMO:
        parser.error("--intervalo debe ser de al menos %d segundos" % INTERVALO_MINIMO)
    return argumentos


def leer_temperatura():
    """La temperatura de la batería en °C con dos decimales (ioreg la da en centésimas)."""
    if shutil.which("ioreg") is None:
        raise SinLectura("Este equipo no es macOS (no existe ioreg): no se puede leer la batería. "
                         "Para la demo, usa --simular.")
    salida = subprocess.run(["ioreg", "-rn", "AppleSmartBattery"], capture_output=True, text=True)
    encontrada = PATRON_TEMPERATURA.search(salida.stdout)
    if salida.returncode != 0 or encontrada is None:
        raise SinLectura("ioreg no muestra la temperatura de la batería (¿un Mac sin batería?). "
                         "Para la demo, usa --simular.")
    return round(int(encontrada.group(1)) / 100.0, 2)


def temperatura_simulada(segundos):
    avance = min(max(segundos, 0) / float(SIMULADA_SEGUNDOS), 1.0)
    return round(SIMULADA_DESDE + (SIMULADA_HASTA - SIMULADA_DESDE) * avance, 2)


def iso(momento):
    """ISO 8601 en UTC con milisegundos, como el contrato (2026-10-25T15:00:00.000Z)."""
    return momento.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (momento.microsecond // 1000)


def ahora_utc():
    return datetime.datetime.now(datetime.timezone.utc)


def cuerpo_evento(sello, secuencia, grados, leida_en, simulada):
    """El Senal_Sensor__e con los campos que arma SenalSensorService para un mensaje del contrato."""
    prefijo = "sim" if simulada else "portatil"
    id_mensaje = "%s-%s-%06d" % (prefijo, sello, secuencia)
    id_entrega = "dlv-%s%s-%06d" % ("sim-" if simulada else "", sello, secuencia)
    enviada_en = iso(ahora_utc())
    mensaje = {
        "deliveryId": id_entrega,
        "messageId": id_mensaje,
        "messageType": "MEASUREMENT",
        "source": FUENTE,
        "building": {"id": EDIFICIO},
        "asset": {"id": ACTIVO, "name": "Sensor de prueba (portátil)", "type": "TECHNICAL_ROOM"},
        "sensorId": SENSOR,
        "measurement": {"type": "TEMPERATURE", "value": grados, "unit": "CELSIUS"},
        "occurredAt": iso(leida_en),
        "publishedAt": enviada_en,
    }
    return {
        "Origen__c": FUENTE,
        "Id_Mensaje__c": id_mensaje,
        "Clave_Mensaje__c": FUENTE + "|" + id_mensaje,
        "Id_Entrega__c": id_entrega,
        "Tipo_Mensaje__c": "MEASUREMENT",
        "Edificio_Externo__c": EDIFICIO,
        "Activo_Externo__c": ACTIVO,
        "Sensor_Id__c": SENSOR,
        "Tipo_Medicion__c": "TEMPERATURE",
        "Unidad__c": "CELSIUS",
        "Valor__c": grados,
        "Ocurrido_En__c": iso(leida_en),
        "Publicado_En__c": enviada_en,
        "Recibido_En__c": enviada_en,
        "Version_Contrato__c": "1.0",
        "Carga_Cruda__c": json.dumps(mensaje, ensure_ascii=False, separators=(",", ":")),
    }


def primer_json(texto):
    """El primer objeto JSON del texto: el CLI puede escribir avisos antes."""
    inicio = texto.find("{")
    if inicio < 0:
        return None
    try:
        return json.JSONDecoder().raw_decode(texto[inicio:])[0]
    except ValueError:
        return None


def publicar(org, cuerpo):
    """Publica el evento con el CLI. Devuelve None si salió bien, o el error en una línea."""
    orden = ["sf", "api", "request", "rest", RUTA_EVENTO, "-o", org, "-X", "POST",
             "-b", json.dumps(cuerpo, ensure_ascii=False)]
    salida = subprocess.run(orden, capture_output=True, text=True)
    respuesta = primer_json(salida.stdout)
    if salida.returncode == 0 and isinstance(respuesta, dict) and respuesta.get("success") is True:
        return None  # OPERATION_ENQUEUED en errors es informativo: el evento quedó en cola.
    if isinstance(respuesta, list) and respuesta and isinstance(respuesta[0], dict):
        respuesta = respuesta[0]
    if isinstance(respuesta, dict) and (respuesta.get("message") or respuesta.get("errors")):
        return str(respuesta.get("message") or respuesta.get("errors"))
    lineas = [l for l in (salida.stderr + "\n" + salida.stdout).splitlines()
              if l.strip() and "update available" not in l]
    return lineas[-1].strip() if lineas else "el CLI terminó con código %d" % salida.returncode


def grados_texto(grados):
    return ("%.2f" % grados).replace(".", ",") + " °C"


def main():
    argumentos = leer_argumentos()
    if not argumentos.seco and shutil.which("sf") is None:
        print("No se encuentra el CLI de Salesforce (sf) en el PATH.", file=sys.stderr)
        return 2
    aviso = "[SIMULADA] " if argumentos.simular else ""
    if argumentos.simular:
        print("[SIMULADA] Modo --simular: la temperatura NO es de la batería; sube de 30 a 36 °C en unos "
              "10 min y los messageId empiezan por sim-.")

    sello = ahora_utc().strftime("%Y%m%dT%H%M%SZ")
    arranque = time.monotonic()
    enviadas = 0
    fallidas = 0
    secuencia = 0
    try:
        while True:
            vuelta = time.monotonic()
            secuencia += 1
            leida_en = ahora_utc()
            try:
                grados = (temperatura_simulada(vuelta - arranque) if argumentos.simular
                          else leer_temperatura())
            except SinLectura as error:
                print(str(error), file=sys.stderr)
                return 2
            cuerpo = cuerpo_evento(sello, secuencia, grados, leida_en, argumentos.simular)
            hora = datetime.datetime.now().strftime("%H:%M:%S")

            if argumentos.seco:
                print("%s%s · %s · sin publicar (--seco)" % (aviso, hora, grados_texto(grados)))
                print(json.dumps(cuerpo, ensure_ascii=False, indent=2))
                return 0

            error = publicar(argumentos.org, cuerpo)
            if error is None:
                enviadas += 1
                print("%s%s · %s · enviada" % (aviso, hora, grados_texto(grados)), flush=True)
            else:
                fallidas += 1
                print("%s%s · %s · NO enviada: %s" % (aviso, hora, grados_texto(grados), error), flush=True)
            if argumentos.una_vez:
                return 0 if error is None else 1

            espera = argumentos.intervalo - (time.monotonic() - vuelta)
            if espera > 0:
                time.sleep(espera)
    except KeyboardInterrupt:
        print("\n%s%d enviadas, %d fallidas: desde ahora la fuente está en silencio." % (aviso, enviadas, fallidas))
        return 0


if __name__ == "__main__":
    sys.exit(main())
