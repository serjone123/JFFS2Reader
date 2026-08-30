program JFFS2Reader;

uses
  System.StartUpCopy,
  FMX.Forms,
  uJFFS2RMain in 'uJFFS2RMain.pas' {fmJFFS2Reader},
  FS.JFFS2Reader in 'FS.JFFS2Reader.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfmJFFS2Reader, fmJFFS2Reader);
  Application.Run;
end.
