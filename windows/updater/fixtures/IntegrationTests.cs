using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.IO.Compression;
using System.Threading;
using BirdLockUpdate;
class IntegrationTests {
 static string root,source,compiler;
 static void Check(bool value,string name){if(!value)throw new Exception(name);}
 static string Q(string s){return "\""+s+"\"";}
 static void Compile(string options){var p=Process.Start(new ProcessStartInfo(compiler,"/nologo /optimize+ /platform:x64 "+options){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true});string output=p.StandardOutput.ReadToEnd()+p.StandardError.ReadToEnd();p.WaitForExit();Check(p.ExitCode==0,"Compile: "+output);}
 static void Write(string dir,string path,byte[] data){string f=Path.Combine(dir,path);Directory.CreateDirectory(Path.GetDirectoryName(f));File.WriteAllBytes(f,data);}
 static byte[] Text(string value){return new UTF8Encoding(false).GetBytes(value);}
 static FileSpec Spec(byte[] bytes){using(var s=new MemoryStream(bytes))return new FileSpec{size=bytes.Length,sha256=Engine.Hash(s)};}
 static Package Zip(string dir,string filename,Dictionary<string,byte[]> files){string file=Path.Combine(dir,filename);using(var z=ZipFile.Open(file,ZipArchiveMode.Create)){foreach(var f in files){var e=z.CreateEntry(f.Key);using(var s=e.Open())s.Write(f.Value,0,f.Value.Length);}}using(var s=File.OpenRead(file))return new Package{url="https://fixture.invalid/"+filename,prefix="",size=s.Length,sha256=Engine.Hash(s)};}
 static void CleanupProcesses(string path){foreach(var p in Process.GetProcessesByName("BirdLock")){try{if(p.MainModule.FileName.StartsWith(path+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)){p.Kill();p.WaitForExit();}}catch(InvalidOperationException){}}}
 static void Run(string name,byte[] app,RSACryptoServiceProvider rsa,bool delta,bool changedBase,bool badSignature,bool corruptPackage,bool badProgram,bool noHealth){
  string dir=Path.Combine(root,name),target=Path.Combine(dir,"BirdLock"),files=Path.Combine(dir,"network");Directory.CreateDirectory(files);
  var old=new Dictionary<string,byte[]>{{"BirdLock.exe",app},{"_internal/VERSION",Text("1.0.0")},{"unchanged.bin",Text("same runtime data")}};
  string catalog="_internal/updates/managed-files.json";old[catalog]=Text(Engine.Json.Serialize(old.Keys.Concat(new[]{catalog}).OrderBy(x=>x).ToArray()));
  foreach(var f in old)Write(target,f.Key,f.Value);Write(target,"data/settings.json",Text("settings sentinel"));Write(target,"photos/data/original.jpg",Text("photo sentinel"));
  var next=old.ToDictionary(x=>x.Key,x=>x.Value);next["_internal/VERSION"]=Text("1.1.0");if(badProgram)next["BirdLock.exe"]=Text("invalid executable test fixture");
  var full=Zip(files,"full.zip",next);var manifest=new Manifest{schema=1,version="1.1.0",channel="beta",full=full,files=next.ToDictionary(x=>x.Key,x=>Spec(x.Value))};
  if(delta){var changes=next.Where(x=>!old[x.Key].SequenceEqual(x.Value)).ToDictionary(x=>x.Key,x=>x.Value);manifest.delta=Zip(files,"delta.zip",changes);manifest.delta.from="1.0.0";}
  if(changedBase)Write(target,"unchanged.bin",Text("locally modified runtime"));
  byte[] payload=Text(Engine.Json.Serialize(manifest));var signature=rsa.SignData(payload,CryptoConfig.MapNameToOID("SHA256"));if(badSignature)signature[0]^=1;
  File.WriteAllText(Path.Combine(files,"feed.json"),Engine.Json.Serialize(new Envelope{payload=Convert.ToBase64String(payload),signature=Convert.ToBase64String(signature)}));
  if(corruptPackage)File.WriteAllBytes(Path.Combine(files,"full.zip"),new byte[full.size]);
  string sessions=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"BirdLock","updates"),session=Path.Combine(sessions,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(session);
  string updater=Path.Combine(session,"BirdLockUpdater.exe");File.Copy(Path.Combine(root,"Updater-test.exe"),updater);
  string exit=Path.Combine(dir,"exit");Process parent=null,worker=null;
  try {
   parent=Process.Start(new ProcessStartInfo(Path.Combine(target,"BirdLock.exe"),"--wait "+Q(exit)){UseShellExecute=false,CreateNoWindow=true,WorkingDirectory=target});
   var info=new ProcessStartInfo(updater,"--install 1.0.0 "+Q(target)+" "+parent.Id+" 1.1.0 --beta"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true};
   info.EnvironmentVariables["BIRDLOCK_QA_FILES"]=files;if(noHealth)info.EnvironmentVariables["BIRDLOCK_QA_SKIP_HEALTH"]="1";
   worker=Process.Start(info);DateTime deadline=DateTime.UtcNow.AddSeconds(75);bool ready=false;
   while(!worker.HasExited && DateTime.UtcNow<deadline){
    try{var state=Engine.Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(session,"state.json")));if((string)state["status"]=="ready"){File.WriteAllText(exit,"exit");ready=true;}}catch(IOException){}catch(ArgumentException){}
    Thread.Sleep(100);
   }
   Check(worker.HasExited,"updater did not finish");string error=worker.StandardError.ReadToEnd();bool success=!badSignature&&!corruptPackage&&!badProgram&&!noHealth;
   Check((worker.ExitCode==0)==success,name+" exit: "+error);
   Check(File.ReadAllText(Path.Combine(target,"_internal/VERSION")).Trim()==(success?"1.1.0":"1.0.0"),name+" version");
   Check(File.ReadAllText(Path.Combine(target,"data/settings.json"))=="settings sentinel",name+" settings");
   Check(File.ReadAllText(Path.Combine(target,"photos/data/original.jpg"))=="photo sentinel",name+" original photo");
   if(success&&delta){string requests=File.ReadAllText(Path.Combine(files,"requests.log"));Check(requests.Contains("delta.zip:"),name+" delta not requested");Check(requests.Contains("full.zip:")==changedBase,name+" full fallback");}
   if(badSignature||corruptPackage)Check(!ready&&!parent.HasExited,name+" old app exited too early");
   File.WriteAllText(Path.Combine(dir,"result.json"),Engine.Json.Serialize(new{test=name,success=success,ready=ready,exit=worker.ExitCode,settingsPreserved=true,photosPreserved=true}));
   Console.WriteLine("PASS process integration "+name);
  } finally {if(worker!=null&&!worker.HasExited){worker.Kill();worker.WaitForExit();}File.WriteAllText(exit,"exit");if(parent!=null)parent.WaitForExit(3000);CleanupProcesses(dir);Directory.Delete(session,true);}
 }
 static int Main(string[] args){
  source=args[0];compiler=Path.Combine(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(),"csc.exe");root=Path.Combine(Path.GetTempPath(),"BirdLockUpdaterIntegration-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
  try {
   using(var rsa=new RSACryptoServiceProvider(2048,new CspParameters(24))){rsa.PersistKeyInCsp=false;var p=rsa.ExportParameters(false);string cfg=Path.Combine(root,"config.json");File.WriteAllText(cfg,Engine.Json.Serialize(new Config{windows=new WindowsConfig{feed_url="https://fixture.invalid/feed.json",rsa_modulus=Convert.ToBase64String(p.Modulus),rsa_exponent=Convert.ToBase64String(p.Exponent)}}));
    Compile("/target:exe /define:UPDATE_TESTS /main:BirdLockUpdate.Program /out:"+Q(Path.Combine(root,"Updater-test.exe"))+" /resource:"+Q(cfg)+",UpdateConfig /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll "+Q(Path.Combine(source,"Updater.cs"))+" "+Q(Path.Combine(source,"Program.cs"))+" "+Q(Path.Combine(source,"fixtures","TestTransport.cs")));
    Compile("/target:winexe /out:"+Q(Path.Combine(root,"probe.exe"))+" "+Q(Path.Combine(source,"fixtures","ProbeApp.cs")));var app=File.ReadAllBytes(Path.Combine(root,"probe.exe"));
    Run("full",app,rsa,false,false,false,false,false,false);
    Run("delta",app,rsa,true,false,false,false,false,false);
    Run("delta-fallback",app,rsa,true,true,false,false,false,false);
    Run("invalid-signature",app,rsa,false,false,true,false,false,false);
    Run("corrupt-download",app,rsa,false,false,false,true,false,false);
    Run("startup-failure",app,rsa,false,false,false,false,true,false);
    Run("startup-timeout",app,rsa,false,false,false,false,false,true);
   }
   Console.WriteLine("PASS all 7 process integration cases");Directory.Delete(root,true);return 0;
  }catch(Exception e){Console.Error.WriteLine(e);Console.Error.WriteLine("Test evidence: "+root);CleanupProcesses(root);return 1;}
 }
}
