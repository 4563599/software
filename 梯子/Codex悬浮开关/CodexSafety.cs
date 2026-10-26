using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Cache;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal sealed class ExitCheckResult {
    public string Status {get;set;}
    public string ExpectedIp {get;set;}
    public string ActualIp {get;set;}
    public string Detail {get;set;}
    public string CheckedAt {get;set;}
}
internal static class CodexActionGuard {
    public static bool TryExecute(string action,ExitCheckResult check,Func<string,string,MessageBoxIcon,bool> confirm,Action execute){
        if(action=="Close"){
            if(!confirm("确定要彻底关闭 Codex 及其相关后台进程吗？\n\n正在执行的任务会被中断。", "确认关闭 Codex",MessageBoxIcon.Question))return false;
        }else if(action=="Open"){
            if(check==null || check.Status!="Static"){
                string text;
                if(check!=null && check.Status=="Other"){
                    text="目前不是静态 IP 出口。\n\n当前出口 IP："+check.ActualIp+"\n静态出口 IP："+check.ExpectedIp;
                }else{
                    text="未能确认当前是否为静态 IP 出口。\n\n原因："+(check==null?"未取得检测结果":check.Detail);
                    if(check!=null && !String.IsNullOrEmpty(check.ExpectedIp))text+="\n静态出口 IP："+check.ExpectedIp;
                }
                text+="\n\n是否仍要打开 Codex？";
                if(!confirm(text,"Codex 出口检查",MessageBoxIcon.Warning))return false;
            }
        }else throw new ArgumentException("Unsupported action", "action");
        execute();return true;
    }
}
internal static class StaticExitChecker {
    // Probe the OpenAI domain itself so Clash's AI rules apply to this request.
    const string TraceUrl="https://chatgpt.com/cdn-cgi/trace";
    public static ExitCheckResult Check(string root){
        var result=new ExitCheckResult{Status="Unknown",CheckedAt=DateTimeOffset.Now.ToString("o")};
        try{
            var settings=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(root,"network-settings.json"),Encoding.UTF8));
            object expected;IPAddress expectedAddress;
            if(!settings.TryGetValue("ExpectedStaticIp",out expected) || !IPAddress.TryParse(Convert.ToString(expected),out expectedAddress)){
                result.Detail="静态 IP 配置无效";return result;
            }
            result.ExpectedIp=expectedAddress.ToString();
            ServicePointManager.SecurityProtocol|=(SecurityProtocolType)3072;
            var request=(HttpWebRequest)WebRequest.Create(TraceUrl);
            request.Proxy=WebRequest.GetSystemWebProxy();
            request.Timeout=6000;request.ReadWriteTimeout=6000;request.AllowAutoRedirect=false;
            request.CachePolicy=new RequestCachePolicy(RequestCacheLevel.NoCacheNoStore);
            request.KeepAlive=false;request.UserAgent="CodexDesktopToggle/1.1";
            request.AutomaticDecompression=DecompressionMethods.GZip|DecompressionMethods.Deflate;
            using(var timeout=new System.Threading.Timer(state=>request.Abort(),null,7500,Timeout.Infinite))
            using(var response=(HttpWebResponse)request.GetResponse()){
                if(response.StatusCode!=HttpStatusCode.OK){result.Detail="出口检测返回 HTTP "+(int)response.StatusCode;return result;}
                using(var reader=new StreamReader(response.GetResponseStream(),Encoding.UTF8)){
                    var text=new StringBuilder();var buffer=new char[1024];int read;
                    while(text.Length<16384 && (read=reader.Read(buffer,0,Math.Min(buffer.Length,16384-text.Length)))>0)text.Append(buffer,0,read);
                    result.ActualIp=ParseAddress(text.ToString());
                }
            }
            if(result.ActualIp==null){result.Detail="检测服务没有返回有效的出口 IP";return result;}
            result.Status=ClassifyAddress(result.ExpectedIp,result.ActualIp);
            result.Detail=result.Status=="Static"?"出口 IP 与静态 IP 一致":"出口 IP 与静态 IP 不同";
        }catch(WebException error){
            var response=error.Response as HttpWebResponse;
            if(response!=null){result.Detail="出口检测返回 HTTP "+(int)response.StatusCode;response.Dispose();}
            else if(error.Status==WebExceptionStatus.Timeout || error.Status==WebExceptionStatus.RequestCanceled)result.Detail="出口检测超时";
            else result.Detail="无法连接出口检测服务";
        }catch(IOException){result.Detail="无法读取网络检测配置或响应";}
        catch(Exception){result.Detail="出口检测未能完成";}
        return result;
    }
    public static string ParseAddress(string text){
        using(var reader=new StringReader(text??"")){
            string line;IPAddress address;
            while((line=reader.ReadLine())!=null)if(line.StartsWith("ip=",StringComparison.Ordinal) && IPAddress.TryParse(line.Substring(3).Trim(),out address))return address.ToString();
        }
        return null;
    }
    public static string ClassifyAddress(string expected,string actual){
        IPAddress left,right;
        if(!IPAddress.TryParse(expected,out left) || !IPAddress.TryParse(actual,out right))return "Unknown";
        return left.Equals(right)?"Static":"Other";
    }
}
