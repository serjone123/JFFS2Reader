unit FS.JFFS2Reader;

{
  Разбор дампа JFFS2.

  По результатам анализа предоставленного дампа установлено, что реальная
  раскладка узлов отличается от того, что предполагала предыдущая версия
  парсера:

    - узел типа $E001 — это DIRENT (запись каталога): pino/version/ino/
      mctime/nsize/dtype/... /name. Именно из таких узлов строится дерево
      файлов (это и раньше работало правильно, поэтому список отображался).

    - узел типа $E002 — это узел ДАННЫХ ФАЙЛА (аналог jffs2_raw_inode):
      ino/version/mode/uid/gid/isize/atime/mtime/ctime/offset/csize/dsize/
      compr/usercompr/flags/data_crc/node_crc, а после 68-байтного
      заголовка идут собственно данные (возможно, сжатые).

  Старая версия модуля путала эти два типа местами и, самое главное,
  вообще не сохраняла байты данных файла никуда (TFSItem.DataFragments/
  DataChunks заполнялись, но не использовались), а ExtractFile была
  пустой заглушкой. Поэтому список отображался, а содержимое — нет.
}

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.ZLib,
  System.IOUtils;

const
  JFFS2_MAGIC = $1985;

  // Типы узлов (эмпирически определены по дампу)
  NT_DIRENT   = $E001; // запись каталога (имя + связь ino/pino)
  NT_FILEDATA = $E002; // фрагмент данных файла

  // d_type записи каталога (совпадает с классическими значениями DT_*)
  DT_DIR = 4;
  DT_REG = 8;

  // Коды сжатия JFFS2
  COMPR_NONE      = 0;
  COMPR_ZERO      = 1;
  COMPR_RTIME     = 2;
  COMPR_RUBINMIPS = 3;
  COMPR_COPY      = 4;
  COMPR_DYNRUBIN  = 5;
  COMPR_ZLIB      = 6;
  COMPR_LZO       = 7;

  DIRENT_HDR_SIZE   = 40; // байт до имени в dirent-узле
  FILEDATA_HDR_SIZE = 68; // байт до данных в узле данных файла

  // Если размер файла больше этого значения, текстовый предпросмотр
  // не строится (только свойства) — чтобы не грузить в TMemo мегабайты.
  MAX_TEXT_PREVIEW_SIZE = 256 * 1024; // 256 KB

type
  // Свойства элемента дерева, для отображения без загрузки содержимого целиком.
  TFSItemProps = record
    Found: Boolean;
    IsDirectory: Boolean;
    Ino: Cardinal;
    Pino: Cardinal;
    Size: Int64;
    FragmentCount: Integer;  // для файлов — кол-во узлов данных
    ChildCount: Integer;     // для каталогов — кол-во непосредственных потомков
    Compression: string;     // человекочитаемый список кодеков, встретившихся во фрагментах
  end;

  TFileFragment = record
    Offset: Cardinal;   // смещение фрагмента внутри файла
    Version: Cardinal;  // версия узла (порядок применения фрагментов)
    Data: TBytes;       // данные (уже распакованные, если распаковка удалась)
    Compr: Byte;        // исходный код сжатия
    Decoded: Boolean;   // удалось ли распаковать
  end;

  TFSItem = class
  public
    Ino: Cardinal;
    Pino: Cardinal;
    Name: string;
    IsDirectory: Boolean;
    DirentVersion: Cardinal;
    Size: Cardinal;                  // isize из самого свежего фрагмента
    Fragments: TList<TFileFragment>;
    constructor Create;
    destructor Destroy; override;
  end;

  TJFFS2Parser = class
  private
    FStream: TFileStream;
    FItems: TObjectDictionary<Cardinal, TFSItem>;
    FCRCTable: array [0 .. 255] of Cardinal;
    FRootIno: Cardinal;
    FPathIndex: TDictionary<string, Cardinal>; // путь -> ino, строится в GetFileList

    procedure InitCRCTable;
    function CRC32Buf(const Buffer; Len: Integer): Cardinal;

    function ReadBE32At(const Buffer: TBytes; Offset: Integer): Cardinal;
    function IsPrintable(B: Byte): Boolean;
    function HexDump(const Buffer: TBytes; MaxBytes: Integer = 48): string;
    function AsciiDump(const Buffer: TBytes; MaxBytes: Integer = 64): string;

    function ReadNode(NodePos: Int64; out NodeType: Word; out TotLen: Cardinal;
      out NodeData: TBytes): Boolean;
    procedure ParseStream;
    procedure HandleDirentNode(const NodeData: TBytes);
    procedure HandleFileDataNode(const NodeData: TBytes);

    function TryDecompress(Compr: Byte; const InData: TBytes; DSize: Cardinal;
      out OutData: TBytes): Boolean;

    procedure BuildChildTree(out Childs: TDictionary<Cardinal, TList<Cardinal>>;
      out RootIno: Cardinal);
    procedure BuildPath(CurrentIno: Cardinal; const CurrentPath: string;
      Childs: TDictionary<Cardinal, TList<Cardinal>>; ResultList: TStrings;
      PathIndex: TDictionary<string, Cardinal>);

    function AssembleFileData(Item: TFSItem): TBytes;
    function FindItemByPath(const DisplayPath: string; out Item: TFSItem): Boolean;
    function CompressionName(Compr: Byte): string;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;

    function GetFileList: TArray<string>;

    // Возвращает содержимое файла по пути, полученному из GetFileList.
    function ReadFileData(const DisplayPath: string): TBytes;

    // Свойства файла/каталога без загрузки и сборки содержимого —
    // дёшево вызывать перед тем, как решать, показывать превью или нет.
    function GetItemProps(const DisplayPath: string): TFSItemProps;

    // Грубая эвристика: похожи ли байты на текст (нет NUL-байтов, мало
    // "мусорных" непечатаемых символов в начале файла).
    function IsTextContent(const Data: TBytes): Boolean;

    // Извлекает файл на диск. Бросает исключение, если путь не найден
    // или это каталог.
    procedure ExtractFile(const DisplayPath: string; const OutputPath: string);

    // Извлекает содержимое каталога (рекурсивно) в указанную папку на диске.
    procedure ExtractFolder(const DisplayPath: string; const OutputDir: string);

    // Извлекает вообще всё дерево в указанную папку.
    procedure ExtractAll(const OutputDir: string);

    procedure AnalyzeToStrings(Lines: TStrings);
  end;

implementation

{ ---------------------------------------------------------------------------
  TFSItem
  --------------------------------------------------------------------------- }
constructor TFSItem.Create;
begin
  inherited Create;
  Fragments := TList<TFileFragment>.Create;
end;

destructor TFSItem.Destroy;
begin
  Fragments.Free;
  inherited;
end;

{ ---------------------------------------------------------------------------
  Constructor / Destructor
  --------------------------------------------------------------------------- }
constructor TJFFS2Parser.Create(const AFileName: string);
begin
  inherited Create;
  InitCRCTable;
  FStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  FItems := TObjectDictionary<Cardinal, TFSItem>.Create([doOwnsValues]);
  FRootIno := 1;
  FPathIndex := nil;
  ParseStream;
end;

destructor TJFFS2Parser.Destroy;
begin
  FPathIndex.Free;
  FItems.Free;
  FStream.Free;
  inherited;
end;

{ ---------------------------------------------------------------------------
  CRC32 (используется опционально, оставлено для будущей проверки целостности)
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.InitCRCTable;
var
  I, J: Integer;
  C: Cardinal;
begin
  for I := 0 to 255 do
  begin
    C := Cardinal(I);
    for J := 0 to 7 do
    begin
      if (C and 1) <> 0 then
        C := $EDB88320 xor (C shr 1)
      else
        C := C shr 1;
    end;
    FCRCTable[I] := C;
  end;
end;

function TJFFS2Parser.CRC32Buf(const Buffer; Len: Integer): Cardinal;
var
  P: PByte;
  I: Integer;
begin
  Result := $FFFFFFFF;
  P := PByte(@Buffer);
  for I := 0 to Len - 1 do
  begin
    Result := FCRCTable[(Result xor P^) and $FF] xor (Result shr 8);
    Inc(P);
  end;
  Result := Result xor $FFFFFFFF;
end;

{ ---------------------------------------------------------------------------
  Raw buffer helpers
  --------------------------------------------------------------------------- }
function TJFFS2Parser.ReadBE32At(const Buffer: TBytes; Offset: Integer): Cardinal;
begin
  if (Offset < 0) or (Offset + 3 >= Length(Buffer)) then Exit(0);
  Result := (Cardinal(Buffer[Offset]) shl 24) or
    (Cardinal(Buffer[Offset + 1]) shl 16) or
    (Cardinal(Buffer[Offset + 2]) shl 8) or Cardinal(Buffer[Offset + 3]);
end;

function TJFFS2Parser.IsPrintable(B: Byte): Boolean;
begin
  Result := (B >= $20) and (B <= $7E);
end;

function TJFFS2Parser.HexDump(const Buffer: TBytes; MaxBytes: Integer): string;
const
  Hex: array [0 .. 15] of Char = '0123456789ABCDEF';
var
  I, N: Integer;
begin
  Result := '';
  N := Length(Buffer);
  if N > MaxBytes then N := MaxBytes;
  for I := 0 to N - 1 do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + Hex[Buffer[I] shr 4] + Hex[Buffer[I] and $0F];
  end;
  if Length(Buffer) > MaxBytes then Result := Result + ' ...';
end;

function TJFFS2Parser.AsciiDump(const Buffer: TBytes; MaxBytes: Integer): string;
var
  I, N: Integer;
begin
  Result := '';
  N := Length(Buffer);
  if N > MaxBytes then N := MaxBytes;
  for I := 0 to N - 1 do
  begin
    if IsPrintable(Buffer[I]) then
      Result := Result + Char(Buffer[I])
    else
      Result := Result + '.';
  end;
  if Length(Buffer) > MaxBytes then Result := Result + '...';
end;

{ ---------------------------------------------------------------------------
  Decompression
  --------------------------------------------------------------------------- }
function TJFFS2Parser.TryDecompress(Compr: Byte; const InData: TBytes;
  DSize: Cardinal; out OutData: TBytes): Boolean;
var
  InStream: TBytesStream;
  DecompStream: TDecompressionStream;
  OutStream: TMemoryStream;
  Buffer: array [0 .. 4095] of Byte;
  Count: Integer;
begin
  Result := False;
  OutData := nil;

  case Compr of
    COMPR_NONE, COMPR_COPY:
      begin
        OutData := InData;
        Exit(True);
      end;

    COMPR_ZERO:
      begin
        SetLength(OutData, DSize);
        if DSize > 0 then
          FillChar(OutData[0], DSize, 0);
        Exit(True);
      end;

    COMPR_ZLIB:
      begin
        if Length(InData) < 2 then Exit(False);
        try
          InStream := TBytesStream.Create(InData);
          try
            DecompStream := TDecompressionStream.Create(InStream);
            try
              OutStream := TMemoryStream.Create;
              try
                repeat
                  Count := DecompStream.Read(Buffer, SizeOf(Buffer));
                  if Count > 0 then OutStream.WriteBuffer(Buffer, Count);
                until Count = 0;
                SetLength(OutData, OutStream.Size);
                if OutStream.Size > 0 then
                  Move(OutStream.Memory^, OutData[0], OutStream.Size);
                Result := True;
              finally
                OutStream.Free;
              end;
            finally
              DecompStream.Free;
            end;
          finally
            InStream.Free;
          end;
        except
          Result := False;
        end;
      end;
  else
    // COMPR_RTIME / COMPR_RUBINMIPS / COMPR_DYNRUBIN / COMPR_LZO — не
    // реализованы (нестандартные для JFFS2 схемы сжатия). Возвращаем
    // False, вызывающий код сохранит исходные байты как есть.
    Result := False;
  end;
end;

{ ---------------------------------------------------------------------------
  Reading node
  --------------------------------------------------------------------------- }
function TJFFS2Parser.ReadNode(NodePos: Int64; out NodeType: Word;
  out TotLen: Cardinal; out NodeData: TBytes): Boolean;
var
  Hdr: array [0 .. 11] of Byte;
begin
  Result := False;
  NodeType := 0;
  TotLen := 0;
  SetLength(NodeData, 0);
  if NodePos + 12 > FStream.Size then Exit;

  FStream.Position := NodePos;
  FStream.ReadBuffer(Hdr, SizeOf(Hdr));

  if (Hdr[0] <> $19) or (Hdr[1] <> $85) then Exit;

  NodeType := (Word(Hdr[2]) shl 8) or Word(Hdr[3]);
  TotLen := (Cardinal(Hdr[4]) shl 24) or (Cardinal(Hdr[5]) shl 16) or
    (Cardinal(Hdr[6]) shl 8) or Cardinal(Hdr[7]);

  if TotLen < 12 then Exit;
  if NodePos + TotLen > FStream.Size then Exit;

  SetLength(NodeData, TotLen);
  FStream.Position := NodePos;
  FStream.ReadBuffer(NodeData[0], TotLen);
  Result := True;
end;

{ ---------------------------------------------------------------------------
  DIRENT ($E001): pino/version/ino/mctime/nsize/dtype/.../name
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.HandleDirentNode(const NodeData: TBytes);
var
  Pino, Version, Ino: Cardinal;
  NameLen: Byte;
  DType: Byte;
  Name: string;
  Item: TFSItem;
begin
  if Length(NodeData) < DIRENT_HDR_SIZE then Exit;

  Pino := ReadBE32At(NodeData, 12);
  Version := ReadBE32At(NodeData, 16);
  Ino := ReadBE32At(NodeData, 20);
  NameLen := NodeData[28];
  DType := NodeData[29];

  if Ino = 0 then Exit; // whiteout / удалённая запись — пропускаем
  if (NameLen = 0) or (DIRENT_HDR_SIZE + NameLen > Length(NodeData)) then Exit;

  SetString(Name, PAnsiChar(@NodeData[DIRENT_HDR_SIZE]), NameLen);

  if not FItems.TryGetValue(Ino, Item) then
  begin
    Item := TFSItem.Create;
    Item.Ino := Ino;
    FItems.Add(Ino, Item);
  end;

  // На флеше может быть несколько версий одной и той же записи каталога
  // (переименование/перемещение) — оставляем самую свежую по version.
  if (Item.DirentVersion = 0) or (Version >= Item.DirentVersion) then
  begin
    Item.Pino := Pino;
    Item.Name := Name;
    Item.DirentVersion := Version;
    Item.IsDirectory := (DType = DT_DIR);
  end;
end;

{ ---------------------------------------------------------------------------
  Узел данных файла ($E002): ino/version/mode/.../isize/.../offset/csize/
  dsize/compr/.../data
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.HandleFileDataNode(const NodeData: TBytes);
var
  Ino, Version, ISize, OffsetInFile, CSize, DSize: Cardinal;
  Compr: Byte;
  RawData: TBytes;
  Item: TFSItem;
  Frag: TFileFragment;
begin
  if Length(NodeData) < FILEDATA_HDR_SIZE then Exit;

  Ino := ReadBE32At(NodeData, 12);
  Version := ReadBE32At(NodeData, 16);
  ISize := ReadBE32At(NodeData, 28);
  OffsetInFile := ReadBE32At(NodeData, 44);
  CSize := ReadBE32At(NodeData, 48);
  DSize := ReadBE32At(NodeData, 52);
  Compr := NodeData[56];

  if Ino = 0 then Exit;
  if Cardinal(FILEDATA_HDR_SIZE) + CSize > Cardinal(Length(NodeData)) then Exit; // повреждённый/усечённый узел

  SetLength(RawData, CSize);
  if CSize > 0 then
    Move(NodeData[FILEDATA_HDR_SIZE], RawData[0], CSize);

  if not FItems.TryGetValue(Ino, Item) then
  begin
    Item := TFSItem.Create;
    Item.Ino := Ino;
    FItems.Add(Ino, Item);
  end;

  Frag.Offset := OffsetInFile;
  Frag.Version := Version;
  Frag.Compr := Compr;
  Frag.Decoded := TryDecompress(Compr, RawData, DSize, Frag.Data);
  if not Frag.Decoded then
    Frag.Data := RawData; // сохраняем как есть — лучше «сырые» байты, чем ничего

  Item.Fragments.Add(Frag);
  if ISize > Item.Size then
    Item.Size := ISize;
end;

{ ---------------------------------------------------------------------------
  Main parse loop
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.ParseStream;
var
  Pos: Int64;
  NodeType: Word;
  TotLen: Cardinal;
  NodeData: TBytes;
begin
  FItems.Clear;
  Pos := 0;
  while Pos + 12 <= FStream.Size do
  begin
    if ReadNode(Pos, NodeType, TotLen, NodeData) then
    begin
      case NodeType of
        NT_DIRENT:   HandleDirentNode(NodeData);
        NT_FILEDATA: HandleFileDataNode(NodeData);
      end;
      Pos := Pos + ((Int64(TotLen) + 3) and not 3);
    end
    else
      Inc(Pos); // ищем следующее совпадение магии $1985 побайтово (флеш выровнен, но между узлами бывает $FF-заполнение)
  end;
end;

{ ---------------------------------------------------------------------------
  Tree building
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.BuildChildTree(out Childs: TDictionary<Cardinal, TList<Cardinal>>;
  out RootIno: Cardinal);
var
  Item: TFSItem;
  Pino: Cardinal;
  HasRoot: Boolean;
begin
  Childs := TDictionary<Cardinal, TList<Cardinal>>.Create;
  RootIno := 1;
  HasRoot := False;

  for Item in FItems.Values do
    if Item.Pino = 0 then
    begin
      RootIno := Item.Ino;
      HasRoot := True;
      Break;
    end;

  if not HasRoot then
    for Item in FItems.Values do
      if Item.Pino = 1 then
      begin
        RootIno := 1;
        HasRoot := True;
        Break;
      end;

  FRootIno := RootIno;

  for Item in FItems.Values do
  begin
    Pino := Item.Pino;
    if (Pino = 0) or (Pino = RootIno) then
      Pino := RootIno;

    if not Childs.ContainsKey(Pino) then
      Childs.Add(Pino, TList<Cardinal>.Create);
    Childs[Pino].Add(Item.Ino);
  end;
end;

procedure TJFFS2Parser.BuildPath(CurrentIno: Cardinal; const CurrentPath: string;
  Childs: TDictionary<Cardinal, TList<Cardinal>>; ResultList: TStrings;
  PathIndex: TDictionary<string, Cardinal>);
var
  Item: TFSItem;
  ChildIno: Cardinal;
  NewPath: string;
  HasChildren: Boolean;
begin
  HasChildren := Childs.ContainsKey(CurrentIno) and (Childs[CurrentIno].Count > 0);

  if FItems.TryGetValue(CurrentIno, Item) then
  begin
    if CurrentPath <> '' then
      NewPath := CurrentPath + '/' + Item.Name
    else
      NewPath := Item.Name;

    if CurrentIno <> FRootIno then
    begin
      ResultList.Add(NewPath);
      if Assigned(PathIndex) and not PathIndex.ContainsKey(NewPath) then
        PathIndex.Add(NewPath, CurrentIno);
    end;
  end
  else
    NewPath := CurrentPath;

  if HasChildren then
    for ChildIno in Childs[CurrentIno] do
      BuildPath(ChildIno, NewPath, Childs, ResultList, PathIndex);
end;

function TJFFS2Parser.GetFileList: TArray<string>;
var
  Childs: TDictionary<Cardinal, TList<Cardinal>>;
  RootIno: Cardinal;
  ResultList: TStringList;
begin
  if FItems.Count = 0 then
    ParseStream;

  FreeAndNil(FPathIndex);
  FPathIndex := TDictionary<string, Cardinal>.Create;

  BuildChildTree(Childs, RootIno);
  try
    ResultList := TStringList.Create;
    try
      BuildPath(RootIno, '', Childs, ResultList, FPathIndex);
      Result := ResultList.ToStringArray;
    finally
      ResultList.Free;
    end;
  finally
    Childs.Free;
  end;
end;

{ ---------------------------------------------------------------------------
  Извлечение содержимого файла
  --------------------------------------------------------------------------- }
function TJFFS2Parser.FindItemByPath(const DisplayPath: string; out Item: TFSItem): Boolean;
var
  Ino: Cardinal;
begin
  if not Assigned(FPathIndex) then
    GetFileList; // построит индекс путей

  Result := Assigned(FPathIndex) and FPathIndex.TryGetValue(DisplayPath, Ino)
    and FItems.TryGetValue(Ino, Item);
end;

function TJFFS2Parser.AssembleFileData(Item: TFSItem): TBytes;
var
  Sorted: TList<TFileFragment>;
  Frag: TFileFragment;
  Comparer: IComparer<TFileFragment>;
  NeedLen: Int64;
  I: Integer;
begin
  SetLength(Result, 0);
  if Item.Fragments.Count = 0 then Exit;

  // Применяем фрагменты в порядке возрастания версии — более новые
  // перезаписывают перекрывающиеся области, как это делает сам JFFS2.
  Comparer := TComparer<TFileFragment>.Construct(
    function(const A, B: TFileFragment): Integer
    begin
      Result := Integer(A.Version) - Integer(B.Version);
    end);

  Sorted := TList<TFileFragment>.Create;
  try
    for I := 0 to Item.Fragments.Count - 1 do
      Sorted.Add(Item.Fragments[I]);
    Sorted.Sort(Comparer);

    NeedLen := Item.Size;
    for Frag in Sorted do
      if Int64(Frag.Offset) + Length(Frag.Data) > NeedLen then
        NeedLen := Int64(Frag.Offset) + Length(Frag.Data);

    SetLength(Result, NeedLen);
    if NeedLen > 0 then
      FillChar(Result[0], NeedLen, 0);

    for Frag in Sorted do
      if Length(Frag.Data) > 0 then
        Move(Frag.Data[0], Result[Frag.Offset], Length(Frag.Data));
  finally
    Sorted.Free;
  end;
end;

function TJFFS2Parser.CompressionName(Compr: Byte): string;
begin
  case Compr of
    COMPR_NONE:      Result := 'none';
    COMPR_ZERO:      Result := 'zero';
    COMPR_RTIME:     Result := 'rtime (не распаковывается)';
    COMPR_RUBINMIPS: Result := 'rubinmips (не распаковывается)';
    COMPR_COPY:      Result := 'copy';
    COMPR_DYNRUBIN:  Result := 'dynrubin (не распаковывается)';
    COMPR_ZLIB:      Result := 'zlib';
    COMPR_LZO:       Result := 'lzo (не распаковывается)';
  else
    Result := Format('неизвестно ($%.2X)', [Compr]);
  end;
end;

function TJFFS2Parser.GetItemProps(const DisplayPath: string): TFSItemProps;
var
  Item, Other: TFSItem;
  Frag: TFileFragment;
  Codecs: TStringList;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Found := FindItemByPath(DisplayPath, Item);
  if not Result.Found then Exit;

  Result.Ino := Item.Ino;
  Result.Pino := Item.Pino;
  Result.IsDirectory := Item.IsDirectory;
  Result.Size := Item.Size;
  Result.FragmentCount := Item.Fragments.Count;

  if Item.IsDirectory then
  begin
    for Other in FItems.Values do
      if Other.Pino = Item.Ino then
        Inc(Result.ChildCount);
  end
  else
  begin
    Codecs := TStringList.Create;
    try
      Codecs.Sorted := True;
      Codecs.Duplicates := dupIgnore;
      for Frag in Item.Fragments do
        Codecs.Add(CompressionName(Frag.Compr));
      Result.Compression := Codecs.CommaText;
    finally
      Codecs.Free;
    end;
  end;
end;

function TJFFS2Parser.IsTextContent(const Data: TBytes): Boolean;
var
  I, Checked, NonText: Integer;
begin
  if Length(Data) = 0 then Exit(True);

  Checked := 0;
  NonText := 0;
  for I := 0 to Length(Data) - 1 do
  begin
    if Data[I] = 0 then Exit(False); // NUL-байт — верный признак бинарных данных
    Inc(Checked);
    if not (IsPrintable(Data[I]) or (Data[I] in [9, 10, 13])) then
      Inc(NonText);
    if Checked >= 8192 then Break; // для скорости проверяем только начало файла
  end;

  Result := (Checked = 0) or (NonText / Checked < 0.05);
end;

function TJFFS2Parser.ReadFileData(const DisplayPath: string): TBytes;
var
  Item: TFSItem;
begin
  if not FindItemByPath(DisplayPath, Item) then
    raise Exception.CreateFmt('Файл не найден в образе: %s', [DisplayPath]);
  if Item.IsDirectory then
    raise Exception.CreateFmt('"%s" — это каталог, а не файл', [DisplayPath]);

  Result := AssembleFileData(Item);
end;

procedure TJFFS2Parser.ExtractFile(const DisplayPath: string; const OutputPath: string);
var
  Data: TBytes;
  OutFile: TFileStream;
begin
  Data := ReadFileData(DisplayPath);

  ForceDirectories(ExtractFilePath(OutputPath));
  OutFile := TFileStream.Create(OutputPath, fmCreate);
  try
    if Length(Data) > 0 then
      OutFile.WriteBuffer(Data[0], Length(Data));
  finally
    OutFile.Free;
  end;
end;

procedure TJFFS2Parser.ExtractFolder(const DisplayPath: string; const OutputDir: string);
var
  RootItem, Item: TFSItem;
  Prefix, Path, Relative: string;
begin
  if not FindItemByPath(DisplayPath, RootItem) then
    raise Exception.CreateFmt('Путь не найден в образе: %s', [DisplayPath]);
  if not RootItem.IsDirectory then
    raise Exception.CreateFmt('"%s" — это файл, а не каталог (используйте ExtractFile)', [DisplayPath]);

  Prefix := DisplayPath + '/';
  ForceDirectories(OutputDir);

  for Path in GetFileList do
  begin
    if not Path.StartsWith(Prefix) then Continue;
    if not FindItemByPath(Path, Item) then Continue;

    Relative := Copy(Path, Length(Prefix) + 1, MaxInt);
    if Relative = '' then Continue;
    // Пути в образе всегда на '/', на диске нужен родной разделитель.
    Relative := StringReplace(Relative, '/', PathDelim, [rfReplaceAll]);

    if Item.IsDirectory then
      ForceDirectories(TPath.Combine(OutputDir, Relative))
    else
      ExtractFile(Path, TPath.Combine(OutputDir, Relative));
  end;
end;

procedure TJFFS2Parser.ExtractAll(const OutputDir: string);
var
  Path, NativePath: string;
  Item: TFSItem;
begin
  for Path in GetFileList do
  begin
    if not FindItemByPath(Path, Item) then Continue;
    NativePath := StringReplace(Path, '/', PathDelim, [rfReplaceAll]);
    if Item.IsDirectory then
    begin
      ForceDirectories(TPath.Combine(OutputDir, NativePath));
      Continue;
    end;
    ExtractFile(Path, TPath.Combine(OutputDir, NativePath));
  end;
end;

{ ---------------------------------------------------------------------------
  Диагностический дамп (для отладки / просмотра сырых узлов)
  --------------------------------------------------------------------------- }
procedure TJFFS2Parser.AnalyzeToStrings(Lines: TStrings);
var
  Pos: Int64;
  NodeType: Word;
  TotLen: Cardinal;
  NodeData: TBytes;
  NodeCount: Integer;
  Pino, Version, Ino, ISize, OffsetInFile, CSize, DSize: Cardinal;
  NameLen: Byte;
  DType: Byte;
  Name: string;
  Compr: Byte;
begin
  Lines.BeginUpdate;
  try
    Lines.Clear;
    Lines.Add('=== JFFS2 scanner ===');
    Lines.Add(Format('File size: %d bytes ($%X)', [FStream.Size, FStream.Size]));
    Lines.Add('');
    Pos := 0;
    NodeCount := 0;
    while Pos + 12 <= FStream.Size do
    begin
      if ReadNode(Pos, NodeType, TotLen, NodeData) then
      begin
        Inc(NodeCount);
        Lines.Add(Format('@$%.8X  type=$%.4X  len=%d ($%.8X)',
          [Pos, NodeType, TotLen, TotLen]));

        case NodeType of
          NT_DIRENT:
            begin
              Lines.Add('  DIRENT');
              if Length(NodeData) >= DIRENT_HDR_SIZE then
              begin
                Pino := ReadBE32At(NodeData, 12);
                Version := ReadBE32At(NodeData, 16);
                Ino := ReadBE32At(NodeData, 20);
                NameLen := NodeData[28];
                DType := NodeData[29];
                Lines.Add(Format('    pino=%d  version=%d  ino=%d  dtype=%d',
                  [Pino, Version, Ino, DType]));
                if (NameLen > 0) and (DIRENT_HDR_SIZE + NameLen <= Length(NodeData)) then
                begin
                  SetString(Name, PAnsiChar(@NodeData[DIRENT_HDR_SIZE]), NameLen);
                  Lines.Add('    name: "' + Name + '"');
                end;
              end;
            end;

          NT_FILEDATA:
            begin
              Lines.Add('  FILEDATA');
              if Length(NodeData) >= FILEDATA_HDR_SIZE then
              begin
                Ino := ReadBE32At(NodeData, 12);
                Version := ReadBE32At(NodeData, 16);
                ISize := ReadBE32At(NodeData, 28);
                OffsetInFile := ReadBE32At(NodeData, 44);
                CSize := ReadBE32At(NodeData, 48);
                DSize := ReadBE32At(NodeData, 52);
                Compr := NodeData[56];
                Lines.Add(Format('    ino=%d  version=%d  isize=%d  offset=%d  csize=%d  dsize=%d  compr=%d',
                  [Ino, Version, ISize, OffsetInFile, CSize, DSize, Compr]));
                if Cardinal(FILEDATA_HDR_SIZE) + CSize <= Cardinal(Length(NodeData)) then
                begin
                  var Preview: TBytes;
                  SetLength(Preview, CSize);
                  if CSize > 0 then
                    Move(NodeData[FILEDATA_HDR_SIZE], Preview[0], CSize);
                  Lines.Add('    ascii: "' + AsciiDump(Preview, 64) + '"');
                end;
              end;
            end;
        else
          Lines.Add(Format('  UNKNOWN node type=$%.4X', [NodeType]));
          Lines.Add('    ascii: "' + AsciiDump(NodeData, 64) + '"');
          Lines.Add('    hex: ' + HexDump(NodeData, 64));
        end;

        Lines.Add('');
        Pos := Pos + ((Int64(TotLen) + 3) and not 3);
        Continue;
      end;
      Inc(Pos);
    end;
    Lines.Add('========================================');
    Lines.Add(Format('Nodes found: %d', [NodeCount]));
    Lines.Add('=== scan finished ===');
  finally
    Lines.EndUpdate;
  end;
end;

end.
