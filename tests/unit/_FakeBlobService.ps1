# PERF-RUNS-LIST-1: a small blob service on this computer, for tests of the
# store reads that go over HTTP at the same time.
#
# Every other store test fakes ONE seam, Invoke-VmfStorageRequest, which sends
# one request and waits for it. The run list sends several requests at once
# (Invoke-VmfStorageGetMany), and what must be proved there - how many are in
# flight, that each answer goes back to the request that asked, that a "try
# later" answer is tried again - is a property of real requests on a real
# socket. A mock that answers at once cannot show any of it.
#
# The service serves the files of one folder as the blobs of a container
# (GET <container>/<path>), answers a container listing (comp=list, with
# prefix and delimiter) in Azure's XML shape, waits LatencyMs before each
# answer, and counts the requests and the largest number in flight.
# FailFirst makes the next N reads of one blob answer 503, and RequireToken
# answers 403 to a request without that Authorization header.
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.

if (-not ('VmfFakeBlobService' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public class VmfFakeBlobService : IDisposable
{
    readonly HttpListener listener = new HttpListener();
    readonly object gate = new object();
    int inFlight;
    public string Root { get; private set; }
    public string BaseUri { get; private set; }
    public int LatencyMs { get; set; }
    // STORE-REQUEST-TIMEOUT-1: when above 0, a found blob's answer sends its
    // headers and first byte at once, then each further byte after this wait,
    // so a body takes (length - 1) x TrickleMs to arrive.
    public int TrickleMs { get; set; }
    public string RequireToken { get; set; }
    public int MaxInFlight { get; private set; }
    public int Requests;
    public ConcurrentQueue<string> Log = new ConcurrentQueue<string>();
    public ConcurrentDictionary<string, int> FailFirst = new ConcurrentDictionary<string, int>();
    // PAGE-LOAD-FREEZE-1: one key for each TCP connection a client opened
    // (its address and port), and each request as it arrived, so a test can
    // count the connections and read what was sent.
    public ConcurrentDictionary<string, int> Connections = new ConcurrentDictionary<string, int>();
    public ConcurrentQueue<VmfFakeBlobRequest> Captured = new ConcurrentQueue<VmfFakeBlobRequest>();

    public VmfFakeBlobService(string root, int latencyMs)
    {
        Root = root;
        LatencyMs = latencyMs;
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        BaseUri = "http://localhost:" + port + "/";
        listener.Prefixes.Add(BaseUri);
        listener.Start();
        Task.Run(Loop);
    }

    public void ResetCounts()
    {
        lock (gate) { MaxInFlight = 0; Requests = 0; }
        string ignored;
        while (Log.TryDequeue(out ignored)) { }
        Connections.Clear();
        VmfFakeBlobRequest dropped;
        while (Captured.TryDequeue(out dropped)) { }
    }

    async Task Loop()
    {
        while (listener.IsListening)
        {
            HttpListenerContext c;
            try { c = await listener.GetContextAsync(); }
            catch { return; }
            var ignored = Task.Run(() => Handle(c));
        }
    }

    async Task Handle(HttpListenerContext c)
    {
        int now = Interlocked.Increment(ref inFlight);
        Interlocked.Increment(ref Requests);
        Connections.AddOrUpdate(c.Request.RemoteEndPoint.ToString(), 1, (k, v) => v + 1);
        var seen = new VmfFakeBlobRequest { Method = c.Request.HttpMethod, PathAndQuery = c.Request.Url.PathAndQuery };
        foreach (string k in c.Request.Headers.AllKeys) { seen.Headers[k] = c.Request.Headers[k]; }
        if (c.Request.HasEntityBody)
        {
            using (var ms = new MemoryStream()) { c.Request.InputStream.CopyTo(ms); seen.Body = ms.ToArray(); }
        }
        Captured.Enqueue(seen);
        lock (gate) { if (now > MaxInFlight) { MaxInFlight = now; } }
        // A request stops counting BEFORE its answer is sent: once the answer
        // is on its way the client may send the next one, and counting both
        // would report one more in flight than the client ever had.
        int released = 0;
        Action release = () => { if (Interlocked.Exchange(ref released, 1) == 0) { Interlocked.Decrement(ref inFlight); } };
        try
        {
            if (LatencyMs > 0) { await Task.Delay(LatencyMs); }
            Log.Enqueue(c.Request.HttpMethod + " " + c.Request.Url.PathAndQuery);
            string path = Uri.UnescapeDataString(c.Request.Url.AbsolutePath.TrimStart('/'));
            int slash = path.IndexOf('/');
            string blob = slash < 0 ? "" : path.Substring(slash + 1);
            if (RequireToken != null && c.Request.Headers["Authorization"] != RequireToken)
            {
                release();
                c.Response.StatusCode = 403;
                c.Response.Close();
                return;
            }
            int fails;
            if (blob.Length > 0 && FailFirst.TryGetValue(blob, out fails) && fails > 0)
            {
                FailFirst[blob] = fails - 1;
                release();
                c.Response.StatusCode = 503;
                c.Response.Close();
                return;
            }
            byte[] body = null;
            if (c.Request.QueryString["comp"] == "list") { body = Encoding.UTF8.GetBytes(List(c.Request.QueryString["prefix"] ?? "", c.Request.QueryString["delimiter"])); }
            else
            {
                string file = Path.Combine(Root, blob.Replace('/', Path.DirectorySeparatorChar));
                if (blob.Length > 0 && File.Exists(file)) { body = File.ReadAllBytes(file); }
            }
            release();
            if (c.Request.HttpMethod == "HEAD")
            {
                // A HEAD answer has headers and no body, as Azure gives it.
                c.Response.StatusCode = body == null ? 404 : 200;
                c.Response.Close();
                return;
            }
            if (body == null)
            {
                // Azure answers a missing blob with an XML error body, not an
                // empty one - a reader that took the body as the document fails.
                byte[] err = Encoding.UTF8.GetBytes("<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>");
                c.Response.StatusCode = 404;
                c.Response.ContentLength64 = err.Length;
                c.Response.OutputStream.Write(err, 0, err.Length);
            }
            else
            {
                c.Response.StatusCode = 200;
                c.Response.ContentType = "application/octet-stream";
                c.Response.AddHeader("ETag", "\"0x" + body.Length.ToString("X") + "\"");
                c.Response.ContentLength64 = body.Length;
                if (TrickleMs > 0 && c.Request.HttpMethod == "GET" && body.Length > 1)
                {
                    for (int at = 0; at < body.Length; at++)
                    {
                        if (at > 0) { await Task.Delay(TrickleMs); }
                        await c.Response.OutputStream.WriteAsync(body, at, 1);
                        await c.Response.OutputStream.FlushAsync();
                    }
                }
                else { c.Response.OutputStream.Write(body, 0, body.Length); }
            }
            c.Response.Close();
        }
        catch { try { c.Response.Abort(); } catch { } }
        finally { release(); }
    }

    string List(string prefix, string delimiter)
    {
        var blobs = new SortedSet<string>(StringComparer.Ordinal);
        var prefixes = new SortedSet<string>(StringComparer.Ordinal);
        if (Directory.Exists(Root))
        {
            foreach (var f in Directory.EnumerateFiles(Root, "*", SearchOption.AllDirectories))
            {
                string rel = Path.GetRelativePath(Root, f).Replace(Path.DirectorySeparatorChar, '/');
                if (!rel.StartsWith(prefix, StringComparison.Ordinal)) { continue; }
                string rest = rel.Substring(prefix.Length);
                int cut = delimiter == "/" ? rest.IndexOf('/') : -1;
                if (cut >= 0) { prefixes.Add(prefix + rest.Substring(0, cut + 1)); } else { blobs.Add(rel); }
            }
        }
        var sb = new StringBuilder("<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults><Blobs>");
        foreach (var b in blobs) { sb.Append("<Blob><Name>").Append(WebUtility.HtmlEncode(b)).Append("</Name></Blob>"); }
        foreach (var p in prefixes) { sb.Append("<BlobPrefix><Name>").Append(WebUtility.HtmlEncode(p)).Append("</Name></BlobPrefix>"); }
        sb.Append("</Blobs><NextMarker /></EnumerationResults>");
        return sb.ToString();
    }

    public void Dispose()
    {
        try { listener.Stop(); listener.Close(); } catch { }
    }
}

public class VmfFakeBlobRequest
{
    public string Method;
    public string PathAndQuery;
    public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    public byte[] Body = new byte[0];
}
'@
}
