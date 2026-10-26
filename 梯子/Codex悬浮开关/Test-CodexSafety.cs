using System;
using System.IO;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class SafetyTests {
    static int count;
    static void Assert(bool value,string reason){if(!value)throw new Exception(reason);count++;}
    public static int Main(string[] args){
        try {
            if(args.Length>0 && args[0]=="--probe"){
                var result=StaticExitChecker.Check(AppDomain.CurrentDomain.BaseDirectory);
                string text=new JavaScriptSerializer().Serialize(result);
                File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"test-state","live-network-check.json"),text);
                Console.WriteLine(text);return 0;
            }
            int asked=0,executed=0;
            Func<string,string,MessageBoxIcon,bool> cancel=(text,title,icon)=>{asked++;return false;};
            Action execute=()=>executed++;
            var good=new ExitCheckResult{Status="Static",ExpectedIp="82.26.250.63",ActualIp="82.26.250.63"};
            var other=new ExitCheckResult{Status="Other",ExpectedIp="82.26.250.63",ActualIp="142.91.98.83"};
            var unknown=new ExitCheckResult{Status="Unknown",ExpectedIp="82.26.250.63",Detail="检测超时"};
            Assert(!CodexActionGuard.TryExecute("Close",null,cancel,execute),"Cancelling close must reject shutdown");
            Assert(asked==1 && executed==0,"Close cancellation must not dispatch a shutdown worker");
            asked=0;executed=0;
            Assert(CodexActionGuard.TryExecute("Close",null,(text,title,icon)=>{asked++;return true;},execute),"Confirmed close must proceed");
            Assert(asked==1 && executed==1,"Confirmed close must dispatch exactly once");
            asked=0;executed=0;
            Assert(CodexActionGuard.TryExecute("Open",good,cancel,execute),"Verified static egress must open without a dialog");
            Assert(asked==0 && executed==1,"Static egress must not ask for an override");
            asked=0;executed=0;string warning="";
            Assert(!CodexActionGuard.TryExecute("Open",other,(text,title,icon)=>{asked++;warning=text;return false;},execute),"Cancelling a non-static opening must reject launch");
            Assert(asked==1 && executed==0,"Non-static cancellation must not dispatch an open worker");
            Assert(warning.Contains("目前不是静态 IP 出口") && warning.Contains(other.ActualIp) && warning.Contains(other.ExpectedIp),"Non-static warning must show both exit addresses");
            asked=0;executed=0;
            Assert(CodexActionGuard.TryExecute("Open",other,(text,title,icon)=>{asked++;return true;},execute),"Explicitly accepting non-static egress must open");
            Assert(asked==1 && executed==1,"Non-static override must dispatch exactly once");
            asked=0;executed=0;warning="";
            Assert(!CodexActionGuard.TryExecute("Open",unknown,(text,title,icon)=>{asked++;warning=text;return false;},execute),"An inconclusive network check must require confirmation");
            Assert(asked==1 && executed==0 && warning.Contains("未能确认") && !warning.Contains("目前不是静态"),"Unknown egress must not be reported as a confirmed non-static address");
            Assert(StaticExitChecker.ParseAddress("fl=123\nip=82.26.250.63\nloc=SG\n")=="82.26.250.63","Trace parser must extract the exit IP");
            Assert(StaticExitChecker.ParseAddress("ip=not-an-ip\n")==null,"Trace parser must reject invalid addresses");
            Assert(StaticExitChecker.ParseAddress("<html>blocked</html>")==null,"An HTML error page must not count as a successful IP check");
            Assert(StaticExitChecker.ClassifyAddress(good.ExpectedIp,good.ActualIp)=="Static","Matching observed egress must be classified as static");
            Assert(StaticExitChecker.ClassifyAddress(other.ExpectedIp,other.ActualIp)=="Other","A different observed egress must require an override");
            Assert(StaticExitChecker.ClassifyAddress(good.ExpectedIp,null)=="Unknown","A missing observed address must not count as static");
            Assert(StaticExitChecker.ClassifyAddress("invalid",good.ActualIp)=="Unknown","An invalid configured static IP must not count as verified");
            Console.WriteLine("PASS: "+count+" safety assertions; no real app was opened or closed");return 0;
        }catch(Exception error){Console.Error.WriteLine("FAIL: "+error.Message);return 1;}
    }
}
