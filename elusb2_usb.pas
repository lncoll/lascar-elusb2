unit elusb2_usb;

{ elusb2_usb.pas — Comunicación con el datalogger Lascar EL-USB-2 vía libusb-1.0.
  Protocolo según el driver oficial de sigrok ("lascar-el-usb").
  Peculiaridades del firmware (documentadas tras depuración real):
    1. Dejar una LECTURA PENDIENTE en el EP IN antes de escribir el comando
       (el firmware solo responde si hay un read a la espera).
    2. Las peticiones de lectura deben ser MÚLTIPLO DE 64 bytes.
    3. Los datos llegan en ráfagas de 512 B cerradas con paquete corto.
  Esta unidad NO usa LCL: sirve para consola y para GUI. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, CTypes, DateUtils, Math;

const
  VID = $10C4;                 // Silicon Labs
  PID = $0002;                 // F32x USBXpress (EL-USB-*)
  EP_OUT = $02;
  EP_IN = $82;
  LIBUSB_SUCCESS = 0;
  LIBUSB_ERROR_TIMEOUT = -7;
  REQ_TYPE_VENDOR = $40;

type
  TSample = record
    T: TDateTime;
    Temp: Double;              // en la unidad configurada (°C o °F)
    Hum: Double;               // %rh
    Dew: Double;               // punto de rocío, siempre °C
  end;

  TSampleArray = array of TSample;

  TDeviceInfo = record
    ModelID: Byte;
    ModelName: string;
    Serial: string;
    FW: string;
    Name: string;
    UnitC: Boolean;            // True = °C, False = °F
    Start: TDateTime;          // fecha/hora de inicio programada
    FirstRec: TDateTime;       // fecha/hora de la 1ª lectura
    Interval: LongWord;        // segundos entre muestras
    SampleCount: LongWord;
    AlarmEn: Byte;             // bitfield de alarmas habilitadas
    HiT, LoT: Double;          // alarmas de temperatura
    HiH, LoH: Double;          // alarmas de humedad
    Logging: Boolean;          // bit de grabación
  end;

var
  ElusbLastError: string = '';

function ElusbOpen: Pointer;
procedure ElusbClose(dev: Pointer);
function ElusbReadConfig(dev: Pointer; out cfg: TBytes): Boolean;
function ElusbReadData(dev: Pointer; sampleCount: LongWord; out data: TBytes): Boolean;
function ElusbSaveConfig(dev: Pointer; const cfg: TBytes): Boolean;
function ElusbParseConfig(const cfg: TBytes): TDeviceInfo;
function ElusbParseSamples(const data: TBytes; const info: TDeviceInfo): TSampleArray;
function ElusbModelName(id: Byte): string;

implementation

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
function libusb_claim_interface(dev: Pointer; interface_number: cint): cint;
  cdecl; external 'libusb-1.0.so.0';
function libusb_release_interface(dev: Pointer; interface_number: cint): cint;
  cdecl; external 'libusb-1.0.so.0';

type
  { Lectura bloqueante en hilo: queda PENDIENTE mientras el hilo principal
    escribe el comando (patrón que exige el firmware). }
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
  inherited Create(True);
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

function RoundUp64(x: cint): cint;
begin
  Result := ((x + 63) div 64) * 64;
end;

procedure InitDevice(dev: Pointer);
begin
  { El primero puede fallar (STALL): es normal ("some of these fail", sigrok). }
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
  Sleep(50);
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

function ElusbOpen: Pointer;
begin
  if libusb_init(nil) <> LIBUSB_SUCCESS then
  begin
    ElusbLastError := 'libusb_init falló';
    Exit(nil);
  end;
  Result := libusb_open_device_with_vid_pid(nil, VID, PID);
  if Result = nil then
    ElusbLastError := 'dispositivo 10c4:0002 no encontrado'
  else if libusb_claim_interface(Result, 0) <> LIBUSB_SUCCESS then
  begin
    ElusbLastError := 'no se pudo reclamar la interfaz 0';
    libusb_close(Result);
    Result := nil;
  end;
end;

procedure ElusbClose(dev: Pointer);
begin
  if dev <> nil then
  begin
    libusb_release_interface(dev, 0);
    libusb_close(dev);
  end;
  libusb_exit(nil);
end;

function ElusbReadConfig(dev: Pointer; out cfg: TBytes): Boolean;
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
  if not CmdRead(dev, @cmd[0], 3, hdr, nh, 256) then
  begin
    ElusbLastError := 'timeout leyendo cabecera de configuración';
    Exit;
  end;
  if (nh < 3) or (hdr[0] <> $02) then
  begin
    FreeMem(hdr);
    ElusbLastError := 'cabecera de configuración inesperada';
    Exit;
  end;
  blen := cint(hdr[1]) or (cint(hdr[2]) shl 8);
  if nh > 3 then
  begin
    SetLength(cfg, nh - 3);
    for i := 0 to nh - 4 do
      cfg[i] := hdr[i + 3];
  end;
  FreeMem(hdr);
  if Length(cfg) < blen then
  begin
    if not PlainRead(dev, data, nd, RoundUp64(blen - Length(cfg))) then
    begin
      ElusbLastError := 'timeout leyendo bloque de configuración';
      Exit;
    end;
    i := Length(cfg);
    SetLength(cfg, i + nd);
    Move(data[0], cfg[i], nd);
    FreeMem(data);
  end;
  if Length(cfg) >= blen then
  begin
    SetLength(cfg, blen);
    Result := True;
  end
  else
    ElusbLastError := 'bloque de configuración incompleto';
end;

function ElusbReadData(dev: Pointer; sampleCount: LongWord; out data: TBytes): Boolean;
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
  if not CmdRead(dev, @cmd[0], 3, hdr, nh, 256) then
  begin
    ElusbLastError := 'timeout leyendo cabecera de datos';
    Exit;
  end;
  if (nh < 3) or (hdr[0] <> $02) then
  begin
    FreeMem(hdr);
    ElusbLastError := 'cabecera de datos inesperada';
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
  needed := Integer(sampleCount) * 2;
  if needed > blen then needed := blen;
  { Leer en trozos de 4096 hasta recibir el bloque COMPLETO que anuncia la
    cabecera (blen = 32768 B en el EL-USB-2: el área de datos completa).
    El firmware NO lo envía de una vez: manda el área en ráfagas de 512 B,
    cada una cerrada con paquete corto, y solo continúa mientras se le
    relancen lecturas (patrón del driver sigrok: resubmit hasta log_size).
    Parar al primer paquete corto dejaba la descarga en 512 B = 256 muestras
    (con más de 256 lecturas el programa solo cargaba 256); y detenerse a
    mitad de la transferencia deja el firmware esperando (se desconecta solo
    ~1 min después). Al final se descartan los bytes sobrantes (0xFF/relleno)
    y se conservan solo las sampleCount*2 primeras muestras reales. }
  while Length(data) < blen do
  begin
    chunk := 4096;
    if not PlainRead(dev, extra, ne, chunk) then
    begin
      ElusbLastError := 'timeout leyendo datos';
      Break;
    end;
    i := Length(data);
    SetLength(data, i + ne);
    if ne > 0 then
      Move(extra[0], data[i], ne);
    FreeMem(extra);
    if ne = 0 then Break;   { el dispositivo ya no envía más }
  end;
  if Length(data) >= needed then
  begin
    SetLength(data, needed);
    Result := True;
  end
  else
  begin
    Result := False;
    if ElusbLastError = '' then
      ElusbLastError := Format('datos incompletos: %d de %d bytes recibidos',
        [Length(data), needed]);
  end;
end;

function ElusbSaveConfig(dev: Pointer; const cfg: TBytes): Boolean;
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
  if not Result then
    ElusbLastError := 'el logger no confirmó la escritura (ACK)';
end;

function ElusbModelName(id: Byte): string;
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

function Le16(b: PByte): Word;
begin
  Result := Word(b[0]) or (Word(b[1]) shl 8);
end;

function Le32(b: PByte): LongWord;
begin
  Result := LongWord(b[0]) or (LongWord(b[1]) shl 8) or
            (LongWord(b[2]) shl 16) or (LongWord(b[3]) shl 24);
end;

function ElusbParseConfig(const cfg: TBytes): TDeviceInfo;
var
  i: Integer;
  flags: Word;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ModelID := cfg[0];
  Result.ModelName := ElusbModelName(cfg[0]);
  Result.Name := '';
  for i := 2 to 17 do
    if cfg[i] <> 0 then
      Result.Name := Result.Name + Chr(cfg[i]);
  Result.Serial := IntToStr(Le32(@cfg[$34]));
  Result.FW := '';
  for i := $30 to $33 do
    Result.FW := Result.FW + Chr(cfg[i]);
  Result.UnitC := Le16(@cfg[$2E]) = 0;
  Result.Start := EncodeDateTime(2000 + cfg[$17], cfg[$16], cfg[$15],
    cfg[$12], cfg[$13], cfg[$14], 0);
  Result.FirstRec := IncSecond(Result.Start, Le32(@cfg[$18]));
  Result.Interval := Le16(@cfg[$1C]);
  Result.SampleCount := Le16(@cfg[$1E]);
  Result.AlarmEn := cfg[$20];
  Result.HiT := cfg[$22] / 2.0 - 40;
  Result.LoT := cfg[$23] / 2.0 - 40;
  Result.HiH := cfg[$38] / 2.0;
  Result.LoH := cfg[$39] / 2.0;
  flags := (Le16(@cfg[$20]) and $1FFF);
  Result.Logging := (flags and $0100) <> 0;
end;

function DewPoint(t, rh: Double): Double; forward;

function ElusbParseSamples(const data: TBytes; const info: TDeviceInfo): TSampleArray;
var
  n, i, written: Integer;
  tRaw, hRaw: Byte;
  temp, hum, t: Double;
begin
  n := Length(data) div 2;
  if n > Integer(info.SampleCount) then n := Integer(info.SampleCount);
  SetLength(Result, n);
  written := 0;
  t := info.FirstRec;
  for i := 0 to n - 1 do
  begin
    tRaw := data[i * 2];
    hRaw := data[i * 2 + 1];
    temp := tRaw / 2.0 - 40;             // °C (base -40, medios grados)
    if not info.UnitC then
      temp := temp * 9 / 5 + 32;
    hum := hRaw / 2.0;
    if (temp = 0.0) and (hum = 0.0) then
    begin                                 // medición inválida
      t := t + info.Interval / SecsPerDay;
      Continue;
    end;
    Result[written].T := t;
    Result[written].Temp := temp;
    Result[written].Hum := hum;
    if info.UnitC then
      Result[written].Dew := DewPoint(temp, hum)
    else
      Result[written].Dew := DewPoint((temp - 32) * 5 / 9, hum);
    Inc(written);
    t := t + info.Interval / SecsPerDay;
  end;
  SetLength(Result, written);
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

end.
