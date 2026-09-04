#!/usr/bin/env python3
# gen_lrs.py — Regenera main.lrs a partir de main.lfm.
# Formato CORRECTO (validado headless con TLazarusResourceStream):
#   - UN solo string por recurso con #13#10 incrustados (igual que los .lrs
#     reales de los componentes de Lazarus; el formato "array de líneas"
#     rompe la firma del TReader -> "Invalid Filer Signature").
#   - Registra 'frmMain' (convención IDE) y 'TfrmMain' (ClassName que busca
#     el LCL en TForm.InitResource).
# Uso: python3 gen_lrs.py   (ejecutar en el directorio del proyecto)
import os

HERE = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(HERE, 'main.lfm')
dst = os.path.join(HERE, 'main.lrs')

lines = open(src, encoding='utf-8').read().split('\n')
if lines and lines[-1] == '':
    lines.pop()

def esc(s):
    return s.replace("'", "''")

def write_resource(f, name):
    f.write("LazarusResources.Add('" + name + "','FORMDATA',[\n")
    f.write("  '" + esc(lines[0]) + "'#13#10\n")
    for ln in lines[1:]:
        f.write("  +'" + esc(ln) + "'#13#10\n")
    f.write(']);\n')

with open(dst, 'w', encoding='utf-8') as f:
    write_resource(f, 'frmMain')
    write_resource(f, 'TfrmMain')

print(f'{dst} regenerado ({len(lines)} lineas, single-string #13#10, frmMain + TfrmMain)')
