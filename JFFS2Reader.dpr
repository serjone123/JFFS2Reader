program JFFS2Reader;

uses
  System.StartUpCopy,
  FMX.Forms,
  uJFFS2RMain in 'uJFFS2RMain.pas' {Form1},
  FS.JFFS2Reader in 'FS.JFFS2Reader.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
