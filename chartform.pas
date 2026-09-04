unit chartform;

{ chartform.pas — Formulario de la gráfica de datos del Lascar EL-USB-2.

  FORM EDITABLE EN LA IDE: la definición visual está en chartform.lfm
  (TChart con 3 series, ejes izquierdo/derecho con TAutoScaleAxisTransform
  para escala independiente, y eje X de fecha/hora). Aquí solo queda el
  código de comportamiento:
    - FormCreate: refuerza el back-reference de las transformaciones.
    - ChartDrawLegend: dibuja debajo de la leyenda la caja de máx/mín con
      el mismo estilo (marco y fondo de la leyenda).
    - LoadData: carga datos, ajusta rangos (mín-10 / máx+12 por eje) y
      títulos. Se abre con ShowModal desde el form principal. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls,
  TAGraph, TASeries, TAChartAxis, TAChartAxisUtils, TAIntervalSources,
  TATransformations, TALegend, TADrawUtils, TATools, TAGeometry, TAChartUtils,
  TACustomSource,
  elusb2_usb;

type

  { TfrmChart }

  TfrmChart = class(TForm)
    Chart1: TChart;
    pnlTop: TPanel;
    btnSaveImage: TButton;
    ChartAxisTransformations1: TChartAxisTransformations;
    AutoScaleAxisTransform1: TAutoScaleAxisTransform;
    ChartAxisTransformations2: TChartAxisTransformations;
    AutoScaleAxisTransform2: TAutoScaleAxisTransform;
    DateTimeIntervalChartSource1: TDateTimeIntervalChartSource;
    SeriesTemp: TLineSeries;
    SeriesHum: TLineSeries;
    SeriesDew: TLineSeries;
    ChartToolset1: TChartToolset;
    ChartToolset1ZoomDragTool1: TZoomDragTool;
    ChartToolset1PanDragTool1: TPanDragTool;
    Timer1: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure btnSaveImageClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure ChartDrawLegend(ASender: TChart; ADrawer: IChartDrawer;
      ALegendItems: TChartLegendItems; ALegendItemSize: TPoint;
      const ALegendRect: TRect; AColCount, ARowCount: Integer);
    procedure ChartAfterPaint(ASender: TChart);
    procedure ChartMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure ChartMouseLeave(Sender: TObject);
  private
    FStatsText: array of string;
    FStatsColor: array of TColor;
    FData: TSampleArray;
    FUnitTxt: string;
    FSnapIdx: Integer;   { índice de la muestra bajo el cursor; -1 = ninguna }
    FHint: THintWindow;  { popup con los valores }
    procedure ApplyXAxisLabelLimit;
  public
    procedure LoadData(const AData: TSampleArray; const AInfo: TDeviceInfo);
  end;

implementation

{$R *.lfm}

procedure TfrmChart.FormCreate(Sender: TObject);
begin
  FSnapIdx := -1;
  { El hint se crea UNA vez y se oculta con Hide: liberarlo con FreeAndNil
    mientras el LCL lo sigue como control bajo el ratón (Application.
    FMouseControl) provoca un EAccessViolation en el siguiente movimiento
    (UpdateMouseControl -> Perform sobre el objeto liberado). }
  FHint := THintWindow.Create(nil);
  { El streaming del .lfm ya enlaza los transforms a sus transformaciones;
    este back-reference es a prueba de balas (SetTransformations es no-op
    si ya está asignado). Sin él, la List de TChartAxisTransformations
    quedaría vacía y los ejes volverían a compartir escala (unión de
    rangos). }
  AutoScaleAxisTransform1.Transformations := ChartAxisTransformations1;
  AutoScaleAxisTransform2.Transformations := ChartAxisTransformations2;
  { El eje X no debe mostrar más de 15 etiquetas (ver ApplyXAxisLabelLimit). }
  ApplyXAxisLabelLimit;
end;

{ El generador de marcas del eje X (DateTimeIntervalChartSource1) elige el
  paso de las etiquetas con dos parámetros: Count (número deseado) y las
  restricciones en píxeles MinLength/MaxLength. El tope DURO está en
  MinLength: distancia mínima en px entre etiquetas; como el eje admite
  anchura/MinLength etiquetas como mucho, MinLength = anchura/15 + 1 px
  garantiza que nunca se dibujen más de 15 (sea cual sea el zoom y aunque
  se agrande la ventana, porque se recalcula en OnResize). Con Count = 15
  el generador elige el paso "redondo" más cercano a 15 etiquetas. }
procedure TfrmChart.ApplyXAxisLabelLimit;
begin
  with DateTimeIntervalChartSource1.Params do
  begin
    Count := 15;
    Options := [aipUseCount, aipUseMinLength, aipUseNiceSteps];
    MinLength := Chart1.Width div 15 + 1;
  end;
end;

procedure TfrmChart.FormResize(Sender: TObject);
begin
  { Al redimensionar cambia la anchura del eje -> recalcular el tope de px. }
  ApplyXAxisLabelLimit;
end;

procedure TfrmChart.Timer1Timer(Sender: TObject);
var
  rc: TRect;
  p: TPoint;
begin
  { Si el cursor sale del área del gráfico, ocultar el popup (el OnMouseLeave
    de GTK2 no siempre se recibe con la ventana del hint encima). }
  if FSnapIdx < 0 then Exit;
  rc := Chart1.ClientRect;
  rc.TopLeft := Chart1.ClientToScreen(rc.TopLeft);
  rc.BottomRight := Chart1.ClientToScreen(rc.BottomRight);
  p := Mouse.CursorPos;
  if (p.X < rc.Left) or (p.X > rc.Right) or
     (p.Y < rc.Top) or (p.Y > rc.Bottom) then
  begin
    FSnapIdx := -1;
    if FHint <> nil then
      FHint.Hide;
    Chart1.Invalidate;
  end;
end;

procedure TfrmChart.FormDestroy(Sender: TObject);
begin
  FHint.Free;
  FHint := nil;
end;

{ Guarda la gráfica como imagen PNG (lo que se ve en pantalla, sin la línea
  del cursor). Usa el pintado del propio TChart sobre un lienzo PNG. }
procedure TfrmChart.btnSaveImageClick(Sender: TObject);
var
  dlg: TSaveDialog;
  png: TPortableNetworkGraphic;
  prevIdx: Integer;
begin
  if Length(FData) = 0 then Exit;
  dlg := TSaveDialog.Create(nil);
  try
    dlg.Title := 'Guardar gráfica como imagen';
    dlg.Filter := 'Imagen PNG (*.png)|*.png';
    dlg.DefaultExt := '.png';
    dlg.Options := dlg.Options + [ofOverwritePrompt];
    dlg.FileName := Format('elusb2_%s.png', [FormatDateTime('yyyymmdd_hhnnss', Now)]);
    if not dlg.Execute then Exit;
    png := TPortableNetworkGraphic.Create;
    try
      png.Width := Chart1.Width;
      png.Height := Chart1.Height;
      prevIdx := FSnapIdx;
      FSnapIdx := -1;      { la imagen sale sin la línea del cursor }
      try
        Chart1.PaintOnCanvas(png.Canvas, Rect(0, 0, png.Width, png.Height));
      finally
        FSnapIdx := prevIdx;
      end;
      Chart1.Invalidate;
      png.SaveToFile(dlg.FileName);
    finally
      png.Free;
    end;
  finally
    dlg.Free;
  end;
end;

procedure TfrmChart.LoadData(const AData: TSampleArray; const AInfo: TDeviceInfo);
var
  i: Integer;
  unitTxt: string;
  minT, maxT, minH, maxH, minD, maxD: Double;
  leftMin, leftMax, rightMin, rightMax: Integer;
begin
  FData := AData;
  FSnapIdx := -1;
  SeriesTemp.Clear;
  SeriesHum.Clear;
  SeriesDew.Clear;
  if Length(AData) = 0 then Exit;
  for i := 0 to High(AData) do
  begin
    SeriesTemp.AddXY(AData[i].T, AData[i].Temp);
    SeriesHum.AddXY(AData[i].T, AData[i].Hum);
    SeriesDew.AddXY(AData[i].T, AData[i].Dew);
  end;

  { Escala ajustada a los datos: mínimo - 10, máximo + 10, por eje.
    Izquierdo: temperatura + punto de rocío. Derecho: humedad. }
  minT := AData[0].Temp; maxT := AData[0].Temp;
  minH := AData[0].Hum;  maxH := AData[0].Hum;
  minD := AData[0].Dew;  maxD := AData[0].Dew;
  for i := 1 to High(AData) do
  begin
    minT := Min(minT, AData[i].Temp); maxT := Max(maxT, AData[i].Temp);
    minH := Min(minH, AData[i].Hum);  maxH := Max(maxH, AData[i].Hum);
    minD := Min(minD, AData[i].Dew);  maxD := Max(maxD, AData[i].Dew);
  end;

  leftMin := round(Min(minT, minD)) - 10;
  if (leftMin mod 5) > 2.5 then
    leftMin := leftMin - (leftMin mod 5)
  else
    leftMin := leftMin + (leftMin mod 5);

  leftMax := round(Max(maxT, maxD)) + 10;
  if (leftMax mod 5) > 2.5 then
    leftMax := leftMax + 5 - (leftMax mod 5)
  else
    leftMax := leftMax - (leftMax mod 5);

  rightMin := round(minH) - 10;
  if (rightMin mod 5) > 2.5 then
    rightMin := rightMin - (rightMin mod 5)
  else
    rightMin := rightMin + (rightMin mod 5);

  rightMax := round(maxH) + 10;
  if (rightMax mod 5) > 2.5 then
    rightMax := rightMax + 5 - (rightMax mod 5)
  else
    rightMax := rightMax - (rightMax mod 5);

  with Chart1.LeftAxis.Range do
  begin
    UseMin := True; Min := leftMin;
    UseMax := True; Max := leftMax;
  end;
  with Chart1.AxisList[SeriesHum.AxisIndexY].Range do
  begin
    UseMin := True; Min := rightMin;
    UseMax := True; Max := rightMax;
  end;

  if AInfo.UnitC then
    unitTxt := '°C'
  else
    unitTxt := '°F';
  FUnitTxt := unitTxt;
  SeriesTemp.Title := 'Temperatura (' + unitTxt + ')';
  Chart1.LeftAxis.Title.Caption := 'Temperatura (' + unitTxt + ') / Rocío (°C)';
  Chart1.Title.Text.Clear;
  Chart1.Title.Text.Add(Format('Datos del Lascar EL-USB-2 — %d lecturas (serie %s)',
    [Length(AData), AInfo.Serial]));

  { Datos para la caja de máx/mín bajo la leyenda (se dibuja en
    ChartDrawLegend, con el mismo estilo que la leyenda) }
  SetLength(FStatsText, 4);
  SetLength(FStatsColor, 4);
  FStatsText[0] := Format('T. Máx: %s %s', [FormatFloat('0.0', maxT), unitTxt]);
  FStatsText[1] := Format('T. Mín: %s %s', [FormatFloat('0.0', minT), unitTxt]);
  FStatsText[2] := Format('HR Máx: %s %%', [FormatFloat('0', maxH)]);
  FStatsText[3] := Format('HR Mín: %s %%', [FormatFloat('0', minH)]);
  FStatsColor[0] := clRed;
  FStatsColor[1] := clRed;
  FStatsColor[2] := clBlue;
  FStatsColor[3] := clBlue;
end;

procedure TfrmChart.ChartDrawLegend(ASender: TChart; ADrawer: IChartDrawer;
  ALegendItems: TChartLegendItems; ALegendItemSize: TPoint;
  const ALegendRect: TRect; AColCount, ARowCount: Integer);
var
  ldd: TChartLegendDrawingData;
  r: TRect;
  i, y, lineH, symW, padX, padY, gap, maxW: Integer;
  ts: TPoint;
begin
  { Leyenda normal }
  ldd.FBounds := ALegendRect;
  ldd.FColCount := AColCount;
  ldd.FDrawer := ADrawer;
  ldd.FItems := ALegendItems;
  ldd.FItemSize := ALegendItemSize;
  ldd.FRowCount := ARowCount;
  Chart1.Legend.Draw(ldd);

  if Length(FStatsText) = 0 then Exit;

  { Caja de estadísticas DEBAJO de la leyenda, con el mismo estilo
    (marco y fondo de la leyenda) }
  ADrawer.Font := Chart1.Legend.Font;
  ts := ADrawer.TextExtent(FStatsText[0]);
  lineH := ts.Y;
  padX := Chart1.Legend.MarginX;
  padY := Chart1.Legend.MarginY;
  symW := 14;
  gap := 3;
  maxW := 0;
  for i := 0 to High(FStatsText) do
  begin
    ts := ADrawer.TextExtent(FStatsText[i]);
    if ts.X > maxW then maxW := ts.X;
  end;
  r := ALegendRect;
  r.Top := r.Bottom + 4;
  r.Bottom := r.Top + 2 * padY + Length(FStatsText) * lineH
              + (Length(FStatsText) - 1) * gap;
  if r.Right - r.Left < padX + symW + 4 + maxW + padX then
    r.Right := r.Left + padX + symW + 4 + maxW + padX;
  ADrawer.Pen := Chart1.Legend.Frame;
  { Fondo y borde EXPLÍCITOS: Legend.BackgroundBrush trae clDefault y al
    exportar a PNG (TFPCanvas) clDefault se rasteriza como NEGRO (en pantalla
    el widgetset lo resuelve y no se nota). La leyenda oficial resuelve
    clDefault con GetDefaultColor; aquí usamos colores fijos equivalentes. }
  if Chart1.Legend.Frame.Color = clDefault then
    ADrawer.SetPenColor(clSilver)
  else
    ADrawer.SetPenColor(Chart1.Legend.Frame.Color);
  ADrawer.SetBrushParams(bsSolid, clWhite);
  ADrawer.Rectangle(r);

  { Líneas con marcador del color de cada serie }
  y := r.Top + padY;
  for i := 0 to High(FStatsText) do
  begin
    ADrawer.SetPenColor(FStatsColor[i]);
    ADrawer.Line(r.Left + padX, y + lineH div 2,
                 r.Left + padX + symW, y + lineH div 2);
    ADrawer.TextOut.Pos(r.Left + padX + symW + 4, y)
      .Text(FStatsText[i]).Done;
    Inc(y, lineH + gap);
  end;
end;

{ ---------- cursor con valores ---------- }

procedure TfrmChart.ChartMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  gp: TDoublePoint;
  pt, r: TRect;
  sp: TPoint;
  i: Integer;
  d, best: Double;
  h: String;
begin
  if Length(FData) = 0 then Exit;
  gp := Chart1.ImageToGraph(Point(X, Y));
  { muestra más cercana al tiempo del cursor }
  best := 1e300;
  FSnapIdx := -1;
  for i := 0 to High(FData) do
  begin
    d := Abs(FData[i].T - gp.X);
    if d < best then
    begin
      best := d;
      FSnapIdx := i;
    end;
  end;
  if FSnapIdx < 0 then Exit;
  { popup con los valores de la muestra, junto al cursor }
  h := FormatDateTime('dd/mm/yyyy hh:nn', FData[FSnapIdx].T) + #13#10 +
       Format('T: %.1f %s', [FData[FSnapIdx].Temp, FUnitTxt]) + #13#10 +
       Format('H: %.0f %%', [FData[FSnapIdx].Hum]) + #13#10 +
       Format('D: %.1f °C', [FData[FSnapIdx].Dew]);
  if FHint = nil then
    FHint := THintWindow.Create(nil);
  pt := FHint.CalcHintRect(200, h, nil);
  sp := Chart1.ClientToScreen(Point(X, Y));
  r.Left := sp.X + 14;
  r.Top := sp.Y + 14;
  r.Right := r.Left + (pt.Right - pt.Left);
  r.Bottom := r.Top + (pt.Bottom - pt.Top);
  FHint.ActivateHint(r, h);
  Chart1.Invalidate;
end;

procedure TfrmChart.ChartMouseLeave(Sender: TObject);
begin
  FSnapIdx := -1;
  if FHint <> nil then
    FHint.Hide;
  Chart1.Invalidate;
end;

procedure TfrmChart.ChartAfterPaint(ASender: TChart);
var
  ext: TDoubleRect;
  cv: TCanvas;
  p: TPoint;
  sx: Integer;
begin
  if FSnapIdx < 0 then Exit;
  ext := ASender.CurrentExtent;
  cv := ASender.Canvas;
  cv.Pen.Style := psDash;
  cv.Pen.Color := $606060;
  cv.Pen.Width := 1;
  { solo línea vertical en la X de la muestra bajo el cursor }
  p := ASender.GraphToImage(DoublePoint(FData[FSnapIdx].T, 0));
  sx := p.X;
  p := ASender.GraphToImage(DoublePoint(0, ext.b.Y));
  cv.MoveTo(sx, p.Y);
  p := ASender.GraphToImage(DoublePoint(0, ext.a.Y));
  cv.LineTo(sx, p.Y);
end;

end.
