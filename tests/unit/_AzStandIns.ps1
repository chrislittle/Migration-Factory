# FACADE-PASS-SHARE-1: local stand-ins for what the real Az.Accounts module
# reaches, so a test can run the real module with no Azure and nothing sent
# outside this computer.
#
# VmfFakeIdentity answers the managed identity endpoint (IDENTITY_ENDPOINT,
# the App Service protocol) with a token, and the ARM requests of
# Connect-AzAccount -Identity -Subscription -Tenant (an environment whose
# Resource Manager is this service) with one subscription. It counts the token
# requests, and keeps the X-IDENTITY-HEADER value each one sent.
#
# VmfBlackHole is an HTTP proxy that reads the first line of each request (a
# CONNECT line names the host) and then never answers: an outbound request
# that hangs. A child process with HTTPS_PROXY and HTTP_PROXY set to it, and
# NO_PROXY=localhost,127.0.0.1, sends every request to a host outside this
# computer here, and nothing leaves it. A request to a host named in Refused
# gets 502 at once instead.
#
# Both answer from dedicated threads, never from the thread pool, so they do
# not change what the pool counts. Subscription and tenant are the placeholder
# ids (rule 13).
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.

if (-not ('VmfFakeIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class VmfFakeIdentity : IDisposable
{
    readonly TcpListener listener;
    volatile bool stopping;
    public readonly ConcurrentQueue<string> Paths = new ConcurrentQueue<string>();
    // FACADE-SIGNIN-COLD-1: the X-IDENTITY-HEADER value of each token request.
    public readonly ConcurrentQueue<string> IdentityHeaders = new ConcurrentQueue<string>();
    public string Subscription { get; private set; }
    public string Tenant { get; private set; }
    public string BaseUri { get; private set; }

    public VmfFakeIdentity(string subscription, string tenant)
    {
        Subscription = subscription; Tenant = tenant;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        BaseUri = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port + "/";
        var t = new Thread(Accept) { IsBackground = true }; t.Start();
    }

    void Accept()
    {
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { return; }
            var t = new Thread(() => Serve(c)) { IsBackground = true }; t.Start();
        }
    }

    static string ReadLine(Stream s)
    {
        var sb = new StringBuilder();
        while (true) { int b = s.ReadByte(); if (b < 0) return null; if (b == 10) return sb.ToString().TrimEnd((char)13); sb.Append((char)b); }
    }

    void Serve(TcpClient c)
    {
        try
        {
            var s = c.GetStream();
            while (!stopping)
            {
                string first = ReadLine(s);
                if (string.IsNullOrEmpty(first)) return;
                string line; int length = 0;
                while (!string.IsNullOrEmpty(line = ReadLine(s)))
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line.Substring(15).Trim());
                    if (line.StartsWith("X-IDENTITY-HEADER:", StringComparison.OrdinalIgnoreCase)) IdentityHeaders.Enqueue(line.Substring(18).Trim());
                }
                if (line == null) return;
                var body = new byte[length]; int got = 0;
                while (got < length) { int n = s.Read(body, got, length - got); if (n <= 0) return; got += n; }
                string path = first.Split(' ')[1];
                Paths.Enqueue(path);
                string answer;
                if (path.Contains("/msi/token"))
                {
                    long expires = DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds();
                    string resource = path.Contains("storage") ? "https://storage.azure.com/" : "https://management.core.windows.net/";
                    answer = "{\"access_token\":\"stand-in-token\",\"expires_on\":\"" + expires + "\",\"resource\":\"" + resource + "\",\"token_type\":\"Bearer\",\"client_id\":\"00000000-0000-0000-0000-0000000000bb\"}";
                }
                else if (path.StartsWith("/subscriptions/"))
                {
                    answer = "{\"id\":\"/subscriptions/" + Subscription + "\",\"subscriptionId\":\"" + Subscription + "\",\"tenantId\":\"" + Tenant + "\",\"displayName\":\"contoso\",\"state\":\"Enabled\"}";
                }
                else if (path.StartsWith("/tenants"))
                {
                    answer = "{\"value\":[{\"id\":\"/tenants/" + Tenant + "\",\"tenantId\":\"" + Tenant + "\"}]}";
                }
                else { answer = "{\"value\":[]}"; }
                byte[] payload = Encoding.UTF8.GetBytes(answer);
                byte[] h = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + payload.Length + "\r\n\r\n");
                s.Write(h, 0, h.Length); s.Write(payload, 0, payload.Length); s.Flush();
            }
        }
        catch { }
        finally { try { c.Close(); } catch { } }
    }

    public int TokenRequests { get { int n = 0; foreach (var p in Paths) { if (p.Contains("/msi/token")) n++; } return n; } }

    public void Dispose() { stopping = true; try { listener.Stop(); } catch { } }
}

public class VmfBlackHole : IDisposable
{
    readonly TcpListener listener;
    volatile bool stopping;
    public readonly ConcurrentQueue<string> FirstLines = new ConcurrentQueue<string>();
    public string ProxyUri { get; private set; }
    // Hosts whose requests are refused at once (502) instead of held.
    public string[] Refused = new string[0];

    public VmfBlackHole()
    {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        ProxyUri = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
        var t = new Thread(Accept) { IsBackground = true }; t.Start();
    }

    void Accept()
    {
        while (!stopping)
        {
            TcpClient c;
            try { c = listener.AcceptTcpClient(); } catch { return; }
            var t = new Thread(() => Hold(c)) { IsBackground = true }; t.Start();
        }
    }

    void Hold(TcpClient c)
    {
        try
        {
            var s = c.GetStream(); var sb = new StringBuilder();
            while (true) { int b = s.ReadByte(); if (b < 0) return; if (b == 10) break; sb.Append((char)b); }
            string first = sb.ToString().Trim();
            FirstLines.Enqueue(first);
            foreach (var host in Refused)
            {
                if (first.IndexOf(host, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    byte[] no = Encoding.ASCII.GetBytes("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    s.Write(no, 0, no.Length); s.Flush();
                    return;
                }
            }
            while (!stopping) Thread.Sleep(200);
        }
        catch { }
        finally { try { c.Close(); } catch { } }
    }

    // How many requests went to a host whose name contains this text.
    public int CountTo(string host) { int n = 0; foreach (var l in FirstLines) { if (l.IndexOf(host, StringComparison.OrdinalIgnoreCase) >= 0) n++; } return n; }

    public void Dispose() { stopping = true; try { listener.Stop(); } catch { } }
}

public static class VmfPoolSampler
{
    static volatile bool sampling;
    static int maxBusy, maxThreads;
    // Every 20 ms, from a dedicated thread: the most thread-pool threads that
    // ran work at once (the pool's maximum less its free threads), and the
    // most threads it had.
    public static void Start()
    {
        maxBusy = 0; maxThreads = 0; sampling = true;
        var t = new Thread(() =>
        {
            while (sampling)
            {
                int mw, mi, fw, fi;
                ThreadPool.GetMaxThreads(out mw, out mi); ThreadPool.GetAvailableThreads(out fw, out fi);
                int busy = mw - fw, threads = ThreadPool.ThreadCount;
                if (busy > maxBusy) maxBusy = busy;
                if (threads > maxThreads) maxThreads = threads;
                Thread.Sleep(20);
            }
        }) { IsBackground = true };
        t.Start();
    }
    public static void Stop() { sampling = false; }
    public static int MaxBusy { get { return maxBusy; } }
    public static int MaxThreads { get { return maxThreads; } }
}
'@
}
