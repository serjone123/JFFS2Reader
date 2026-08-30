unit uJFFS2RMain;
interface
uses
  System.SysUtils, System.Types, System.UITypes, System.Classes,
  System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Memo.Types,
  FMX.ScrollBox, FMX.Memo, FMX.Controls.Presentation, FMX.StdCtrls
, FS.JFFS2Reader
, System.ZLib
, System.StrUtils, FMX.Layouts, FMX.TreeView
, System.IOUtils, FMX.Objects, FMX.Menus
, Common.Utils
  ;

type
  TfmJFFS2Reader = class(TForm)
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
    Splitter2: TSplitter;
    StyleBook1: TStyleBook;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnExtractClickClick(Sender: TObject);
    procedure btnOpenFileClick(Sender: TObject);
    procedure PopupMenuPopup(Sender: TObject);
    procedure tvFilesChange(Sender: TObject);
  private
    Parser: TJFFS2Parser;
    procedure PopulateTreeView;
    function BuildPropsText(const DisplayPath: string;
      const Props: TFSItemProps): string;
    procedure ShowImagePreview(const Data: TBytes);
    procedure HideImagePreview;
    function IsImageContent(const Data: TBytes): Boolean;
    procedure ParserProgress(Sender: TObject; Position, Total: Int64);
    procedure SaveSelected(KeepPath: Boolean);

    procedure miSaveFileClick(Sender: TObject);
    procedure miSaveFileWithPathClick(Sender: TObject);
  public
    { Public declarations }
  end;
var
  fmJFFS2Reader: TfmJFFS2Reader;
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

procedure TfmJFFS2Reader.FormCreate(Sender: TObject);
begin
  self.Caption:= 'JFFS2Reader '+FileVersion(Paramstr(0)) ;
end;

procedure TfmJFFS2Reader.FormDestroy(Sender: TObject);
begin
  if Assigned(Parser) then
    Parser.Free;
end;
procedure TfmJFFS2Reader.SaveSelected(KeepPath: Boolean);
var
  SelectedNode: TTreeViewItem;
  Props: TFSItemProps;
  OutRoot, TargetPath: string;
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
  if not SelectDirectory('Выберите папку для сохранения', GetCurrentDir, OutRoot)
  then
    Exit;
  if KeepPath then
    TargetPath := System.IOUtils.TPath.Combine(OutRoot,
      ToNativePath(SelectedNode.TagString))
  else
    TargetPath := System.IOUtils.TPath.Combine(OutRoot,
      LastPathSegment(SelectedNode.TagString));
  try
    if Props.IsDirectory then
      Parser.ExtractFolder(SelectedNode.TagString, TargetPath)
    else
      Parser.ExtractFile(SelectedNode.TagString, TargetPath);

    // Сообщение об успехе — только в статус-лейбл, без модального окна.
    lbStatus.Text := 'Сохранено: ' + TargetPath;
  except
    on E: Exception do
      ShowMessage('Ошибка сохранения: ' + E.Message);
  end;
end;
procedure TfmJFFS2Reader.miSaveFileClick(Sender: TObject);
begin
  SaveSelected(False); // без пути — только сам файл/папка в корень
end;
procedure TfmJFFS2Reader.miSaveFileWithPathClick(Sender: TObject);
begin
  SaveSelected(True); // с воссозданием полного пути от корня образа
end;

procedure TfmJFFS2Reader.btnExtractClickClick(Sender: TObject);
var
  Props: TFSItemProps;
  KeepPath: Boolean;
begin
  if tvFiles.Selected = nil then
  begin
    ShowMessage('Сначала выберите файл или папку в дереве.');
    Exit;
  end;
  if tvFiles.Selected.TagString = '' then
  begin
    ShowMessage('Выбранный элемент нельзя извлечь.');
    Exit;
  end;
  Props := Parser.GetItemProps(tvFiles.Selected.TagString);
  if not Props.Found then
  begin
    ShowMessage('Элемент не найден в образе.');
    Exit;
  end;
  if Props.IsDirectory then
    KeepPath := True
    // для папки кнопка «Извлечь» всегда воссоздаёт путь от корня образа
  else
    KeepPath := MessageDlg(
      'Сохранить с воссозданием пути внутри выбранной папки?' + sLineBreak +
      '«Да» — будет создана структура: ' +
      ExtractFilePath(ToNativePath(tvFiles.Selected.TagString)) + sLineBreak +
      '«Нет» — файл будет сохранён прямо в выбранную папку, без пути.',
      TMsgDlgType.mtConfirmation, [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo],
      0) = mrYes;
  SaveSelected(KeepPath);
end;
procedure TfmJFFS2Reader.ParserProgress(Sender: TObject; Position, Total: Int64);
begin
  if Total > 0 then
    ProgressBar.Value := (Position / Total) * 100
  else
    ProgressBar.Value := 0;
  // Разбор синхронный и может занимать заметное время на больших образах —
  // прокачиваем очередь сообщений, чтобы прогресс-бар и статус реально перерисовывались.
  Application.ProcessMessages;
end;
procedure TfmJFFS2Reader.btnOpenFileClick(Sender: TObject);
var
  Stats: TFSStats;
begin
  openDialog.Filter :=
    'Файлы прошивок (*.bin;*.jffs2)|*.bin;*.jffs2|Все файлы (*.*)|*.*';
  if openDialog.Execute then
  begin
    if Assigned(Parser) then
      FreeAndNil(Parser);
    ProgressBar.Min := 0;
    ProgressBar.Max := 100;
    ProgressBar.Value := 0;
    lbStatus.Text := 'Открытие файла: ' + openDialog.FileName;
    Application.ProcessMessages;
    try
      Parser := TJFFS2Parser.Create(openDialog.FileName);
      // только открывает поток, без разбора
      Parser.OnProgress := ParserProgress;
      Parser.Parse; // сам разбор — здесь идёт прогресс
      PopulateTreeView;
      Stats := Parser.GetStats;
      lbStatus.Text :=
        Format('%s   |   Размер образа: %d байт   |   Файлов: %d   |   Папок: %d',
        [openDialog.FileName, Stats.ImageSize, Stats.FileCount,
        Stats.DirCount]);
      memoContent.Lines.Clear;
      memoContent.Lines.Add('Файл успешно открыт: ' +
        ExtractFileName(openDialog.FileName));
      memoContent.Lines.Add
        ('Выберите элемент в дереве слева для просмотра содержимого.');
    except
      on E: Exception do
      begin
        lbStatus.Text := 'Ошибка открытия файла: ' + E.Message;
        ShowMessage('Ошибка открытия файла: ' + E.Message);
      end;
    end;
    ProgressBar.Value := 0;
  end;
end;
procedure TfmJFFS2Reader.PopulateTreeView;
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
          // Меню сохранения — на КАЖДОМ элементе дерева, а не на всём tvFiles:
          // так правый клик мимо элементов не откроет контекстное меню.
          CurrentNode.PopupMenu := PopupMenu;
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
function TfmJFFS2Reader.BuildPropsText(const DisplayPath: string;
  const Props: TFSItemProps): string;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('Путь: ' + DisplayPath);
    Lines.Add('Inode: ' + Props.Ino.ToString + '   Родитель: ' +
      Props.Pino.ToString);
    if Props.IsDirectory then
    begin
      Lines.Add('Тип: каталог');
      Lines.Add('Элементов внутри: ' + Props.ChildCount.ToString);
      Lines.Add('');
      Lines.Add(
        'Чтобы сохранить каталог целиком, используйте кнопку «Извлечь».');
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
procedure TfmJFFS2Reader.ShowImagePreview(const Data: TBytes);
var
  MS: TMemoryStream;
begin
  MS := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      MS.WriteBuffer(Data[0], Length(Data));
    MS.Position := 0;
    try
      ImagePreview.Bitmap.LoadFromStream(MS);
      // Защита от вырожденного случая, если высота не задана в дизайнере —
      // сам компонент (Align=Bottom, WrapMode=Fit) уже настроен вами на форме.
      if ImagePreview.Height < 50 then
        ImagePreview.Height := 250;
      ImagePreview.Visible := True;
      Splitter2.Visible := True;
      Splitter2.Align:=TAlignLayout.Top;
      Splitter2.Align:=TAlignLayout.Bottom;
    except
      on E: Exception do
      begin
        ImagePreview.Visible := False;
        Splitter2.Visible := False;
        memoContent.Lines.Add('');
        memoContent.Lines.Add('(не удалось декодировать изображение: ' +
          E.Message + ')');
      end;
    end;
  finally
    MS.Free;
  end;
end;
procedure TfmJFFS2Reader.HideImagePreview;
begin
  ImagePreview.Visible := False;
  Splitter2.Visible := False;
end;
function TfmJFFS2Reader.IsImageContent(const Data: TBytes): Boolean;
begin
  Result := False;
  if Length(Data) >= 8 then
    if (Data[0] = $89) and (Data[1] = $50) and (Data[2] = $4E) and
      (Data[3] = $47) then
      Exit(True); // PNG
  if Length(Data) >= 3 then
    if (Data[0] = $FF) and (Data[1] = $D8) and (Data[2] = $FF) then
      Exit(True); // JPEG
  if Length(Data) >= 2 then
    if (Data[0] = Ord('B')) and (Data[1] = Ord('M')) then
      Exit(True); // BMP
  if Length(Data) >= 3 then
    if (Data[0] = Ord('G')) and (Data[1] = Ord('I')) and (Data[2] = Ord('F'))
    then
      Exit(True); // GIF
  if Length(Data) >= 4 then
    if (Data[0] = 0) and (Data[1] = 0) and ((Data[2] = 1) or (Data[2] = 2)) and
      (Data[3] = 0) then
      Exit(True);
  // ICO (type=1) / CUR (type=2) — именно в таком формате favicon.ico
end;

procedure TfmJFFS2Reader.PopupMenuPopup(Sender: TObject);
begin
  // Меню теперь навешено на КАЖДЫЙ TTreeViewItem (см. PopulateTreeView),
  // а не на весь tvFiles целиком — поэтому оно физически не может
  // раскрыться при клике мимо элементов. Здесь только подхватываем,
  // какой именно элемент был кликнут, и выделяем его перед показом меню.
  if (PopupMenu.PopupComponent is TTreeViewItem) then
    tvFiles.Selected := TTreeViewItem(PopupMenu.PopupComponent);
end;

procedure TfmJFFS2Reader.tvFilesChange(Sender: TObject);
const
  MAX_READ_FOR_PREVIEW = 8 * 1024 * 1024;
  // не читаем в память файлы крупнее 8 МБ
var
  SelectedNode: TTreeViewItem;
  Props: TFSItemProps;
  Content: TBytes;
  S: string;
begin
  if tvFiles.Selected = nil then
    Exit;
  SelectedNode := tvFiles.Selected;
  if SelectedNode.TagString = '' then
    Exit;
  memoContent.Lines.Clear;
  HideImagePreview; // по умолчанию картинка спрятана, memo видно
  Props := Parser.GetItemProps(SelectedNode.TagString);
  if not Props.Found then
  begin
    memoContent.Lines.Add('(элемент не найден в образе)');
    Exit;
  end;

  // Сначала — всегда информация об элементе (путь, размер, сжатие и т.п.).
  memoContent.Lines.Text := BuildPropsText(SelectedNode.TagString, Props);
  if Props.IsDirectory then
    Exit; // для каталога больше показывать нечего
  if Props.Size = 0 then
  begin
    memoContent.Lines.Add('');
    memoContent.Lines.Add('(файл пуст)');
    Exit;
  end;
  if Props.Size > MAX_READ_FOR_PREVIEW then
  begin
    memoContent.Lines.Add('');
    memoContent.Lines.Add('(файл слишком большой для предпросмотра)');
    Exit;
  end;
  try
    Content := Parser.ReadFileData(SelectedNode.TagString);
  except
    on E: Exception do
    begin
      memoContent.Lines.Add('');
      memoContent.Lines.Add('(' + E.Message + ')');
      Exit;
    end;
  end;

  // Картинка — показываем в отдельном ImagePreview, свойства в memo уже есть.
  if IsImageContent(Content) then
  begin
    ShowImagePreview(Content);
    Exit;
  end;
  if not Parser.IsTextContent(Content) then
  begin
    memoContent.Lines.Add('');
    memoContent.Lines.Add
      ('(бинарный файл — предпросмотр содержимого недоступен)');
    Exit;
  end;

  // Похоже на текст — дописываем содержимое после информации о файле.
  if Length(Content) > MAX_TEXT_PREVIEW_SIZE then
  begin
    memoContent.Lines.Add('');
    memoContent.Lines.Add('(файл большой, показано только начало)');
    SetLength(Content, MAX_TEXT_PREVIEW_SIZE);
  end;
  SetString(S, PAnsiChar(Content), Length(Content));
  S := StringReplace(S, #0, '', [rfReplaceAll]);
  memoContent.Lines.Add('');
  memoContent.Lines.Add('--- содержимое ---');
  memoContent.Lines.Add(S);
end;
end.
