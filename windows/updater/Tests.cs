using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.IO.Compression;
namespace BirdLockUpdate {
public static class Tests {
 static int count;
 static WindowsConfig JsonConfig(string path){return Engine.Json.Deserialize<Config>(File.ReadAllText(path)).windows;}
 sealed class Interrupted : MemoryStream {
  bool first=true;public Interrupted(byte[] b):base(b){}
  public override int Read(byte[] b,int offset,int n){if(!first)throw new IOException("network interruption");first=false;return base.Read(b,offset,Math.Min(5,n));}
 }
 static HttpReply Reply(byte[] b,long start,string url){return new HttpReply{status=start==0?200:206,finalUrl=url,range="bytes "+start+"-"+(b.Length-1)+"/"+b.Length,body=new MemoryStream(b.Skip((int)start).ToArray())};}
 static void DownloadTests(string root) {
  var network=Engine.Transport;var progress=Engine.Progress;var free=Engine.FreeSpace;
  try {
   byte[] bytes=Encoding.UTF8.GetBytes("a resumable update archive with a known hash");var spec=Spec(bytes);
   var p=new Package{url="https://example.test/archive.zip",size=spec.size,sha256=spec.sha256};var starts=new List<long>();
   Engine.Transport=(u,start)=>{starts.Add(start);if(starts.Count==1)return new HttpReply{status=200,finalUrl=u,body=new Interrupted(bytes)};return Reply(bytes,start,u);};
   var result=Engine.Download(p,Path.Combine(root,"resume"));Assert(Engine.Matches(result,p),"resumed hash");Assert(starts.SequenceEqual(new long[]{0,5}),"resume Range offset");
   string cache=Path.Combine(root,"ignore-range");Directory.CreateDirectory(cache);File.WriteAllBytes(Path.Combine(cache,p.sha256+".zip.part"),bytes.Take(5).ToArray());
   Engine.Transport=(u,start)=>Reply(bytes,0,u);result=Engine.Download(p,cache);Assert(Engine.Matches(result,p),"server ignored Range resets download");
   cache=Path.Combine(root,"bad-range");Directory.CreateDirectory(cache);File.WriteAllBytes(Path.Combine(cache,p.sha256+".zip.part"),bytes.Take(5).ToArray());
   Engine.Transport=(u,start)=>Reply(bytes,2,u);Reject(()=>Engine.Download(p,cache),"wrong Content-Range");
   Engine.Transport=(u,start)=>Reply(new byte[bytes.Length],0,u);Reject(()=>Engine.Download(p,Path.Combine(root,"tampered-download")),"tampered package");
   Engine.Transport=(u,start)=>Reply(bytes,start,"http://example.test/a");Reject(()=>Engine.Download(p,Path.Combine(root,"downgraded-response")),"non-HTTPS response");
   Engine.Transport=(u,start)=>Reply(bytes,start,u);Engine.Progress=(m,n)=>Engine.Cancelled=true;
   Reject(()=>Engine.Download(p,Path.Combine(root,"cancel")),"cancel download");Assert(!File.Exists(Path.Combine(root,"cancel",p.sha256+".zip")),"cancel leaves no accepted package");Engine.Cancelled=false;Engine.Progress=progress;
   p.mirrors=new[]{"https://mirror.test/archive.zip"};int attempts=0;
   Engine.Transport=(u,start)=>{attempts++;if(u.Contains("example.test"))throw new System.Net.WebException("offline");return Reply(bytes,start,u);};
   result=Engine.Download(p,Path.Combine(root,"mirror"));Assert(Engine.Matches(result,p)&&attempts==4,"mirror fallback with same hash");
   Engine.FreeSpace=path=>1;Reject(()=>Engine.Prepare(Fixture(),"1.0.0",Path.Combine(root,"low-disk"),Path.Combine(root,"cache")),"disk space check");Assert(!Directory.Exists(Path.Combine(root,"low-disk")),"low disk leaves app unchanged");
  } finally {Engine.Transport=network;Engine.Progress=progress;Engine.FreeSpace=free;Engine.Cancelled=false;}
 }

 static void Assert(bool ok,string name){if(!ok)throw new Exception("FAILED: "+name);count++;}
 static void Reject(Action action,string name){try{action();}catch{count++;return;}throw new Exception("Accepted invalid input: "+name);}
 static string Sha(byte[] b){using(var s=new MemoryStream(b))return Engine.Hash(s);}
 static FileSpec Spec(byte[] b){return new FileSpec{size=b.Length,sha256=Sha(b)};}
 static void Put(string root,string name,string value){string p=Path.Combine(root,name);Directory.CreateDirectory(Path.GetDirectoryName(p));File.WriteAllText(p,value);}
 static byte[] Sign(Manifest m,RSACryptoServiceProvider rsa){var b=Encoding.UTF8.GetBytes(Engine.Json.Serialize(m));return Encoding.UTF8.GetBytes(Engine.Json.Serialize(new Envelope{payload=Convert.ToBase64String(b),signature=Convert.ToBase64String(rsa.SignData(b,CryptoConfig.MapNameToOID("SHA256")))}));}
 static Manifest Fixture(){return new Manifest{schema=1,version="1.10.0",channel="beta",files=new Dictionary<string,FileSpec>{{"BirdLock.exe",Spec(Encoding.UTF8.GetBytes("new"))},{"unchanged.dll",Spec(Encoding.UTF8.GetBytes("same"))}},full=new Package{url="https://example.test/full.zip",sha256=new string('a',64),size=1}};}
 public static int Main(string[] args){
  string root=Path.Combine(Path.GetTempPath(),"BirdLockUpdateTests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
  try {
   using(var rsa=new RSACryptoServiceProvider(2048,new CspParameters(24))){rsa.PersistKeyInCsp=false;var key=rsa.ExportParameters(false);var cfg=new WindowsConfig{rsa_modulus=Convert.ToBase64String(key.Modulus),rsa_exponent=Convert.ToBase64String(key.Exponent)};var m=Fixture();var signed=Sign(m,rsa);Assert(Engine.Verify(signed,cfg).version==m.version,"valid signature");
    var env=Engine.Json.Deserialize<Envelope>(Encoding.UTF8.GetString(signed));env.payload=Convert.ToBase64String(Encoding.UTF8.GetBytes("{}"));Reject(()=>Engine.Verify(Encoding.UTF8.GetBytes(Engine.Json.Serialize(env)),cfg),"tampered payload");
    Assert(Engine.Newer(m,"1.9.0",true),"numeric versions");Assert(!Engine.Newer(m,"1.9.0",false),"beta opt-out");Assert(!Engine.Newer(m,"1.10.0",true),"same version");Assert(!Engine.Newer(m,"2.0.0",true),"downgrade");
    foreach(var n in new[]{"../bad","a/../../bad","/absolute","a\\bad","a:bad","a//b","CON.txt","a./b","data/settings.json","a/LPT1"})Reject(()=>Engine.ValidatePath(n),n);
    m.files.Add("birdlock.EXE",Spec(new byte[0]));Reject(()=>Engine.Verify(Sign(m,rsa),cfg),"case collision");m.files.Remove("birdlock.EXE");
    m.full.url="http://example.test/a";Reject(()=>Engine.Verify(Sign(m,rsa),cfg),"insecure URL");m.full.url="https://example.test/full.zip";
   }
   string old=Path.Combine(root,"old"),stage=Path.Combine(root,"stage");Directory.CreateDirectory(old);
   Put(old,"unchanged.dll","same");string zip=Path.Combine(root,"delta.zip");using(var z=ZipFile.Open(zip,ZipArchiveMode.Create)){var e=z.CreateEntry("BirdLock.exe");using(var w=new StreamWriter(e.Open(),new UTF8Encoding(false)))w.Write("new");}
   var manifest=Fixture();var package=new Package{from="1.9.0",prefix="",size=new FileInfo(zip).Length,sha256=""};using(var f=File.OpenRead(zip))package.sha256=Engine.Hash(f);
   Engine.Stage(manifest,package,zip,old,stage);Assert(File.ReadAllText(Path.Combine(stage,"unchanged.dll"))=="same","delta reuse");Assert(File.ReadAllText(Path.Combine(stage,"BirdLock.exe"))=="new","delta replacement");
   Put(old,"unchanged.dll","modified");Reject(()=>Engine.Stage(manifest,package,zip,old,Path.Combine(root,"invalid-stage")),"changed delta base");
   string target=Path.Combine(root,"BirdLock"),candidate=Path.Combine(root,"candidate");
   Put(target,"BirdLock.exe","old");Put(target,"_internal/obsolete.dll","old-dll");Put(target,"data/settings.json","settings");Put(target,"photos/nested/data/photo.jpg","original");
   Put(target,"_internal/updates/managed-files.json",Engine.Json.Serialize(new[]{"BirdLock.exe","_internal/obsolete.dll","_internal/updates/managed-files.json"}));Put(candidate,"BirdLock.exe","new");
   var backup=Engine.Swap(target,candidate);Assert(File.ReadAllText(Path.Combine(target,"BirdLock.exe"))=="new","swap app");Assert(File.ReadAllText(Path.Combine(target,"data/settings.json"))=="settings","portable data preserved");Assert(File.ReadAllText(Path.Combine(target,"photos/nested/data/photo.jpg"))=="original","user originals stay at same path");Assert(!File.Exists(Path.Combine(target,"_internal/obsolete.dll")),"obsolete runtime removed");
   Engine.Rollback(target,backup);Assert(File.ReadAllText(Path.Combine(target,"BirdLock.exe"))=="old","rollback executable");Assert(File.ReadAllText(Path.Combine(target,"data/settings.json"))=="settings","rollback data");Assert(File.ReadAllText(Path.Combine(target,"photos/nested/data/photo.jpg"))=="original","rollback originals");
   Reject(()=>Engine.Swap(target,Path.Combine(root,"missing-stage")),"failed swap");Assert(File.ReadAllText(Path.Combine(target,"BirdLock.exe"))=="old","failed swap restores old app");
   DownloadTests(root);
   if(args.Length==2) {
       var cfg=JsonConfig(args[1]);var bytes=File.ReadAllBytes(args[0]);
       Assert(Engine.Verify(bytes,cfg).notes=="本机签名与跨语言验证","Python RSA signature and UTF8 payload");
   }
   Console.WriteLine("PASS "+count+" updater assertions");return 0;
  } finally {Directory.Delete(root,true);}
 }
}
}
