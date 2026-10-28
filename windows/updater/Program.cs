using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Net;
using System.Threading;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using System.ComponentModel;
namespace BirdLockUpdate {
public class Program {
    static string session;
    static DateTime lastState=DateTime.MinValue;
    static string recoveryTarget,originalVersion;
    static bool parentExited;
    static string lastEvent;
    static void State(string status,string text,int percent) {
        if(session==null)return;
        if(File.Exists(Path.Combine(session,"cancel")))Engine.Cancelled=true;
        if(Engine.Cancelled && status!="error")throw new OperationCanceledException();
        if(status=="downloading" && DateTime.UtcNow-lastState<TimeSpan.FromMilliseconds(200))return;
        lastState=DateTime.UtcNow;
        string path=Path.Combine(session,"state.json"),tmp=path+".tmp";
        File.WriteAllText(tmp,Engine.Json.Serialize(new{status=status,message=text,percent=percent}),new UTF8Encoding(false));
        for(int retry=0;;retry++) {
            try { if(File.Exists(path))File.Replace(tmp,path,null);else File.Move(tmp,path);break; }
            catch(IOException) {if(retry>=20)throw;Thread.Sleep(20);}
        }
        if(status!=lastEvent) {
            lastEvent=status;
            try { File.AppendAllText(Path.Combine(session,"events.log"),DateTime.UtcNow.ToString("o")+" "+status+" "+text+Environment.NewLine,new UTF8Encoding(false)); } catch {}
        }
        if(File.Exists(Path.Combine(session,"cancel")))Engine.Cancelled=true;
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct StartupInfo {public int cb;public string reserved,desktop,title;public int x,y,xSize,ySize,xCountChars,yCountChars,fillAttribute,flags;public short showWindow,reserved2Size;public IntPtr reserved2,stdInput,stdOutput,stdError;}
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {public IntPtr process,thread;public int pid,tid;}
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inheritHandles,uint flags,IntPtr environment,string directory,ref StartupInfo startup,out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static Process Launch(string executable,string arguments,string directory) {
        var startup=new StartupInfo{cb=Marshal.SizeOf(typeof(StartupInfo))};ProcessInfo info;
        if(!CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,false,0,IntPtr.Zero,directory,ref startup,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
        try{return Process.GetProcessById(info.pid);}finally{CloseHandle(info.thread);CloseHandle(info.process);}
    }
    public static int Main(string[] args) {
        Console.OutputEncoding=new UTF8Encoding(false);
        ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;
        try {
            var asm=Assembly.GetExecutingAssembly();WindowsConfig cfg;
            if(args.Length>0 && args[0]=="--install") {
                var location=Path.GetDirectoryName(asm.Location);
                var allowed=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BirdLock","updates");
                Guid id;
                if(!String.Equals(Path.GetDirectoryName(location),allowed,StringComparison.OrdinalIgnoreCase) || !Guid.TryParseExact(Path.GetFileName(location),"N",out id))throw new Exception("请从软件内启动更新");
                session=location;
            }
#if UPDATE_TESTS
            TestTransport.Setup();
#endif
            using(var reader=new StreamReader(asm.GetManifestResourceStream("UpdateConfig"))) cfg=Engine.Json.Deserialize<Config>(reader.ReadToEnd()).windows;
            if(String.IsNullOrEmpty(cfg.rsa_modulus))throw new Exception("此测试包尚未配置在线更新");
            if(args.Length<2)throw new Exception("缺少更新参数");
            string version=args[1];bool beta=args.Contains("--beta");
            var manifest=Engine.Verify(Engine.Fetch(!beta && !String.IsNullOrEmpty(cfg.stable_feed_url) ? cfg.stable_feed_url : cfg.feed_url),cfg);
            if(args[0]=="--check") {
                Console.WriteLine(Engine.Json.Serialize(new{available=Engine.Newer(manifest,version,beta),version=manifest.version,notes=manifest.notes??"",channel=manifest.channel}));return 0;
            }
            if(args[0]!="--install" || args.Length<5)throw new Exception("更新参数无效");
            session=Path.GetDirectoryName(asm.Location);
            string target=Path.GetFullPath(args[2]).TrimEnd(Path.DirectorySeparatorChar),expectedExe=Path.Combine(target,"BirdLock.exe");
            if(File.ReadAllText(Path.Combine(target,"_internal","VERSION")).Trim()!=version)throw new Exception("当前版本不匹配，请重新启动后更新");
            int pid=Int32.Parse(args[3]);string expectedVersion=args[4];
            var parent=Process.GetProcessById(pid);
            if(!String.Equals(parent.MainModule.FileName,expectedExe,StringComparison.OrdinalIgnoreCase))throw new Exception("运行程序与更新目录不匹配");
            if(!Engine.Newer(manifest,version,beta) || manifest.version!=expectedVersion)throw new Exception("更新版本已变化，请重新检查");
            string cache=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BirdLock","updates","downloads");
#if UPDATE_TESTS
            cache=TestTransport.CacheRoot;
#endif
            Engine.Progress=(text,percent)=> { State("downloading",text,percent);if(Engine.Cancelled)throw new OperationCanceledException(); };
            State("downloading","正在准备更新",0);
            string stage=Engine.Prepare(manifest,version,target,cache);
            try {
                if(Engine.Cancelled)throw new OperationCanceledException();
                State("ready","更新已校验，等待软件退出",100);
                if(!parent.WaitForExit(120000))throw new Exception("软件尚未退出，本次没有安装更新");
                recoveryTarget=target;originalVersion=version;parentExited=true;
                if(Engine.Cancelled)throw new OperationCanceledException();
                State("installing","正在安装更新",100);
                foreach(var other in Process.GetProcessesByName("BirdLock")) {
                    if(other.Id==pid)continue;
                    if(String.Equals(other.MainModule.FileName,expectedExe,StringComparison.OrdinalIgnoreCase))throw new Exception("另一个 BirdLock 仍在运行，请关闭后重试");
                }
                var backup=Engine.Swap(target,stage);
                Process child=null;
                try {
                    string health=Path.Combine(session,"health");
                    child=Launch(expectedExe,"--update-health \""+health+"\"",target);
                    DateTime deadline=DateTime.UtcNow.AddSeconds(45);
                    while(DateTime.UtcNow<deadline && !File.Exists(health) && !child.HasExited)Thread.Sleep(100);
                    if(!File.Exists(health) || File.ReadAllText(health)!=manifest.version)throw new Exception("新版未能完成启动，正在恢复旧版");
                    Thread.Sleep(1000);child.Refresh();if(child.HasExited)throw new Exception("新版启动后退出，正在恢复旧版");
                    State("complete","更新完成，旧版已保留以便回退",100);
                    return 0;
                } catch {
                    if(child!=null && !child.HasExited) { child.Kill();child.WaitForExit(); }
                    Engine.Rollback(target,backup);
                    throw;
                }
            } finally { if(Directory.Exists(stage))Directory.Delete(stage,true); }
        } catch(Exception e) {
            try { State("error",e is OperationCanceledException?"已取消更新":e.Message,0); } catch {}
            if(parentExited) {
                try {
                    string exe=Path.Combine(recoveryTarget,"BirdLock.exe");
                    bool running=Process.GetProcessesByName("BirdLock").Any(p=> {try{return String.Equals(p.MainModule.FileName,exe,StringComparison.OrdinalIgnoreCase);}catch{return false;}});
                    if(!running && File.ReadAllText(Path.Combine(recoveryTarget,"_internal","VERSION")).Trim()==originalVersion)
                        Launch(exe,"--update-result \""+session+"\"",recoveryTarget);
                } catch(Exception recovery) { Console.Error.WriteLine("恢复启动失败："+recovery.Message); }
            }
            Console.Error.WriteLine(e.Message);return 1;
        }
    }
}
}
