using System;
using System.IO;
using System.Reflection;
using System.Threading;
class ProbeApp {
 static void Main(string[] args) {
  if(args.Length==2 && args[0]=="--update-health" && Environment.GetEnvironmentVariable("BIRDLOCK_QA_SKIP_HEALTH")!="1") {
   string version=File.ReadAllText(Path.Combine(Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location),"_internal","VERSION")).Trim();File.WriteAllText(args[1],version);
  }
  var until=DateTime.UtcNow.AddSeconds(90);
  while(DateTime.UtcNow<until) { if(args.Length==2 && args[0]=="--wait" && File.Exists(args[1]))return;Thread.Sleep(20); }
 }
}
