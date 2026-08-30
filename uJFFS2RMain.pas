unit uJFFS2RMain;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Memo.Types,
  FMX.ScrollBox, FMX.Memo, FMX.Controls.Presentation, FMX.StdCtrls
, FS.JFFS2Reader
, System.ZLib
, System.StrUtils, FMX.Layouts, FMX.TreeView
, System.IOUtils, FMX.Objects, FMX.Menus
  ;


type

  TForm1 = class(TForm)
    btnOpenFile: TButton;
    memoContent: TMemo;
    openDialog: TOpenDialog;
    tvFiles: TTreeView;
    Layout1: TLayout;
    saveDialog: TSaveDialog;
    btnExtractClick: TButton;
    Splitter1: TSplitter;
    StatusBar1: TStatusBar;
    ProgressBar: TProgressBar;
    lbStatus: TLabel;
    Layout2: TLayout;
    ImagePreview: TImage;
    PopupMenu: TPopupMenu;
    miSaveFile: TMenuItem;
    miSaveFileWithPath: TMenuItem;
    procedure FormDestroy(Sender: TObject);
    procedure btnExtractClickClick(Sender: TObject);
    procedure btnOpenFileClick(Sender: TObject);
    procedure tvFilesChange(Sender: TObject);
  private
    Parser: TJFFS2Parser;
    FImagePreview: TImage; // создаётся динамически, в .fmx не заведён
    procedure PopulateTreeView;
    function BuildPropsText(const DisplayPath: string; const Props: TFSItemProps): string;
    procedure EnsureImagePreview;
    procedure ShowImagePreview(const Data: TBytes);
    procedure HideImagePreview;
    function IsImageContent(const Data: TBytes): Boolean;
  public
    { Public declarations }
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

function ToNativePath(const P: string): string;
begin
  // Пути из образа JFFS2 всегда используют '/', на диске нужен PathDelim.
  Result := StringReplace(P, '/', PathDelim, [rfReplaceAll]);
end;

function LastPathSegment(const P: string): string;
var
  Idx: Integer;
begin
  Idx := P.LastIndexOf('/');
  if Idx >= 0 then
    Result := Copy(P, Idx + 2, MaxInt)
  else
    Result := P;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if Assigned(Parser) then
    Parser.Free;
end;

procedure TForm1.btnExtractClickClick(Sender: TObject);
var
  SelectedNode: TTreeViewItem;
  Props: TFSItemProps;
  OutRoot, TargetPath: string;
  KeepPath: Boolean;
begin
  if tvFiles.Selected = nil then
  begin
    ShowMessage('Сначала выберите файл или папку в дереве.');
    Exit;
  end;

  SelectedNode := tvFiles.Selected;
  if SelectedNode.TagString = '' then
  begin
    ShowMessage('Выбранный элемент нельзя извлечь.');
    Exit;
  end;

  Props := Parser.GetItemProps(SelectedNode.TagString);
  if not Props.Found then
  begin
    ShowMessage('Элемент не найден в образе.');
    Exit;
  end;

  // Всегда выбираем КОРНЕВУЮ папку на диске — путь из образа строится
  // внутри неё. Явно задаём стартовую директорию, иначе диалог браузера
  // папок иногда ругается "данный каталог не существует".
  OutRoot := GetCurrentDir;
  if not SelectDirectory('Выберите папку для сохранения', GetCurrentDir, OutRoot) then
    Exit;

  if Props.IsDirectory then
  begin
    // Для папки всегда воссоздаём полный путь от корня образа внутри OutRoot.
    TargetPath := System.IOUtils.TPath.Combine(OutRoot, ToNativePath(SelectedNode.TagString));
    try
      Parser.ExtractFolder(SelectedNode.TagString, TargetPath);
      ShowMessage('Папка успешно извлечена в: ' + TargetPath);
    except
      on E: Exception do
        ShowMessage('Ошибка извлечения папки: ' + E.Message);
    end;
  end
  else
  begin
    KeepPath := MessageDlg(
      'Сохранить с воссозданием пути внутри выбранной папки?' + sLineBreak +
      '«Да» — будет создана структура: ' + ExtractFilePath(ToNativePath(SelectedNode.TagString)) + sLineBreak +
      '«Нет» — файл будет сохранён прямо в выбранную папку, без пути.',
      TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo], 0) = mrYes;

    if KeepPath then
      TargetPath := System.IOUtils.TPath.Combine(OutRoot, ToNativePath(SelectedNode.TagString))
    else
      TargetPath := System.IOUtils.TPath.Combine(OutRoot, LastPathSegment(SelectedNode.TagString));

    try
      Parser.ExtractFile(SelectedNode.TagString, TargetPath);
      ShowMessage('Файл успешно сохранён: ' + TargetPath);
    except
      on E: Exception do
        ShowMessage('Ошибка извлечения: ' + E.Message);
    end;
  end;
end;

procedure TForm1.btnOpenFileClick(Sender: TObject);
begin
  openDialog.Filter := 'Файлы прошивок (*.bin;*.jffs2)|*.bin;*.jffs2|Все файлы (*.*)|*.*';
  if openDialog.Execute then
  begin
    if Assigned(Parser) then
      FreeAndNil(Parser);

    try
      Parser := TJFFS2Parser.Create(openDialog.FileName);
      PopulateTreeView;
      memoContent.Lines.Clear;
      memoContent.Lines.Add('Файл успешно открыт: ' + ExtractFileName(openDialog.FileName));
      memoContent.Lines.Add('Выберите элемент в дереве слева для просмотра содержимого.');
    except
      on E: Exception do
        ShowMessage('Ошибка открытия файла: ' + E.Message);
    end;
  end;

end;

procedure TForm1.PopulateTreeView;
var
  FileList: TArray<string>;
  S: string;
  Parts: TArray<string>;
  I, J: Integer;
  ParentNode, CurrentNode: TTreeViewItem;
  NodeName: string;
  Found: Boolean;
begin
  tvFiles.BeginUpdate;
  try
    tvFiles.Clear;
    FileList := Parser.GetFileList;

    for S in FileList do
    begin
      Parts := S.Split(['/']);
      ParentNode := nil;

      for I := 0 to Length(Parts) - 1 do
      begin
        NodeName := Parts[I];
        Found := False;
        CurrentNode := nil;

        if ParentNode = nil then
        begin
          for J := 0 to tvFiles.Count - 1 do
            if tvFiles.Items[J].Text = NodeName then
            begin
              CurrentNode := tvFiles.Items[J];
              Found := True;
              Break;
            end;
        end
        else
        begin
          for J := 0 to ParentNode.Count - 1 do
            if ParentNode.Items[J].Text = NodeName then
            begin
              CurrentNode := ParentNode.Items[J];
              Found := True;
              Break;
            end;
        end;

        if not Found then
        begin
          CurrentNode := TTreeViewItem.Create(tvFiles);
          CurrentNode.Text := NodeName;
          // Сохраняем ПОЛНЫЙ путь — он понадобится для извлечения данных
          CurrentNode.TagString := S;

          if ParentNode = nil then
            tvFiles.AddObject(CurrentNode)
          else
            ParentNode.AddObject(CurrentNode);
        end;

        ParentNode := CurrentNode;
      end;
    end;
  finally
    tvFiles.EndUpdate;
  end;
end;
function TForm1.BuildPropsText(const DisplayPath: string; const Props: TFSItemProps): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('Путь: ' + DisplayPath);
    Lines.Add('Inode: ' + Props.Ino.ToString + '   Родитель: ' + Props.Pino.ToString);
    if Props.IsDirectory then
    begin
      Lines.Add('Тип: каталог');
      Lines.Add('Элементов внутри: ' + Props.ChildCount.ToString);
      Lines.Add('');
      Lines.Add('Чтобы сохранить каталог целиком, используйте кнопку «Извлечь».');
    end
    else
    begin
      Lines.Add('Тип: файл');
      Lines.Add('Размер: ' + Props.Size.ToString + ' байт');
      Lines.Add('Фрагментов данных: ' + Props.FragmentCount.ToString);
      Lines.Add('Сжатие: ' + Props.Compression);
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

procedure TForm1.EnsureImagePreview;
begin
  if Assigned(FImagePreview) then Exit;

  // Компонент не заведён в .fmx — создаём runtime-копию поверх memoContent,
  // с теми же положением/размером/выравниванием, и просто прячем/показываем нужный.
  FImagePreview := TImage.Create(Self);
  FImagePreview.Parent := memoContent.Parent;
  FImagePreview.Align := memoContent.Align;
  FImagePreview.Position.Point := memoContent.Position.Point;
  FImagePreview.Size.Size := memoContent.Size.Size;
  FImagePreview.WrapMode := TImageWrapMode.Fit; // вписываем с сохранением пропорций
  FImagePreview.Visible := False;
end;

procedure TForm1.ShowImagePreview(const Data: TBytes);
var
  MS: TMemoryStream;
begin
  EnsureImagePreview;
  MS := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      MS.WriteBuffer(Data[0], Length(Data));
    MS.Position := 0;
    try
      FImagePreview.Bitmap.LoadFromStream(MS);
      memoContent.Visible := False;
      FImagePreview.Visible := True;
    except
      on E: Exception do
      begin
        HideImagePreview;
        memoContent.Lines.Add('(не удалось декодировать изображение: ' + E.Message + ')');
      end;
    end;
  finally
    MS.Free;
  end;
end;

procedure TForm1.HideImagePreview;
begin
  if Assigned(FImagePreview) then
    FImagePreview.Visible := False;
  memoContent.Visible := True;
end;

function TForm1.IsImageContent(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) >= 8 then
    if (Data[0] = $89) and (Data[1] = $50) and (Data[2] = $4E) and (Data[3] = $47) then
      Exit(True); // PNG
  if Length(Data) >= 3 then
    if (Data[0] = $FF) and (Data[1] = $D8) and (Data[2] = $FF) then
      Exit(True); // JPEG
  if Length(Data) >= 2 then
    if (Data[0] = Ord('B')) and (Data[1] = Ord('M')) then
      Exit(True); // BMP
  if Length(Data) >= 3 then
    if (Data[0] = Ord('G')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F')) then
      Exit(True); // GIF
end;

procedure TForm1.tvFilesChange(Sender: TObject);
var
  SelectedNode: TTreeViewItem;
  Props: TFSItemProps;
  Content: TBytes;
  S: string;
begin
  if tvFiles.Selected = nil then Exit;

  SelectedNode := tvFiles.Selected;
  if SelectedNode.TagString = '' then Exit;

  memoContent.Lines.Clear;
  HideImagePreview; // по умолчанию показываем memo, картинку прячем

  Props := Parser.GetItemProps(SelectedNode.TagString);
  if not Props.Found then
  begin
    memoContent.Lines.Add('(элемент не найден в образе)');
    Exit;
  end;

  // Для каталогов, пустых и «подозрительных» файлов — показываем свойства,
  // а не пытаемся впихнуть содержимое в TMemo.
  if Props.IsDirectory then
  begin
    memoContent.Lines.Text := BuildPropsText(SelectedNode.TagString, Props);
    Exit;
  end;

  if Props.Size = 0 then
  begin
    memoContent.Lines.Add('(файл пуст)');
    Exit;
  end;

  if Props.Size > MAX_TEXT_PREVIEW_SIZE then
  begin
    memoContent.Lines.Add('(файл слишком большой для предпросмотра — показаны свойства)');
    memoContent.Lines.Add('');
    memoContent.Lines.Text := memoContent.Lines.Text + BuildPropsText(SelectedNode.TagString, Props);
    Exit;
  end;

  try
    Content := Parser.ReadFileData(SelectedNode.TagString);
  except
    on E: Exception do
    begin
      memoContent.Lines.Add('(' + E.Message + ')');
      Exit;
    end;
  end;

  // Картинка — показываем в TImage вместо мемо.
  if IsImageContent(Content) then
  begin
    ShowImagePreview(Content);
    Exit;
  end;

  if not Parser.IsTextContent(Content) then
  begin
    memoContent.Lines.Add('(бинарный файл — предпросмотр недоступен, показаны свойства)');
    memoContent.Lines.Add('');
    memoContent.Lines.Text := memoContent.Lines.Text + BuildPropsText(SelectedNode.TagString, Props);
    Exit;
  end;

  // Похоже на текст — показываем содержимое.
  SetString(S, PAnsiChar(Content), Length(Content));
  S := StringReplace(S, #0, '', [rfReplaceAll]);
  memoContent.Lines.Text := S;
end;

end.
