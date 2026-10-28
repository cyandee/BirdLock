// Standalone .NET Framework updater. No Python runtime, administrator escalation or shell commands.
using System;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Web.Script.Serialization;
using System.Threading;

namespace BirdLockUpdate {
public class FileSpec { public long size; public string sha256; }
public class Package : FileSpec { public string url; public string prefix = ""; public string from; public string[] mirrors; }
public class Manifest { public int schema; public string version; public string channel; public string notes; public Dictionary<string,FileSpec> files; public Package full; public Package delta; }
public class Envelope { public string payload; public string signature; }
public class WindowsConfig { public string feed_url; public string stable_feed_url; public string rsa_modulus; public string rsa_exponent; }
public class Config { public WindowsConfig windows; }
public sealed class HttpReply : IDisposable {
    public int status; public string finalUrl; public string range; public Stream body; public Action close;
    public void Dispose(){if(body!=null)body.Dispose();if(close!=null)close();}
}
public static class Engine {
    public static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 8000000, RecursionLimit = 32 };
    public static Action<string,int> Progress = delegate {};
    public static bool Cancelled;
    public static Func<string,long,HttpReply> Transport=Network;
    public static Func<string,long> FreeSpace=path=>new DriveInfo(Path.GetPathRoot(path)).AvailableFreeSpace;
    public static string Hash(Stream stream) { using(var h=SHA256.Create()) return BitConverter.ToString(h.ComputeHash(stream)).Replace("-", "").ToLowerInvariant(); }
    public static bool Matches(string path, FileSpec spec) {
        if(!File.Exists(path) || new FileInfo(path).Length!=spec.size) return false;
        using(var f=File.OpenRead(path)) return Hash(f)==spec.sha256;
    }
    public static Uri Https(string value) {
        Uri u;
        if(!Uri.TryCreate(value,UriKind.Absolute,out u) || u.Scheme!="https" || !String.IsNullOrEmpty(u.UserInfo) || !String.IsNullOrEmpty(u.Fragment)) throw new Exception("更新地址必须使用 HTTPS");
        return u;
    }
    public static void ValidatePath(string name) {
        if(String.IsNullOrEmpty(name) || name.Any(c=>c<32) || name.Length>220 || name.Contains("\\") || name.StartsWith("/") || name.IndexOfAny(new[]{':','\0','*','?','"','<','>','|'})>=0) throw new Exception("更新文件路径无效");
        foreach(var part in name.Split('/')) {
            string stem=part.Split('.')[0].ToUpperInvariant();
            if(part.Length==0 || part=="." || part==".." || part.EndsWith(".") || part.EndsWith(" ") || new[]{"CON","PRN","AUX","NUL"}.Contains(stem) || System.Text.RegularExpressions.Regex.IsMatch(stem,@"^(COM|LPT)[0-9]$")) throw new Exception("更新文件路径无效");
        }
        if(name.Split('/')[0].Equals("data",StringComparison.OrdinalIgnoreCase)) throw new Exception("更新包不能覆盖用户数据");
    }
    public static Manifest Verify(byte[] bytes, WindowsConfig config) {
        if(bytes.Length>8000000) throw new Exception("更新清单过大");
        var envelope=Json.Deserialize<Envelope>(Encoding.UTF8.GetString(bytes));
        var payload=Convert.FromBase64String(envelope.payload);var signature=Convert.FromBase64String(envelope.signature);
        using(var rsa=new RSACryptoServiceProvider(new CspParameters(24))) {
            rsa.PersistKeyInCsp=false;
            rsa.ImportParameters(new RSAParameters{Modulus=Convert.FromBase64String(config.rsa_modulus),Exponent=Convert.FromBase64String(config.rsa_exponent)});
            if(rsa.KeySize<2048 || !rsa.VerifyData(payload,CryptoConfig.MapNameToOID("SHA256"),signature)) throw new Exception("更新签名无效，已停止更新");
        }
        var m=Json.Deserialize<Manifest>(Encoding.UTF8.GetString(payload));
        if(m.schema!=1 || m.files==null || m.files.Count==0 || m.files.Count>20000 || m.full==null) throw new Exception("不支持的更新清单");
        ParseVersion(m.version);
        if(m.channel!="stable" && m.channel!="beta") throw new Exception("未知更新通道");
        var paths=new HashSet<string>(StringComparer.OrdinalIgnoreCase);long total=0;
        foreach(var f in m.files) {
            ValidatePath(f.Key);ValidateSpec(f.Value);
            if(!paths.Add(f.Key)) throw new Exception("更新路径重复");
            total=checked(total+f.Value.size);
        }
        if(total>8L*1024*1024*1024 || !m.files.ContainsKey("BirdLock.exe")) throw new Exception("更新清单不完整或过大");
        foreach(var path in paths) { var parent=path; while(parent.Contains("/")) { parent=parent.Substring(0,parent.LastIndexOf('/')); if(paths.Contains(parent)) throw new Exception("文件与目录冲突"); } }
        ValidatePackage(m.full);if(m.delta!=null) { ValidatePackage(m.delta);ParseVersion(m.delta.from); }
        return m;
    }
    static void ValidateSpec(FileSpec p) {
        if(p==null || p.size<0 || p.size>4L*1024*1024*1024 || !System.Text.RegularExpressions.Regex.IsMatch(p.sha256??"", "^[0-9a-f]{64}$")) throw new Exception("文件校验信息无效");
    }
    static void ValidatePackage(Package p) { ValidateSpec(p);if(p.size==0)throw new Exception("更新包为空");Https(p.url);if(p.mirrors!=null) { if(p.mirrors.Length>3)throw new Exception("备用源过多");foreach(var u in p.mirrors)Https(u); }if(p.prefix!="" && p.prefix!="BirdLock/") throw new Exception("压缩包前缀无效"); }
    static Version ParseVersion(string value) {
        if(!System.Text.RegularExpressions.Regex.IsMatch(value??"", @"^\d+\.\d+\.\d+$")) throw new Exception("版本号无效");
        return new Version(value);
    }
    public static bool Newer(Manifest m,string current,bool beta) { return (beta || m.channel=="stable") && ParseVersion(m.version)>ParseVersion(current); }
    static HttpWebRequest Request(string url) {
        Https(url);var q=(HttpWebRequest)WebRequest.Create(url);q.UserAgent="BirdLock-Updater/1";q.Timeout=30000;q.ReadWriteTimeout=30000;q.AutomaticDecompression=DecompressionMethods.None;q.AllowAutoRedirect=false;return q;
    }
    static HttpReply Network(string url,long start) {
        for(int redirect=0;redirect<6;redirect++) {
            var q=Request(url);if(start>0)q.AddRange(start);
            var r=(HttpWebResponse)q.GetResponse();int status=(int)r.StatusCode;
            if(status==301 || status==302 || status==303 || status==307 || status==308) {
                string next=new Uri(new Uri(url),r.Headers["Location"]).AbsoluteUri;r.Dispose();Https(next);url=next;continue;
            }
            return new HttpReply {status=status,finalUrl=r.ResponseUri.AbsoluteUri,range=r.Headers["Content-Range"],body=r.GetResponseStream(),close=()=>r.Dispose()};
        }
        throw new Exception("下载重定向过多");
    }
    public static byte[] Fetch(string url) {
        Https(url);
        using(var r=Transport(url,0)) {
            Https(r.finalUrl);if(r.status!=200)throw new Exception("更新清单响应无效");
            using(var b=new MemoryStream()) {
                var buffer=new byte[65536];int n;
                while((n=r.body.Read(buffer,0,buffer.Length))>0) {if(b.Length+n>8000000)throw new Exception("更新清单过大");b.Write(buffer,0,n);}
                return b.ToArray();
            }
        }
    }
    public static string Download(Package package,string cache) {
        string original=package.url;
        var urls=new List<string>{original};if(package.mirrors!=null)urls.AddRange(package.mirrors);
        try {
            for(int i=0;i<urls.Count;i++) { package.url=urls[i];try { return DownloadOne(package,cache); } catch(OperationCanceledException){throw;} catch {if(i==urls.Count-1)throw;} }
            throw new Exception("所有下载源均失败");
        } finally {package.url=original;}
    }
    static string DownloadOne(Package package,string cache) {
        Directory.CreateDirectory(cache);string path=Path.Combine(cache,package.sha256+".zip"),partial=path+".part";
        if(Matches(path,package)) return path;
        for(int attempt=0;attempt<3;attempt++) {
            if(Cancelled) throw new OperationCanceledException();
            long start=File.Exists(partial)?new FileInfo(partial).Length:0;
            if(start>=package.size) { if(start==package.size && Matches(partial,package)) { if(File.Exists(path)) File.Delete(path);File.Move(partial,path);return path; } File.Delete(partial);start=0; }
            try {
                Https(package.url);
                using(var response=Transport(package.url,start)) {
                    Https(response.finalUrl);
                    if(response.status==206) {
                        var range=response.range??"";
                        if(!range.StartsWith("bytes "+start+"-",StringComparison.Ordinal) || !range.EndsWith("/"+package.size,StringComparison.Ordinal)) throw new Exception("下载续传范围不匹配");
                    } else { if(response.status!=200)throw new Exception("下载响应无效");start=0; }
                    using(var src=response.body) using(var dst=new FileStream(partial,start==0?FileMode.Create:FileMode.Append,FileAccess.Write,FileShare.None)) {
                        byte[] buffer=new byte[131072];int n;long count=start;
                        while((n=src.Read(buffer,0,buffer.Length))>0) {
                            if(Cancelled)throw new OperationCanceledException();count+=n;if(count>package.size)throw new Exception("下载大小超出清单");
                            dst.Write(buffer,0,n);Progress("正在下载更新",(int)(count*100/Math.Max(1,package.size)));
                        }
                    }
                }
                if(Cancelled)throw new OperationCanceledException();
                if(!Matches(partial,package)) { File.Delete(partial);throw new Exception("下载校验失败"); }
                if(File.Exists(path))File.Delete(path);File.Move(partial,path);return path;
            } catch(Exception e) { if(!(e is WebException || e is IOException) || attempt==2)throw;Thread.Sleep(1000); }
        }
        throw new Exception("下载失败");
    }
    public static void Stage(Manifest manifest,Package package,string archive,string current,string stage) {
        Directory.CreateDirectory(stage);var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using(var z=ZipFile.OpenRead(archive)) {
            foreach(var entry in z.Entries) {
                if(entry.FullName.EndsWith("/"))continue;
                if(!entry.FullName.StartsWith(package.prefix,StringComparison.Ordinal))throw new Exception("压缩包前缀不匹配");
                string name=entry.FullName.Substring(package.prefix.Length);ValidatePath(name);
                FileSpec spec;
                if(!manifest.files.TryGetValue(name,out spec) || !seen.Add(name) || entry.Length!=spec.size || ((entry.ExternalAttributes>>16)&0xF000)==0xA000) throw new Exception("压缩包文件与签名清单不符");
                string dest=Path.Combine(stage,name.Replace('/',Path.DirectorySeparatorChar));Directory.CreateDirectory(Path.GetDirectoryName(dest));
                using(var src=entry.Open())using(var dst=new FileStream(dest,FileMode.CreateNew)) {
                    byte[] buffer=new byte[131072];int n;long copied=0;
                    while((n=src.Read(buffer,0,buffer.Length))>0) { if(Cancelled)throw new OperationCanceledException();Progress("正在校验更新文件",0);copied+=n;if(copied>spec.size)throw new Exception("解压大小超出清单");dst.Write(buffer,0,n); }
                }
                if(!Matches(dest,spec))throw new Exception("更新文件校验失败");
            }
        }
        foreach(var file in manifest.files) {
            if(seen.Contains(file.Key))continue;
            string old=Path.Combine(current,file.Key.Replace('/',Path.DirectorySeparatorChar));
            if(package.from==null || !Matches(old,file.Value))throw new Exception("增量基础不匹配，需要完整更新");
            string dest=Path.Combine(stage,file.Key.Replace('/',Path.DirectorySeparatorChar));Directory.CreateDirectory(Path.GetDirectoryName(dest));File.Copy(old,dest);
        }
    }
    public static string Prepare(Manifest m,string currentVersion,string target,string cache) {
        string stage=target+".update-"+Guid.NewGuid().ToString("N");
        long needed=m.files.Values.Sum(f=>f.size)+m.full.size+256L*1024*1024;
        if(FreeSpace(target)<needed)throw new Exception("磁盘空间不足");
        try {
            if(m.delta!=null && m.delta.from==currentVersion) {
                try { Stage(m,m.delta,Download(m.delta,cache),target,stage);return stage; }
                catch(OperationCanceledException) { throw; }
                catch { if(Directory.Exists(stage))Directory.Delete(stage,true);Progress("增量不可用，改用完整更新",0); }
            }
            Stage(m,m.full,Download(m.full,cache),target,stage);return stage;
        } catch { if(Directory.Exists(stage))Directory.Delete(stage,true);throw; }
    }
    public sealed class SwapResult { public string backup; public List<string> preserved=new List<string>(); }
    static IEnumerable<string> SafeFiles(string root,bool top=true) {
        foreach(var path in Directory.GetFileSystemEntries(root)) {
            if((File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)throw new Exception("程序目录含链接，请手动更新");
            if(Directory.Exists(path)) { if(top && Path.GetFileName(path).Equals("data",StringComparison.OrdinalIgnoreCase))continue;foreach(var f in SafeFiles(path,false))yield return f; }
            else yield return path;
        }
    }
    static void MoveItem(string source,string dest) {
        Directory.CreateDirectory(Path.GetDirectoryName(dest));
        if(Directory.Exists(source))Directory.Move(source,dest);else File.Move(source,dest);
    }
    public static SwapResult Swap(string target,string stage) {
        var result=new SwapResult {backup=target+".previous-"+Guid.NewGuid().ToString("N")};
        string catalog=Path.Combine(target,"_internal","updates","managed-files.json");
        if(!File.Exists(catalog))throw new Exception("当前版本缺少更新文件清单，请先手动安装一次新版");
        var managed=new HashSet<string>(Json.Deserialize<string[]>(File.ReadAllText(catalog)),StringComparer.OrdinalIgnoreCase);
        foreach(var name in managed)ValidatePath(name);
        var extras=SafeFiles(target).Select(f=>f.Substring(target.Length+1).Replace('\\','/')).Where(n=>!managed.Contains(n)).ToList();
        foreach(var n in extras) { ValidatePath(n);if(File.Exists(Path.Combine(stage,n)) || Directory.Exists(Path.Combine(stage,n)))throw new Exception("更新文件与用户文件冲突，请手动处理"); }
        if(Directory.Exists(Path.Combine(target,"data")))extras.Add("data");
        Directory.Move(target,result.backup);
        try {
            Directory.Move(stage,target);
            foreach(var n in extras) {MoveItem(Path.Combine(result.backup,n),Path.Combine(target,n));result.preserved.Add(n);}
            return result;
        } catch {
            foreach(var n in result.preserved.AsEnumerable().Reverse())MoveItem(Path.Combine(target,n),Path.Combine(result.backup,n));
            if(Directory.Exists(target))Directory.Move(target,stage);Directory.Move(result.backup,target);throw;
        }
    }
    public static void Rollback(string target,SwapResult result) {
        string failed=target+".failed-"+Guid.NewGuid().ToString("N");
        foreach(var n in result.preserved.AsEnumerable().Reverse())MoveItem(Path.Combine(target,n),Path.Combine(result.backup,n));
        Directory.Move(target,failed);Directory.Move(result.backup,target);
    }

}
}
