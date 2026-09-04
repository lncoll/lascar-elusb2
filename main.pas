unit main;

{ main.pas — Formulario principal de la aplicación Lascar EL-USB-2.
  Dos solapas:
    - Configuración: leer/editar/guardar parámetros del logger, iniciar/detener.
    - Lectura de datos: descargar lecturas, verlas en rejilla y guardar CSV. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Grids, Forms, Controls, Graphics, Dialogs, ComCtrls, StdCtrls,
  Spin, ExtCtrls, DateUtils, Math, StrUtils, LResources,
  elusb2_usb, chartform;

type

  { TfrmMain }

  TfrmMain = class(TForm)
    btnChart: TButton;
    btnDownload: TButton;
    btnLoadCSV: TButton;
    btnNow: TButton;
    btnReadConfig: TButton;
    btnSaveConfig: TButton;
    btnSaveCSV: TButton;
    btnStart: TButton;
    btnStop: TButton;
    chkHiH: TCheckBox;
    chkHiT: TCheckBox;
    chkLoH: TCheckBox;
    chkLoT: TCheckBox;
    dlgSave: TSaveDialog;
    edHiH: TEdit;
    edHiT: TEdit;
    edLoH: TEdit;
    edLoT: TEdit;
    edName: TEdit;
    edStart: TEdit;
    grid: TStringGrid;
    grpAlarms: TGroupBox;
    grpDataInfo: TGroupBox;
    grpDevice: TGroupBox;
    grpParams: TGroupBox;
    lblAlarmHint: TLabel;
    lblDevInterval: TLabel;
    lblDevModel: TLabel;
    lblDevName: TLabel;
    lblDevSamples: TLabel;
    lblDevSerial: TLabel;
    lblDevStart: TLabel;
    lblDevStatus: TLabel;
    lblFw: TLabel;
    lblInterval: TLabel;
    lblName: TLabel;
    lblStart: TLabel;
    lblModel: TLabel;
    lblSamples: TLabel;
    lblSerial: TLabel;
    lblStatus: TLabel;
    memoCfg: TMemo;
    memoData: TMemo;
    pgcMain: TPageControl;
    rgUnit: TRadioGroup;
    spInterval: TSpinEdit;
    tsConfig: TTabSheet;
    tsData: TTabSheet;
    procedure btnChartClick(Sender: TObject);
    procedure btnDownloadClick(Sender: TObject);
    procedure btnLoadCSVClick(Sender: TObject);
    procedure btnNowClick(Sender: TObject);
    procedure btnReadConfigClick(Sender: TObject);
    procedure btnSaveConfigClick(Sender: TObject);
    procedure btnSaveCSVClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    FInfo: TDeviceInfo;
    FHasInfo: Boolean;
    FData: TSampleArray;
    function OpenDevice(out dev: Pointer): Boolean;
    procedure UpdateConfigUI;
    procedure UpdateDataInfo;
    procedure Log(m: TMemo; const s: string);
    procedure ApplyUItoConfig(var cfg: TBytes);
    procedure gridPrepareCanvas(Sender: TObject; aCol, aRow: Integer; aState: Grids.TGridDrawState);
    function LoadSamplesFromCSV(const AFileName: string; var AData: TSampleArray;
      var AInfo: TDeviceInfo): string;
    procedure ShowSamples(const AData: TSampleArray; const AMsg: string);
  public
    { Importa un CSV de una descarga anterior (modo prueba sin dispositivo) }
    procedure ImportCSVFile(const AFileName: string);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.lfm}

{ Recurso del formulario con el mecanismo ESTÁNDAR {$R *.lfm} (igual que
  EGC Keygen). La clase en main.lfm DEBE ser 'TfrmMain' (no 'TForm'):
  lazbuild registra el recurso con el nombre de clase del .lfm y el LCL lo
  busca por ClassName. El main.lrs manual (gen_lrs.py) YA NO se usa:
  - formato texto -> 'Invalid Filer Signature' (lresources.pp:3983)
  - formato binario registrado como 'TForm' -> EResNotFound (TfrmMain). }

{ ---------------------------------------------------------------- auxiliares }

procedure TfrmMain.Log(m: TMemo; const s: string);
begin
  m.Lines.Add('[' + FormatDateTime('hh:nn:ss', Now) + '] ' + s);
end;

function TfrmMain.OpenDevice(out dev: Pointer): Boolean;
begin
  dev := ElusbOpen;
  Result := dev <> nil;
  if not Result then
    ShowMessage('No se encuentra el Lascar EL-USB-2 (10c4:0002).' + LineEnding +
      LineEnding +
      '¿Está enchufado? ¿Tienes permisos USB?' + LineEnding +
      '(regla udev: SUBSYSTEM=="usb", ATTR{idVendor}=="10c4", ' +
      'ATTR{idProduct}=="0002", MODE="0666")');
end;

procedure TfrmMain.UpdateConfigUI;
begin
  if not FHasInfo then Exit;
  lblModel.Caption := 'Modelo: ' + FInfo.ModelName;
  lblSerial.Caption := 'Serie: ' + FInfo.Serial;
  lblFw.Caption := 'Firmware: ' + FInfo.FW;
  lblSamples.Caption := 'Lecturas: ' + IntToStr(FInfo.SampleCount);
  if FInfo.Logging then
    lblStatus.Caption := 'Estado: GRABANDO'
  else
    lblStatus.Caption := 'Estado: detenido';
  edName.Text := FInfo.Name;
  edStart.Text := FormatDateTime('dd/mm/yyyy hh:nn:ss', FInfo.Start);
  spInterval.Value := FInfo.Interval;
  rgUnit.ItemIndex := Ord(not FInfo.UnitC);
  chkHiT.Checked := (FInfo.AlarmEn and $01) <> 0;
  chkLoT.Checked := (FInfo.AlarmEn and $02) <> 0;
  chkHiH.Checked := (FInfo.AlarmEn and $10) <> 0;
  chkLoH.Checked := (FInfo.AlarmEn and $20) <> 0;
  edHiT.Text := FormatFloat('0.#', FInfo.HiT);
  edLoT.Text := FormatFloat('0.#', FInfo.LoT);
  edHiH.Text := FormatFloat('0.#', FInfo.HiH);
  edLoH.Text := FormatFloat('0.#', FInfo.LoH);
end;

procedure TfrmMain.UpdateDataInfo;
begin
  if not FHasInfo then Exit;
  lblDevModel.Caption := 'Dispositivo: ' + FInfo.ModelName;
  lblDevSerial.Caption := 'Serie: ' + FInfo.Serial;
  lblDevName.Caption := 'Nombre: ' + FInfo.Name;
  lblDevStart.Caption := '1ª lectura: ' + FormatDateTime('dd/mm/yyyy hh:nn:ss', FInfo.FirstRec);
  lblDevInterval.Caption := 'Intervalo: ' + IntToStr(FInfo.Interval) + ' s';
  lblDevSamples.Caption := 'Lecturas: ' + IntToStr(Length(FData));
  if FInfo.Logging then
    lblDevStatus.Caption := 'Estado: GRABANDO'
  else
    lblDevStatus.Caption := 'Estado: detenido';
end;

procedure TfrmMain.ApplyUItoConfig(var cfg: TBytes);
var
  i, off, rawT, rawH: Integer;
  dt: TDateTime;
  unitF: Boolean;
begin
  { Nombre (16 bytes, terminado en 0) }
  for i := 2 to 17 do
    cfg[i] := 0;
  for i := 1 to Length(edName.Text) do
    if i <= 16 then
      cfg[1 + i] := Ord(edName.Text[i]);

  { Fecha/hora de inicio + offset (segundos hasta el inicio) }
  if not TryStrToDateTime(edStart.Text, dt) then
    raise Exception.Create('Fecha de inicio no válida (formato dd/mm/yyyy hh:nn:ss)');
  cfg[$12] := HourOf(dt);
  cfg[$13] := MinuteOf(dt);
  cfg[$14] := SecondOf(dt);
  cfg[$15] := DayOf(dt);
  cfg[$16] := MonthOf(dt);
  cfg[$17] := YearOf(dt) - 2000;
  off := Round((dt - Now) * SecsPerDay);
  if off < 0 then off := 0;
  if off > $00FFFFFF then off := $00FFFFFF;
  cfg[$18] := off and $FF;
  cfg[$19] := (off shr 8) and $FF;
  cfg[$1A] := (off shr 16) and $FF;
  cfg[$1B] := (off shr 24) and $FF;

  { Intervalo }
  cfg[$1C] := spInterval.Value and $FF;
  cfg[$1D] := (spInterval.Value shr 8) and $FF;

  { Unidades (0x2E: 0=°C, 1=°F) }
  unitF := rgUnit.ItemIndex = 1;
  cfg[$2E] := Ord(unitF);
  cfg[$2F] := 0;

  { Alarmas habilitadas }
  cfg[$20] := 0;
  if chkHiT.Checked then cfg[$20] := cfg[$20] or $01;
  if chkLoT.Checked then cfg[$20] := cfg[$20] or $02;
  if chkHiH.Checked then cfg[$20] := cfg[$20] or $10;
  if chkLoH.Checked then cfg[$20] := cfg[$20] or $20;

  { Niveles de alarma }
  if unitF then
    rawT := Round(StrToFloat(edHiT.Text) + 40)
  else
    rawT := Round((StrToFloat(edHiT.Text) + 40) * 2);
  if rawT < 0 then rawT := 0;
  if rawT > 255 then rawT := 255;
  cfg[$22] := rawT;

  if unitF then
    rawT := Round(StrToFloat(edLoT.Text) + 40)
  else
    rawT := Round((StrToFloat(edLoT.Text) + 40) * 2);
  if rawT < 0 then rawT := 0;
  if rawT > 255 then rawT := 255;
  cfg[$23] := rawT;

  rawH := Round(StrToFloat(edHiH.Text) * 2);
  if rawH < 0 then rawH := 0;
  if rawH > 255 then rawH := 255;
  cfg[$38] := rawH;

  rawH := Round(StrToFloat(edLoH.Text) * 2);
  if rawH < 0 then rawH := 0;
  if rawH > 255 then rawH := 255;
  cfg[$39] := rawH;
end;

procedure TfrmMain.gridPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
  aState: Grids.TGridDrawState);
var
  MyTextStyle: TTextStyle;
begin
  MyTextStyle.Alignment := taCenter;
  grid.Canvas.TextStyle := MyTextStyle;
end;

{ Campo AIndex (1-based) de una línea CSV separada por ';' (sin comillas). }
function FieldAt(const s: string; AIndex: Integer): string;
var
  i, p, st: Integer;
begin
  Result := '';
  st := 1;
  for i := 1 to AIndex - 1 do
  begin
    p := PosEx(';', s, st);
    if p = 0 then Exit;
    st := p + 1;
  end;
  p := PosEx(';', s, st);
  if p = 0 then
    Result := Copy(s, st, MaxInt)
  else
    Result := Copy(s, st, p - st);
end;

{ Parsea un CSV generado por la propia app (o el script):
    N;FechaHora;Temperatura(°C/°F);Humedad(%rh);PuntoRocio(°C);Serie
  Devuelve '' si OK (AData/AInfo rellenos) o un mensaje de error. }
function TfrmMain.LoadSamplesFromCSV(const AFileName: string;
  var AData: TSampleArray; var AInfo: TDeviceInfo): string;
var
  sl: TStringList;
  line, s: string;
  i, idx: Integer;
  dt, prevT: TDateTime;
  temp, hum, dew: Double;
  delta, minDelta: Int64;
begin
  Result := '';
  SetLength(AData, 0);
  FillChar(AInfo, SizeOf(AInfo), 0);
  AInfo.ModelName := 'EL-USB-2';
  if not FileExists(AFileName) then
    Exit('No existe el fichero: ' + AFileName);
  sl := TStringList.Create;
  try
    try
      sl.LoadFromFile(AFileName);
    except
      on E: Exception do
        Exit('No se pudo leer el fichero: ' + E.Message);
    end;
    if sl.Count < 2 then
      Exit('El CSV no tiene datos.');
    AInfo.UnitC := Pos('°C', FieldAt(sl[0], 3)) > 0;
    AInfo.Serial := FieldAt(sl[1], 6);
    AInfo.Name := ChangeFileExt(ExtractFileName(AFileName), '');
    minDelta := MaxInt;
    prevT := 0;
    idx := 0;
    SetLength(AData, sl.Count - 1);
    for i := 1 to sl.Count - 1 do
    begin
      line := Trim(sl[i]);
      if line = '' then Continue;
      if not TryStrToDateTime(FieldAt(line, 2), dt) then Continue;
      if not TryStrToFloat(FieldAt(line, 3), temp) then Continue;
      if not TryStrToFloat(FieldAt(line, 4), hum) then Continue;
      s := FieldAt(line, 5);
      if (s = '') or not TryStrToFloat(s, dew) then
        dew := NaN;
      if prevT <> 0 then
      begin
        delta := Round((dt - prevT) * SecsPerDay);
        if (delta > 0) and (delta < minDelta) then
          minDelta := delta;
      end;
      prevT := dt;
      AData[idx].T := dt;
      AData[idx].Temp := temp;
      AData[idx].Hum := hum;
      AData[idx].Dew := dew;
      Inc(idx);
    end;
    SetLength(AData, idx);
    if idx = 0 then
      Exit('No se encontraron filas de datos válidas en el CSV.');
    AInfo.SampleCount := idx;
    AInfo.FirstRec := AData[0].T;
    AInfo.Start := AData[0].T;
    if minDelta = MaxInt then
      AInfo.Interval := 0
    else
      AInfo.Interval := minDelta;
  finally
    sl.Free;
  end;
end;

{ Rellena la rejilla con las muestras y activa CSV/Gráfica. }
procedure TfrmMain.ShowSamples(const AData: TSampleArray; const AMsg: string);
var
  i: Integer;
begin
  grid.RowCount := Length(AData) + 1;
  for i := 0 to High(AData) do
  begin
    grid.Cells[0, i + 1] := IntToStr(i + 1);
    grid.Cells[1, i + 1] := FormatDateTime('dd/mm/yyyy hh:nn:ss', AData[i].T);
    grid.Cells[2, i + 1] := FormatFloat('0.0', AData[i].Temp);
    grid.Cells[3, i + 1] := FormatFloat('0', AData[i].Hum);
    grid.Cells[4, i + 1] := FormatFloat('0.0', AData[i].Dew);
  end;
  UpdateDataInfo;
  btnSaveCSV.Enabled := Length(AData) > 0;
  btnChart.Enabled := Length(AData) > 0;
  Log(memoData, AMsg);
end;

{ Entrada común para el botón Cargar CSV (diálogo aparte). Pública para poder
  invocarla en pruebas sin dispositivo. }
procedure TfrmMain.ImportCSVFile(const AFileName: string);
var
  AData: TSampleArray;
  AInfo: TDeviceInfo;
  err: string;
begin
  err := LoadSamplesFromCSV(AFileName, AData, AInfo);
  if err <> '' then
  begin
    Log(memoData, 'ERROR: ' + err);
    Exit;
  end;
  FData := AData;
  FInfo := AInfo;
  FHasInfo := True;
  ShowSamples(FData, Format('Importadas %d lecturas de %s (modo prueba, sin dispositivo).',
    [Length(FData), ExtractFileName(AFileName)]));
end;

{ ---------------------------------------------------------------- eventos }

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  DefaultFormatSettings.DateSeparator := '/';
  DefaultFormatSettings.ShortDateFormat := 'dd/mm/yyyy';
  DefaultFormatSettings.TimeSeparator := ':';
  DefaultFormatSettings.ShortTimeFormat := 'hh:nn:ss';
  DefaultFormatSettings.DecimalSeparator := '.';
  FHasInfo := False;
  btnSaveCSV.Enabled := False;
  btnChart.Enabled := False;
  grid.Cells[0, 0] := 'N';
  grid.Cells[1, 0] := 'Fecha Hora';
  grid.Cells[2, 0] := 'Temp.';
  grid.Cells[3, 0] := 'HR %rh';
  grid.Cells[4, 0] := 'Rocío °C';
//  grid.Cells[5, 0] := 'Serie';
  grid.ColWidths[0] := 47;
  grid.ColWidths[1] := 167;
  grid.ColWidths[2] := 77;
  grid.ColWidths[3] := 77;
  grid.ColWidths[4] := 77;
//  grid.ColWidths[5] := 110;
  grid.OnPrepareCanvas := @gridPrepareCanvas;
end;

procedure TfrmMain.btnReadConfigClick(Sender: TObject);
var
  dev: Pointer;
  cfg: TBytes;
begin
  if not OpenDevice(dev) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      if not ElusbReadConfig(dev, cfg) then
      begin
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
        Exit;
      end;
      FInfo := ElusbParseConfig(cfg);
      FHasInfo := True;
      UpdateConfigUI;
      Log(memoCfg, 'Configuración leída: ' + FInfo.ModelName + ' (serie ' + FInfo.Serial + ')');
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
  end;
end;

procedure TfrmMain.btnSaveConfigClick(Sender: TObject);
var
  dev: Pointer;
  cfg: TBytes;
begin
  if not OpenDevice(dev) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      if not ElusbReadConfig(dev, cfg) then
      begin
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
        Exit;
      end;
      if FInfo.Logging then
        Log(memoCfg, 'AVISO: el logger está GRABANDO; guardar puede afectar a la grabación.');
      try
        ApplyUItoConfig(cfg);
      except
        on E: Exception do
        begin
          Log(memoCfg, 'ERROR: ' + E.Message);
          Exit;
        end;
      end;
      if ElusbSaveConfig(dev, cfg) then
      begin
        Log(memoCfg, 'Configuración guardada OK.');
        if ElusbReadConfig(dev, cfg) then
        begin
          FInfo := ElusbParseConfig(cfg);
          FHasInfo := True;
          UpdateConfigUI;
        end;
      end
      else
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
  end;
end;

procedure TfrmMain.btnNowClick(Sender: TObject);
begin
  edStart.Text := FormatDateTime('dd/mm/yyyy hh:nn:ss', Now);
end;

procedure TfrmMain.btnStartClick(Sender: TObject);
var
  dev: Pointer;
  cfg: TBytes;
begin
  if not OpenDevice(dev) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      if not ElusbReadConfig(dev, cfg) then
      begin
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
        Exit;
      end;
      cfg[$21] := cfg[$21] or $01;          // bit de grabación ON
      cfg[$18] := 0; cfg[$19] := 0; cfg[$1A] := 0; cfg[$1B] := 0;  // inicio inmediato
      if ElusbSaveConfig(dev, cfg) then
      begin
        Log(memoCfg, 'Grabación INICIADA (inicio inmediato).');
        if ElusbReadConfig(dev, cfg) then
        begin
          FInfo := ElusbParseConfig(cfg);
          FHasInfo := True;
          UpdateConfigUI;
        end;
      end
      else
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
  end;
end;

procedure TfrmMain.btnStopClick(Sender: TObject);
var
  dev: Pointer;
  cfg: TBytes;
begin
  if not OpenDevice(dev) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      if not ElusbReadConfig(dev, cfg) then
      begin
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
        Exit;
      end;
      cfg[$21] := cfg[$21] and not $01;     // bit de grabación OFF
      if ElusbSaveConfig(dev, cfg) then
      begin
        Log(memoCfg, 'Grabación DETENIDA.');
        if ElusbReadConfig(dev, cfg) then
        begin
          FInfo := ElusbParseConfig(cfg);
          FHasInfo := True;
          UpdateConfigUI;
        end;
      end
      else
        Log(memoCfg, 'ERROR: ' + ElusbLastError);
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
  end;
end;

procedure TfrmMain.btnChartClick(Sender: TObject);
var
  f: TfrmChart;
begin
  if Length(FData) = 0 then
  begin
    Log(memoData, 'No hay datos que graficar: pulsa primero Descargar datos.');
    Exit;
  end;
  f := TfrmChart.Create(Application);
  try
    f.LoadData(FData, FInfo);
    f.ShowModal;
  finally
    f.Free;
  end;
end;

procedure TfrmMain.btnDownloadClick(Sender: TObject);
var
  dev: Pointer;
  cfg, data: TBytes;
begin
  if not OpenDevice(dev) then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      if not ElusbReadConfig(dev, cfg) then
      begin
        Log(memoData, 'ERROR: ' + ElusbLastError);
        Exit;
      end;
      FInfo := ElusbParseConfig(cfg);
      FHasInfo := True;
      if not ElusbReadData(dev, FInfo.SampleCount, data) then
      begin
        Log(memoData, 'ERROR descargando: ' + ElusbLastError);
        Exit;
      end;
      FData := ElusbParseSamples(data, FInfo);
      ShowSamples(FData, Format('Descargadas %d lecturas (%s, serie %s).',
        [Length(FData), FInfo.ModelName, FInfo.Serial]));
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
  end;
end;

procedure TfrmMain.btnLoadCSVClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(nil);
  try
    dlg.Title := 'Cargar CSV de una descarga anterior (modo prueba sin dispositivo)';
    dlg.Filter := 'CSV (*.csv)|*.csv|Todos los archivos|*.*';
    dlg.Options := dlg.Options + [ofFileMustExist];
    if not dlg.Execute then Exit;
    ImportCSVFile(dlg.FileName);
  finally
    dlg.Free;
  end;
end;

procedure TfrmMain.btnSaveCSVClick(Sender: TObject);
var
  sl: TStringList;
  i: Integer;
  unitText: string;
begin
  if Length(FData) = 0 then Exit;
  dlgSave.FileName := Format('elusb2_%s.csv', [FormatDateTime('yyyymmdd_hhnnss', Now)]);
  if not dlgSave.Execute then Exit;
  if FInfo.UnitC then
    unitText := 'Temperatura(°C)'
  else
    unitText := 'Temperatura(°F)';
  sl := TStringList.Create;
  try
    sl.Add('N;FechaHora;' + unitText + ';Humedad(%rh);PuntoRocio(°C);Serie');
    for i := 0 to High(FData) do
      sl.Add(Format('%d;%s;%s;%s;%s;%s',
        [i + 1,
         FormatDateTime('dd/mm/yyyy hh:nn:ss', FData[i].T),
         FormatFloat('0.0', FData[i].Temp),
         FormatFloat('0', FData[i].Hum),
         FormatFloat('0.0', FData[i].Dew),
         FInfo.Serial]));
    sl.SaveToFile(dlgSave.FileName);
  finally
    sl.Free;
  end;
  Log(memoData, 'CSV guardado: ' + dlgSave.FileName);
end;

end.
