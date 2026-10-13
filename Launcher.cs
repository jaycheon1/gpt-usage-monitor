using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;
[assembly: AssemblyTitle("GPT Usage Monitor - Unofficial")]
[assembly: AssemblyDescription("Portable launcher for an unofficial Codex quota monitor")]
[assembly: AssemblyVersion("1.2.0.0")]
[assembly: AssemblyFileVersion("1.2.0.0")]
internal static class Launcher {
 [STAThread] private static int Main(string[] args) {
  try {
   string root=AppDomain.CurrentDomain.BaseDirectory;
   foreach(string file in new[]{"Bootstrap.ps1","Monitor.ps1","Monitor.xaml"})
    if(!File.Exists(Path.Combine(root,file))) throw new IOException("Extract the entire ZIP before running. Missing: "+file);
   if(args.Length==1 && args[0]=="--check") return 0;
   string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
   if(!File.Exists(ps)) throw new IOException("Windows PowerShell is required.");
   ProcessStartInfo start=new ProcessStartInfo(ps);
   bool selfTest=args.Length==1 && args[0]=="--self-test";
   start.Arguments="-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \""+Path.Combine(root,selfTest?"Test.ps1":"Bootstrap.ps1")+"\"";
   start.UseShellExecute=false;start.CreateNoWindow=true;start.WorkingDirectory=root;
   start.RedirectStandardError=true;start.RedirectStandardOutput=true;
   using(Process child=Process.Start(start)) {
    var stderr=child.StandardError.ReadToEndAsync();
    var stdout=child.StandardOutput.ReadToEndAsync();
    child.WaitForExit();
    if(selfTest) return child.ExitCode;
    if(child.ExitCode!=0) throw new IOException("Startup failed. See README.md for prerequisites and script-signing policy. System-wide settings were not changed.");
   }
   return 0;
  } catch(Exception ex) {
   if(args.Length==1 && (args[0]=="--check" || args[0]=="--self-test")) return 1;
   MessageBox.Show(ex.Message,"Usage Monitor",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;
  }
 }
}
