#if UPDATE_TESTS
using System;
using System.IO;
namespace BirdLockUpdate {
public static class TestTransport {
 public static string CacheRoot;
 public static void Setup() {
  string root=Environment.GetEnvironmentVariable("BIRDLOCK_QA_FILES");if(String.IsNullOrEmpty(root))throw new Exception("Missing test fixture");
  CacheRoot=Path.Combine(root,"cache");
  Engine.Transport=(url,start)=> {
   var uri=Engine.Https(url);if(uri.Host!="fixture.invalid")throw new Exception("Unexpected test URL");
   string name=Path.GetFileName(uri.LocalPath);File.AppendAllText(Path.Combine(root,"requests.log"),name+":"+start+"\n");
   var stream=File.OpenRead(Path.Combine(root,name));stream.Seek(start,SeekOrigin.Begin);
   return new HttpReply{status=start==0?200:206,finalUrl=url,range="bytes "+start+"-"+(stream.Length-1)+"/"+stream.Length,body=stream};
  };
 }
}
}
#endif
