program elusb2_read;

{ elusb2_read.pas — Descarga los datos de un datalogger Lascar EL-USB-2
  (temperatura + humedad) a CSV, usando libusb-1.0 directamente.

  Puerto a FreePascal/Lazarus del script Python read_elusb2.py.
  Protocolo según el driver oficial de sigrok ("lascar-el-usb"):
    - Init: 3 vendor control transfers (0x40/0x00 wV=0xffff [falla: normal],
      0x40/0x02 wV=0x0002, 0x40/0x02 wV=0x0001).
    - Flush del EP IN antes de cada comando.
    - CLAVE: dejar una LECTURA PENDIENTE en el EP IN antes de escribir el
      comando (el firmware solo responde si hay un read a la espera).
      Aquí se hace con un TThread que bloquea en libusb_bulk_transfer.
    - Comandos: 0x00 0xFF 0xFF (leer config), 0x01 lo hi (guardar config),
      0x03 0xFF 0xFF (descargar datos).

  Compilar:  fpc -Mobjfpc -O2 elusb2_read.pas
  Uso:       ./elusb2_read [-o salida.csv] [--stop]

  Requiere libusb-1.0. Permisos: regla udev
    SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ATTR{idProduct}=="0002", MODE="0666"
  o ejecutar como root.  La descarga NO modifica el logger; --stop sí. }

{$mode objfpc}{$H+}

uses
  cthreads,
  Classes, SysUtils, CTypes, DateUtils, Math;

const
  VID = $10C4;                 // Silicon Labs
  PID = $0002;                 // F32x USBXpress (EL-USB-*)
  EP_OUT = $02;
  EP_IN  = $82;
  LIBUSB_SUCCESS = 0;
  LIBUSB_ERROR_TIMEOUT = -7;
  LIBUSB_ERROR_PIPE = -9;
  REQ_TYPE_VENDOR = $40;

type
  Plibusb_context = Pointer;
  Plibusb_device_handle = Pointer;

function libusb_init(ctx: Pointer): cint; cdecl; external 'libusb-1.0.so.0';
procedure libusb_exit(ctx: Pointer); cdecl; external 'libusb-1.0.so.0';
function libusb_open_device_with_vid_pid(ctx: Pointer; vid, pid: Word): Pointer;
  cdecl; external 'libusb-1.0.so.0';
procedure libusb_close(dev: Pointer); cdecl; external 'libusb-1.0.so.0';
function libusb_control_transfer(dev: Pointer; reqType, bRequest: Byte;
  wValue, wIndex: Word; data: Pointer; wLength: Word; timeout: Cardinal): cint;
  cdecl; external 'libusb-1.0.so.0';
function libusb_bulk_transfer(dev: Pointer; endpoint: Byte; data: Pointer;
  length: cint; transferred: PCint; timeout: Cardinal): cint;
  cdecl; external 'libusb-1.0.so.0';

type
  { Lectura bloqueante en hilo: queda PENDIENTE mientras el hilo principal
    escribe el comando. Es el patrón que exige el firmware del EL-USB-2. }
  TPendingReader = class(TThread)
  private
    FDev: Pointer;
    FBuf: PByte;
    FSize: cint;
    FTransferred: cint;
    FStatus: cint;
  protected
    procedure Execute; override;
  public
    constructor Create(ADev: Pointer; ABuf: PByte; ASize: cint);
    property Status: cint read FStatus;
    property Transferred: cint read FTransferred;
  end;

constructor TPendingReader.Create(ADev: Pointer; ABuf: PByte; ASize: cint);
begin
  inherited Create(True);      // suspendido: primero campos, luego Start
  FDev := ADev;
  FBuf := ABuf;
  FSize := ASize;
  FTransferred := 0;
  FStatus := LIBUSB_ERROR_TIMEOUT;
  FreeOnTerminate := False;
  Start;
end;

procedure TPendingReader.Execute;
begin
  FStatus := libusb_bulk_transfer(FDev, EP_IN, FBuf, FSize, @FTransferred, 3000);
end;

{ ---------------------------------------------------------------- bajo nivel }

procedure InitDevice(dev: Pointer);
begin
  // El primero puede fallar (STALL): es normal, "some of these fail" (sigrok)
  libusb_control_transfer(dev, REQ_TYPE_VENDOR, $00, $FFFF, 0, nil, 0, 100);
  libusb_control_transfer(dev, REQ_TYPE_VENDOR, $02, $0002, 0, nil, 0, 100);
  libusb_control_transfer(dev, REQ_TYPE_VENDOR, $02, $0001, 0, nil, 0, 100);
end;

procedure Flush(dev: Pointer);
var
  buf: array[0..255] of Byte;
  n: cint;
  r: cint;
begin
  repeat
    r := libusb_bulk_transfer(dev, EP_IN, @buf[0], 256, @n, 5);
  until (r <> LIBUSB_SUCCESS) or (n = 0);
end;

{ El firmware exige peticiones de lectura múltiplo de 64 (tamaño de paquete);
  peticiones más pequeñas no reciben respuesta. }
function RoundUp64(x: cint): cint;
begin
  Result := ((x + 63) div 64) * 64;
end;

{ Lee con lectura pendiente previa y escribe el comando. Devuelve FALSE si algo
  falla; si OK, *buf apunta a un bloque GetMem de *n bytes (liberarlo luego). }
function CmdRead(dev: Pointer; cmdData: PByte; cmdLen: cint;
  out buf: PByte; out n: cint; size: cint): Boolean;
var
  reader: TPendingReader;
  r, w: cint;
begin
  Result := False;
  buf := nil;
  n := 0;
  GetMem(buf, size);
  reader := TPendingReader.Create(dev, buf, size);
  Sleep(50);                    // asegura que el read ya está pendiente
  r := libusb_bulk_transfer(dev, EP_OUT, cmdData, cmdLen, @w, 1000);
  reader.WaitFor;
  Result := (r = LIBUSB_SUCCESS) and (reader.Status = LIBUSB_SUCCESS);
  n := reader.Transferred;
  reader.Free;
  if not Result then
  begin
    FreeMem(buf);
    buf := nil;
  end;
end;

{ Lectura sin comando (los datos llegan solos tras la cabecera). }
function PlainRead(dev: Pointer; out buf: PByte; out n: cint; size: cint): Boolean;
var
  reader: TPendingReader;
begin
  Result := False;
  buf := nil;
  n := 0;
  GetMem(buf, size);
  reader := TPendingReader.Create(dev, buf, size);
  Sleep(50);
  reader.WaitFor;
  Result := reader.Status = LIBUSB_SUCCESS;
  n := reader.Transferred;
  reader.Free;
  if not Result then
  begin
    FreeMem(buf);
    buf := nil;
  end;
end;

{ Comando 0x00: lee el bloque de configuración. cfg es un array dinámico. }
function ReadConfig(dev: Pointer; var cfg: TBytes): Boolean;
var
  hdr, data: PByte;
  nh, nd, blen: cint;
  i: Integer;
  cmd: array[0..2] of Byte;
begin
  Result := False;
  SetLength(cfg, 0);
  InitDevice(dev);
  Flush(dev);
  cmd[0] := $00; cmd[1] := $FF; cmd[2] := $FF;
  if not CmdRead(dev, @cmd[0], 3, hdr, nh, 256) then Exit;
  if (nh < 3) or (hdr[0] <> $02) then
  begin
    FreeMem(hdr);
    Exit;
  end;
  blen := cint(hdr[1]) or (cint(hdr[2]) shl 8);
  // Si la cabecera trae datos pegados, aprovecharlos
  if nh > 3 then
  begin
    SetLength(cfg, nh - 3);
    for i := 0 to nh - 4 do
      cfg[i] := hdr[i + 3];
  end;
  FreeMem(hdr);
  if Length(cfg) < blen then
  begin
    if not PlainRead(dev, data, nd, RoundUp64(blen - Length(cfg))) then Exit;
    i := Length(cfg);
    SetLength(cfg, i + nd);
    Move(data[0], cfg[i], nd);
    FreeMem(data);
  end;
  if Length(cfg) >= blen then
  begin
    SetLength(cfg, blen);
    Result := True;
  end;
end;

{ Comando 0x03: descarga los datos grabados (pares temp/hum crudos).
  El dispositivo anuncia el área de datos completa (blen = 32768 B en el
  EL-USB-2) pero la envía en ráfagas de 512 B, cada una cerrada con paquete
  corto, y solo continúa mientras se le relancen lecturas: hay que leer en
  bucle hasta recibir los blen bytes. Parar antes (primer paquete corto o al
  tener solo las muestras) truncaba el registro a 256 lecturas o dejaba la
  transferencia a medias (el firmware se queda esperando y se desconecta
  solo ~1 min después). Luego se descartan los bytes sobrantes (0xFF/relleno). }
function ReadData(dev: Pointer; sampleCount: LongWord; var data: TBytes): Boolean;
var
  hdr, extra: PByte;
  nh, ne, blen, needed, chunk: cint;
  i: Integer;
  cmd: array[0..2] of Byte;
begin
  Result := False;
  SetLength(data, 0);
  InitDevice(dev);
  Flush(dev);
  cmd[0] := $03; cmd[1] := $FF; cmd[2] := $FF;
  if not CmdRead(dev, @cmd[0], 3, hdr, nh, 256) then Exit;
  if (nh < 3) or (hdr[0] <> $02) then
  begin
    FreeMem(hdr);
    Exit;
  end;
  blen := cint(hdr[1]) or (cint(hdr[2]) shl 8);
  if nh > 3 then
  begin
    SetLength(data, nh - 3);
    for i := 0 to nh - 4 do
      data[i] := hdr[i + 3];
  end;
  FreeMem(hdr);
  needed := Integer(sampleCount) * 2;      // solo necesitamos las muestras reales
  if needed > blen then needed := blen;
  while Length(data) < blen do             // bloque completo anunciado (32768 B)
  begin
    chunk := 4096;
    if not PlainRead(dev, extra, ne, chunk) then Break;   // timeout: usar lo leído
    i := Length(data);
    SetLength(data, i + ne);
    if ne > 0 then
      Move(extra[0], data[i], ne);
    FreeMem(extra);
    if ne = 0 then Break;                  // el dispositivo ya no envía más
  end;
  if Length(data) >= needed then
  begin
    SetLength(data, needed);
    Result := True;
  end;
end;

{ Comando 0x01: guarda la configuración. El ACK (0xff) llega tras escribir. }
function SaveConfig(dev: Pointer; const cfg: TBytes): Boolean;
var
  reader: TPendingReader;
  cmd: array[0..2] of Byte;
  ack: array[0..0] of Byte;
  r, w: cint;
begin
  Result := False;
  InitDevice(dev);
  Flush(dev);
  reader := TPendingReader.Create(dev, @ack[0], 1);
  Sleep(50);
  cmd[0] := $01;
  cmd[1] := Byte(Length(cfg) and $FF);
  cmd[2] := Byte((Length(cfg) shr 8) and $FF);
  r := libusb_bulk_transfer(dev, EP_OUT, @cmd[0], 3, @w, 1000);
  if r = LIBUSB_SUCCESS then
    r := libusb_bulk_transfer(dev, EP_OUT, @cfg[0], Length(cfg), @w, 1000);
  reader.WaitFor;
  Result := (r = LIBUSB_SUCCESS) and (reader.Status = LIBUSB_SUCCESS) and
            (reader.Transferred = 1) and (ack[0] = $FF);
  reader.Free;
end;

{ ---------------------------------------------------------------- utilidades }

function Le16(b: PByte): Word;
begin
  Result := Word(b[0]) or (Word(b[1]) shl 8);
end;

function Le32(b: PByte): LongWord;
begin
  Result := LongWord(b[0]) or (LongWord(b[1]) shl 8) or
            (LongWord(b[2]) shl 16) or (LongWord(b[3]) shl 24);
end;

function DewPoint(t, rh: Double): Double;
var
  logEW: Double;
begin
  if (rh <= 0) or (t < -40) or (t > 60) then
    Exit(NaN);
  logEW := 0.66077 + (7.5 * t / (237.3 + t)) + (Log10(rh) - 2);
  Result := ((0.66077 - logEW) * 237.3) / (logEW - 8.16077);
end;

function NombreModelo(id: Byte): string;
begin
  case id of
    1, 2: Result := 'EL-USB-1';
    3: Result := 'EL-USB-2';
    4, 6: Result := 'EL-USB-3';
    5, 7: Result := 'EL-USB-4';
    8: Result := 'EL-USB-LITE';
    9: Result := 'EL-USB-CO';
    10: Result := 'EL-USB-TC';
    11: Result := 'EL-USB-CO300';
    12: Result := 'EL-USB-2-LCD';
    13: Result := 'EL-USB-2+';
    14: Result := 'EL-USB-1-PRO';
    15: Result := 'EL-USB-TC-LCD';
    16: Result := 'EL-USB-2-LCD+';
    17: Result := 'EL-USB-5';
    18: Result := 'EL-USB-1-RCG';
    19, 21: Result := 'EL-USB-1-LCD';
    20: Result := 'EL-OEM-3';
  else
    Result := Format('modelo %d', [id]);
  end;
end;

{ ---------------------------------------------------------------- main }

var
  ctx: Pointer;
  dev: Pointer;
  cfg: TBytes;
  data: TBytes;
  i, n, written: Integer;
  blen: cint;
  serial, fw, nombre, outFile, unidad, tempStr, humStr, dpStr, ts: string;
  unitC, logging, doStop, doJson: Boolean;
  start, first: TDateTime;
  offset, interval, sampleCount: LongWord;
  hiT, loT, hiH, loH: Double;
  temp, hum, dp: Double;
  tRaw, hRaw: Byte;
  line: string;
  sl: TStringList;
  alarmNames: array[0..7] of string;
  alarmEn: Byte;
  enabled: string;

begin
  doStop := False;
  doJson := False;
  outFile := '';
  for i := 1 to ParamCount do
  begin
    if (ParamStr(i) = '--stop') then doStop := True
    else if (ParamStr(i) = '--json') then doJson := True
    else if (ParamStr(i) = '-o') and (i < ParamCount) then outFile := ParamStr(i + 1);
  end;

  ctx := nil;
  if libusb_init(nil) <> LIBUSB_SUCCESS then
  begin
    WriteLn('ERROR: no se pudo inicializar libusb.');
    Halt(1);
  end;

  dev := libusb_open_device_with_vid_pid(nil, VID, PID);
  if dev = nil then
  begin
    WriteLn('ERROR: no se encuentra ningún Lascar EL-USB (10c4:0002).');
    WriteLn('  - ¿Está enchufado? Comprueba con: lsusb');
    WriteLn('  - ¿Permisos? Prueba con sudo o instala la regla udev.');
    libusb_exit(ctx);
    Halt(1);
  end;

  if not ReadConfig(dev, cfg) then
  begin
    WriteLn('ERROR leyendo configuración (¿permisos USB? prueba con sudo).');
    libusb_close(dev);
    libusb_exit(ctx);
    Halt(1);
  end;

  { ---- volcado de información ---- }
  nombre := '';
  for i := 2 to 17 do
    if cfg[i] <> 0 then nombre := nombre + Chr(cfg[i]);
  serial := IntToStr(Le32(@cfg[$34]));
  fw := '';
  for i := $30 to $33 do
    fw := fw + Chr(cfg[i]);
  unitC := Le16(@cfg[$2E]) = 0;
  start := EncodeDateTime(2000 + cfg[$17], cfg[$16], cfg[$15],
                          cfg[$12], cfg[$13], cfg[$14], 0);
  offset := Le32(@cfg[$18]);
  first := IncSecond(start, offset);
  interval := Le16(@cfg[$1C]);
  sampleCount := Le16(@cfg[$1E]);
  alarmEn := cfg[$20];
  hiT := cfg[$22] / 2.0 - 40;
  loT := cfg[$23] / 2.0 - 40;
  hiH := cfg[$38] / 2.0;
  loH := cfg[$39] / 2.0;
  logging := (Le16(@cfg[$20]) and $0100) <> 0;
  alarmNames[0] := 'T alta';    alarmNames[1] := 'T baja';
  alarmNames[2] := 'T alta hold'; alarmNames[3] := 'T baja hold';
  alarmNames[4] := 'HR alta';   alarmNames[5] := 'HR baja';
  alarmNames[6] := 'HR alta hold'; alarmNames[7] := 'HR baja hold';
  enabled := '';
  for i := 0 to 7 do
    if (alarmEn and (1 shl i)) <> 0 then
    begin
      if enabled <> '' then enabled := enabled + ', ';
      enabled := enabled + alarmNames[i];
    end;
  if enabled = '' then enabled := 'ninguna';

  WriteLn('Dispositivo : ', NombreModelo(cfg[0]));
  WriteLn('Serie       : ', serial);
  WriteLn('Nombre      : ', nombre);
  WriteLn('Firmware    : ', fw);
  if unitC then WriteLn('Unidades    : °C') else WriteLn('Unidades    : °F');
  WriteLn('Inicio prog.: ', FormatDateTime('dd/mm/yyyy hh:nn:ss', start));
  WriteLn('1ª lectura  : ', FormatDateTime('dd/mm/yyyy hh:nn:ss', first));
  WriteLn('Intervalo   : ', interval, ' s');
  WriteLn('Lecturas    : ', sampleCount);
  WriteLn(Format('Alarmas     : T alta %.1f | T baja %.1f | HR alta %.0f%% | HR baja %.0f%%',
    [hiT, loT, hiH, loH]));
  if logging then WriteLn('Estado      : GRABANDO') else WriteLn('Estado      : detenido');
  WriteLn('Alarmas act.: ', enabled);

  if not ReadData(dev, sampleCount, data) then
  begin
    WriteLn('ERROR descargando datos.');
    libusb_close(dev);
    libusb_exit(ctx);
    Halt(1);
  end;

  if doJson then
  begin
    if outFile = '' then outFile := 'elusb2_dump.txt';
    sl := TStringList.Create;
    try
      sl.Add('model=' + NombreModelo(cfg[0]));
      sl.Add('serial=' + serial);
      sl.Add('name=' + nombre);
      sl.Add('unit=' + IntToStr(Le16(@cfg[$2E])));
      sl.Add('first_rec=' + FormatDateTime('yyyy-mm-dd hh:nn:ss', first));
      sl.Add('interval=' + IntToStr(interval));
      sl.Add('sample_count=' + IntToStr(sampleCount));
      sl.Add('config=' + IntToHex(Le32(@cfg[0]), 8) + ' len=' + IntToStr(Length(cfg)));
      sl.SaveToFile(outFile);
    finally
      sl.Free;
    end;
    WriteLn('Volcado: ', outFile);
  end
  else
  begin
    if outFile = '' then
      outFile := Format('elusb2_%s.csv', [FormatDateTime('yyyymmdd_hhnnss', Now)]);
    if unitC then unidad := 'Temperatura(°C)' else unidad := 'Temperatura(°F)';
    sl := TStringList.Create;
    try
      sl.Add('N;FechaHora;' + unidad + ';Humedad(%rh);PuntoRocio(°C);Serie');
      written := 0;
      n := Length(data) div 2;
      if n > Integer(sampleCount) then n := Integer(sampleCount);
      for i := 0 to n - 1 do
      begin
        tRaw := data[i * 2];
        hRaw := data[i * 2 + 1];
        temp := tRaw / 2.0 - 40;          // °C (base -40, medios grados)
        if not unitC then temp := temp * 9 / 5 + 32;
        hum := hRaw / 2.0;
        if (temp = 0.0) and (hum = 0.0) then
        begin
          first := IncSecond(first, interval);   // medición inválida
          Continue;
        end;
        if unitC then dp := DewPoint(temp, hum)
        else dp := DewPoint((temp - 32) * 5 / 9, hum);
        ts := FormatDateTime('dd/mm/yyyy hh:nn:ss', first);
        tempStr := Format('%.1f', [temp]);
        humStr := Format('%.0f', [hum]);
        if IsNaN(dp) then dpStr := '' else dpStr := Format('%.1f', [dp]);
        Inc(written);
        sl.Add(Format('%d;%s;%s;%s;%s;%s', [written, ts, tempStr, humStr, dpStr, serial]));
        first := IncSecond(first, interval);
      end;
      sl.SaveToFile(outFile);
    finally
      sl.Free;
    end;
    WriteLn('CSV generado: ', outFile, ' (', written, ' filas)');
  end;

  if doStop then
  begin
    cfg[$21] := cfg[$21] and not $01;     // limpia el bit de grabación
    if SaveConfig(dev, cfg) then
      WriteLn('Configuración guardada (grabación detenida).')
    else
      WriteLn('AVISO: el logger no confirmó la escritura (0xff).');
  end;

  libusb_close(dev);
  libusb_exit(ctx);
end.
