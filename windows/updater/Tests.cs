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
   p.mirrors=new[]{"https://good.test/archive.zip"};var poisoned=new List<string>();
   Engine.Transport=(u,start)=>{poisoned.Add(u+":"+start);if(u.Contains("example.test"))return new HttpReply{status=200,finalUrl=u,body=new MemoryStream(new byte[bytes.Length+10])};return Reply(bytes,start,u);};
   result=Engine.Download(p,Path.Combine(root,"poisoned"));
   Assert(Engine.Matches(result,p)&&poisoned.Last()=="https://good.test/archive.zip:0","bytes from a failed source are not resumed by the next");
   Engine.FreeSpace=path=>1;Reject(()=>Engine.Prepare(Fixture(),"1.0.0",Path.Combine(root,"low-disk"),Path.Combine(root,"cache")),"disk space check");Assert(!Directory.Exists(Path.Combine(root,"low-disk")),"low disk leaves app unchanged");
  } finally {Engine.Transport=network;Engine.Progress=progress;Engine.FreeSpace=free;Engine.Cancelled=false;}
 }

 static void SourceTests(RSACryptoServiceProvider rsa,WindowsConfig cfg) {
  var network=Engine.Transport;
  try {
   const string prefix="https://github.com/cyandee/BirdLock/releases/download/";
   cfg.feed_url="https://raw.example.test/updates/windows.json";cfg.stable_feed_url="https://raw.example.test/updates/windows-stable.json";
   var config=new Config{windows=cfg,release_download_prefix=prefix,sources=new[]{new Source{id="github",name="GitHub"},new Source{name="镜像",url="https://mirror.test/birdlock/update-api"}}};
   var defaults=Engine.Sources(config,null);
   Assert(defaults.Count==2 && defaults[0].id=="github" && defaults[1].url=="https://mirror.test/birdlock/update-api/" && defaults[1].name=="镜像","default sources keep order and normalize base");
   var custom=Engine.Sources(config,new[]{"https://other.test/u/","github","https://other.test/u"});
   Assert(custom.Count==2 && custom[0].url=="https://other.test/u/" && custom[0].name=="other.test" && custom[1].id=="github","requested order overrides defaults and removes duplicates");
   Assert(Engine.Sources(new Config{windows=cfg},null).Single().id=="github","missing source list falls back to GitHub");
   foreach(var bad in new[]{"http://mirror.test/","https://user:pw@mirror.test/","https://mirror.test/?a=1","https://mirror.test/#a","ftp://mirror.test/","","https://mirror:8o8o/","https://exa mple.test/"}) {
    Reject(()=>Engine.SourceBase(bad),"source "+bad);
    var kept=Engine.Sources(config,new[]{bad,"https://good.test/","github"});
    Assert(kept.Count==2 && kept[0].url=="https://good.test/" && kept[1].id=="github","invalid source skipped: "+bad);
    Assert(Engine.Sources(config,new[]{bad}).Single().id=="github","only invalid sources fall back to GitHub: "+bad);
   }
   Reject(()=>Engine.Sources(config,Enumerable.Range(0,11).Select(i=>"https://m"+i+".test/").ToList()),"too many sources");
   var github=defaults[0];var mirror=defaults[1];
   Assert(Engine.FeedUrl(github,cfg,true)==cfg.feed_url && Engine.FeedUrl(github,cfg,false)==cfg.stable_feed_url,"GitHub feeds come from config");
   Assert(Engine.FeedUrl(mirror,cfg,true)=="https://mirror.test/birdlock/update-api/windows.json" && Engine.FeedUrl(mirror,cfg,false)=="https://mirror.test/birdlock/update-api/windows-stable.json","source feeds follow the shared layout");
   Assert(Engine.AssetUrl(mirror,prefix+"v1.5.0-beta.1/BirdLock-1.5.0-Windows-update.zip",prefix)=="https://mirror.test/birdlock/update-api/download/v1.5.0-beta.1/BirdLock-1.5.0-Windows-update.zip","assets keep the release tag");
   Assert(Engine.AssetUrl(mirror,"https://elsewhere.test/a.zip",prefix)==null && Engine.AssetUrl(github,"https://elsewhere.test/a.zip",prefix)=="https://elsewhere.test/a.zip","only release URLs are rewritten");
   var m=Fixture();m.channel="stable";m.full.url=prefix+"v1.10.0/full.zip";m.full.mirrors=new[]{"https://signed.test/full.zip"};m.delta=new Package{url=prefix+"v1.10.0/delta.zip",from="1.9.0",sha256=new string('b',64),size=1};
   var signed=Sign(m,rsa);var requests=new List<string>();
   Engine.Transport=(u,start)=>{requests.Add(u);if(u.Contains("raw.example.test"))throw new System.Net.WebException("blocked");return new HttpReply{status=200,finalUrl=u,body=new MemoryStream(signed)};};
   Source used;var got=Engine.FetchFirst(defaults,cfg,false,out used);
   Assert(used==mirror && got.version==m.version && requests.SequenceEqual(new[]{cfg.stable_feed_url,"https://mirror.test/birdlock/update-api/windows-stable.json"}),"unreachable GitHub falls back to the next source");
   var tampered=Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(signed).Replace("\"signature\":\"","\"signature\":\"AA"));
   Engine.Transport=(u,start)=>new HttpReply{status=200,finalUrl=u,body=new MemoryStream(u.Contains("raw.example.test")?tampered:signed)};
   Engine.FetchFirst(defaults,cfg,true,out used);Assert(used==mirror,"invalid signature on one source tries the next");
   Engine.Transport=(u,start)=>{throw new System.Net.WebException("offline");};
   try{Engine.FetchFirst(defaults,cfg,true,out used);throw new Exception("FAILED: all sources offline");}catch(Exception e){Assert(e.Message.Contains("GitHub")&&e.Message.Contains("镜像"),"all-source failure names every source");}
   Engine.Route(got,new[]{mirror,github},prefix);
   Assert(got.full.url=="https://mirror.test/birdlock/update-api/download/v1.10.0/full.zip" && got.full.mirrors.SequenceEqual(new[]{prefix+"v1.10.0/full.zip","https://signed.test/full.zip"}),"packages follow the serving source, then other sources, then signed mirrors");
   Assert(got.delta.url=="https://mirror.test/birdlock/update-api/download/v1.10.0/delta.zip" && got.delta.mirrors.Single()==prefix+"v1.10.0/delta.zip","delta routing");
   var only=Engine.Verify(signed,cfg);Engine.Route(only,new[]{mirror},prefix);Assert(only.full.url.StartsWith("https://mirror.test/") && only.full.mirrors.Single()=="https://signed.test/full.zip","removed GitHub source is not contacted");
  } finally {Engine.Transport=network;}
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
    SourceTests(rsa,cfg);
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
