unit main;

{ main.pas — Formulario principal de la aplicación Lascar EL-USB-2.
  Dos solapas:
    - Configuración: leer/editar/guardar parámetros del logger, iniciar/detener.
    - Lectura de datos: descargar lecturas, verlas en rejilla y guardar CSV. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Grids, Forms, Controls, Graphics, Dialogs, ComCtrls, StdCtrls,
  Spin, ExtCtrls, DateUtils, Math, LResources,
  elusb2_usb, chartform;

type

  { TfrmMain }

  TfrmMain = class(TForm)
    btnChart: TButton;
    btnDownload: TButton;
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
  public
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
  i: Integer;
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
      grid.RowCount := Length(FData) + 1;
      for i := 0 to High(FData) do
      begin
        grid.Cells[0, i + 1] := IntToStr(i + 1);
        grid.Cells[1, i + 1] := FormatDateTime('dd/mm/yyyy hh:nn:ss', FData[i].T);
        grid.Cells[2, i + 1] := FormatFloat('0.0', FData[i].Temp);
        grid.Cells[3, i + 1] := FormatFloat('0', FData[i].Hum);
        grid.Cells[4, i + 1] := FormatFloat('0.0', FData[i].Dew);
//        grid.Cells[5, i + 1] := FInfo.Serial;
      end;
      UpdateDataInfo;
      if Length(FData) > 0 then
      begin
        btnSaveCSV.Enabled := True;
        btnChart.Enabled := True;
      end;
      Log(memoData, Format('Descargadas %d lecturas (%s, serie %s).',
        [Length(FData), FInfo.ModelName, FInfo.Serial]));
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    ElusbClose(dev);
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
